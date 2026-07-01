# Pi Provider Overflow Guard & Compaction Trap

> **Status**: Planned — ready for implementation  
> **Created**: 2026-05-03  
> **Author**: Assistant analysis (live session forensics on `019dec66-fb9a-75fd-b66a-ad44098ed58f`)

---

## Summary

When using Pi with Ollama-hosted models (e.g. `kimi-k2.6:cloud`), large sessions silently hit a **compaction trap**: a 413 error from the LLM proxy isn't recognized as overflow by Pi's SDK, the session grows past the model's context window, and **even manual compaction fails** because the compaction summary itself exceeds the window.

This document captures the forensic analysis of a real hit session and proposes a three-change Sidemesh-side guard.

---

## Real Session Forensics

Session: `019dec66-fb9a-75fd-b66a-ad44098ed58f` (Pi, model=`kimi-k2.6:cloud`)  
Location: `~/.pi/agent/sessions/--root-dev-code-on-the-go-sidemesh--/2026-05-03T05-54-25-307Z_019dec66-fb9a-75fd-b66a-ad44098ed58f.jsonl`

### Timeline of failure (from `.jsonl`)

```
T+12:10   Last successful assistant message (65k tokens input, 590 tokens output)
T+12:12   User sends "now let's start the review-fix-review loop."
T+12:12   → 413 "Request Entity Too Large (ref: 632ffad5-0fd9-4bbc-935c-29e39693306c)"
T+12:13   User asks "I'm constantly getting 413..."
T+12:13   → 400 "prompt too long; exceeded max context length by 65590 tokens (ref: ...)"
```

**Key observation**: No `compaction_start`/`compaction_end` events appear after the 413 or the 400, despite Pi having auto-compaction enabled by default. The session was **~246,886 tokens** at its last successful compaction (line 1244) and kept growing.

---

## Three-layer Root Cause

### Layer 1: Overflow detection blind spot (Pi SDK)

`@mariozechner/pi-ai/dist/utils/overflow.js` uses regex patterns:

```js
const OVERFLOW_PATTERNS = [
  /prompt is too long/i,              // Anthropic
  /request_too_large/i,               // Anthropic bare 413
  // ...
  /^4(?:00|13)\s*(?:status code)?\s*\(no body\)/i,  // Cerebras
  /prompt too long; exceeded (?:max )?context length/i,  // Ollama explicit
];
```

The 413 from Ollama/Kimi Cloud carries a body:
```
413 "Request Entity Too Large (ref: 632ffad5-0fd9-4bbc-935c-29e39693306c)"
```

This is **not** matched by `/^4(?:00|13).../` because it has a body, and **not** matched by `/prompt too long/` because the wording is `Request Entity Too Large`. Pi stores it as a normal assistant error, ends the turn, and moves on.

### Layer 2: Next prompt pushes over the cliff

The 400 on the subsequent message IS matched by `/prompt too long; exceeded (?:max )?context length/i`, so Pi's `_checkCompaction` fires. But `_runAutoCompaction()` asks the LLM to summarize the entire session history in a single prompt. The session is already ~250k tokens. The summary prompt also exceeds the window, so `completeSimple()` returns an error, and Pi throws before emitting a `compaction_end` (or emits it with `errorMessage: "Summarization failed: ..."`).

### Layer 3: Manual compact also trapped

If user manually triggers compact or runs `/compact`, the same `completeSimple()` call hits the same limit. The server returns 500 with a generic error, or the mobile app shows nothing because a failed compaction is only visible via the `compaction_end` event's `errorMessage` (which user may not notice in a scrolling timeline).

---

## Session State at Failures

| Metric | Value |
|--------|-------|
| Session file size | ~7,013,203 bytes |
| Last known token count | 221,595 tokens (pre-compaction at 10:14) |
| Estimated at 413 | ~246,886+ tokens |
| Compaction events in file | 3 (all successful, none post-failure) |
| Pi `autoCompactionEnabled` | `true` (default) |
| Model context window | Unknown for kimi-k2.6:cloud; likely ~128k–256k |
| Overflow recovery attempted | No evidence in session file |

---

## Proposed Sidemesh Guard (Three Changes)

### Change 1: Pi Provider — Detect & Recover (`src/pi-provider.ts`)

Add overflow patterns Pi misses and hook into `handleMessageEnd`.

```ts
// Pi SDK may miss provider-specific 413/400 body variants
const SIDEMESH_OVERFLOW_PATTERNS = [
  /Request Entity Too Large/i,           // Ollama/Kimi Cloud 413 with body
  /payload too large/i,                  // Generic 413
  /exceeded max context length/i,        // Ollama explicit
  /maximum.*prompt length.*exceeded/i,   // Generic
  /request exceeds the maximum size/i,   // Anthropic 413 body
  /context window exceeds limit/i,       // Generic
];

function isSidemeshOverflowError(errorMessage: string | null | undefined): boolean {
  return !!errorMessage && SIDEMESH_OVERFLOW_PATTERNS.some((p) => p.test(errorMessage));
}
```

Track cooldown per session (add to `PiSessionState`):
```ts
interface PiSessionState {
  // ... existing fields
  lastOverflowRecoveryAt?: number;
}
```

In `handleMessageEnd` for `role === "assistant"`:
```ts
const stopReason = stringValue(message.stopReason);
const errorMessage = stringValue(message.errorMessage);

if (active && stopReason === "error") {
  active.status = "failed";
}

// Guard: Pi may miss provider-specific overflow shapes
if (stopReason === "error" && isSidemeshOverflowError(errorMessage)) {
  const cooldown = 60_000;
  const now = Date.now();
  if (!session.lastOverflowRecoveryAt || now - session.lastOverflowRecoveryAt > cooldown) {
    session.lastOverflowRecoveryAt = now;
    void this.attemptOverflowRecovery(session, errorMessage);
  }
}
```

Add recovery method:
```ts
private async attemptOverflowRecovery(
  session: PiSessionState,
  originalError: string,
): Promise<void> {
  const sessionId = session.thread.id;

  this.emit("liveEvent", {
    type: "provider_warning",
    sessionId,
    level: "warning",
    code: "pi_overflow_detected",
    message: "Context overflow detected. Attempting automatic compaction...",
    source: "pi/overflow-guard",
  });

  try {
    if (!session.session) {
      await this.ensureLoadedSession(sessionId);
    }
    const result = await session.session!.compact();
    const tokensBefore = (result as any)?.tokensBefore ?? null;

    this.emit("liveEvent", {
      type: "provider_warning",
      sessionId,
      level: "info",
      code: "pi_overflow_recovered",
      message: `Session compacted${tokensBefore ? ` (was ${tokensBefore.toLocaleString()} tokens)` : ""}. Please retry your message.`,
      source: "pi/overflow-guard",
    });
  } catch (compactError) {
    const msg = compactError instanceof Error ? compactError.message : String(compactError);

    if (msg.toLowerCase().includes("already") || msg.toLowerCase().includes("in progress")) {
      return;
    }

    this.emit("liveEvent", {
      type: "provider_warning",
      sessionId,
      level: "error",
      code: "pi_overflow_compact_failed",
      message: `Session too large to compact: ${msg}`,
      source: "pi/overflow-guard",
    });
    this.emit("stderr", `[pi-overflow-guard] ${sessionId} compaction failed: ${msg}`);
  }
}
```

**Why this works**: `message_end` fires before `agent_end`, while the turn is still live. Pi's `compact()` reads the session branch directly and doesn't check turn state. The cooldown prevents double-firing with Pi's own `_checkCompaction`.

### Change 2: Server — Actionable Errors (`src/server.ts`)

Wrap the compact endpoint to return 422 instead of opaque 500:

```ts
try {
  const result = await provider.compactSession!(sessionId);
  clearSessionLogCache(logCache, sessionId);
  response.json({ compacted: true, result: result ?? null });
  void broadcastRecentSessionUpsert(sessionId);
} catch (error) {
  const message = error instanceof Error ? error.message : String(error);
  const isCompactionOverflow =
    message.toLowerCase().includes("too long") ||
    message.toLowerCase().includes("too large") ||
    message.toLowerCase().includes("exceeded") ||
    message.toLowerCase().includes("context") ||
    message.toLowerCase().includes("summarization failed");

  if (isCompactionOverflow) {
    response.status(422).json({
      error: "Session too large to compact",
      detail: message,
      suggestion: "The model's context window is exceeded even by the compaction summary. Try creating a new session.",
    });
  } else {
    response.status(500).json({ error: message });
  }
}
```

### Change 3: Tests

**`src/pi-provider.test.ts`**

1. **413 triggers auto-compaction**
   - Fake session with `compact()` spy
   - Emit `message_end` with `stopReason: "error"`, `errorMessage: "413 Request Entity Too Large..."`
   - Assert `compact()` called once
   - Assert provider warnings with codes `pi_overflow_detected` + `pi_overflow_recovered`

2. **Compaction failure surfaces clear error**
   - Same setup, `compact()` throws `"Summarization failed: prompt too long"`
   - Assert provider warning with code `pi_overflow_compact_failed`

3. **Cooldown suppresses duplicate recovery**
   - Emit two 413 errors within 5 seconds
   - Assert `compact()` called once

**`src/server.test.ts`**

4. **Manual compact returns 422 when session too large**
   - Mock `provider.compactSession` to throw `"prompt too long"`
   - POST to `/api/sessions/:id/compact`
   - Assert status 422, body has `error`, `detail`, `suggestion`

---

## Risks & Mitigations

| Risk | Mitigation |
|------|-----------|
| False positive: 413 from file upload, not prompt | In practice, 413 from LLM APIs is always prompt size. Patterns are conservative. |
| Double-fire with Pi auto-recovery | 60s cooldown + Pi's `_overflowRecoveryAttempted` flag means at most one attempt fires. |
| Compaction races with manual compact | If Pi is already compacting, `compact()` may return fast or throw. Our catch handles it. |
| "Compaction summary too large" trap persists | We can't fix Pi's algorithm from Sidemesh. We surface a clear error instead. |
| Upstream Pi SDK adds pattern later | Guard becomes a no-op (coolown blocks it). Add a TODO to remove when Pi fixes it. |

---

## Related Files for Forensics

| File | What to look for |
|------|-----------------|
| `~/.pi/agent/sessions/--root-dev-code-on-the-go-sidemesh--/2026-05-03T05-54-25-307Z_019dec66-fb9a-75fd-b66a-ad44098ed58f.jsonl` | Session history with 413/400 errors, 3 successful compactions |
| `~/.sidemesh/pi-provider/sessions.json` | Sidemesh Pi state: 148 messages, 1,199 activities for this session |
| `/opt/sidemesh/node_modules/@mariozechner/pi-ai/dist/utils/overflow.js` | Pi's overflow regex patterns (line ~30–70) |
| `/opt/sidemesh/node_modules/@earendil-works/pi-coding-agent/dist/core/agent-session.js` | `_checkCompaction()` flow (line ~1393–1465) |
| `/opt/sidemesh/node_modules/@earendil-works/pi-coding-agent/dist/core/compaction/compaction.js` | `compact()` and `generateSummary()` (lines ~557, ~432) |
| `src/pi-provider.ts` | Sidemesh Pi adapter: `handleMessageEnd`, `compactSession`, `handleSessionEvent` |
| `src/server.ts` | `/api/sessions/:sessionId/compact` endpoint |

---

## TODO

- [ ] Implement overflow pattern guard in `src/pi-provider.ts`
- [ ] Add `lastOverflowRecoveryAt` to `PiSessionState`
- [ ] Implement `attemptOverflowRecovery()` with event emission
- [ ] Wrap compact endpoint in `src/server.ts` with 422 differentiation
- [ ] Add `src/pi-provider.test.ts` coverage (3 tests)
- [ ] Add `src/server.test.ts` coverage (1 test)
- [ ] Run `npm run typecheck` + `npm run test:server` + `npm run build`
- [ ] Consider upstreaming `Request Entity Too Large` pattern to Pi SDK (`@mariozechner/pi-ai`)
