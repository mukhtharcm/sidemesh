# Codex app-server compatibility

Last audited: 2026-09-11 against Codex CLI `0.144.6`, with a native
paginated-history check against `0.154.0`.

Sidemesh treats the Codex app-server protocol as versioned provider input. The
audit source of truth is the CLI-generated stable JSON Schema together with the
official [app-server documentation](https://learn.chatgpt.com/docs/app-server).

## Current compatibility decisions

- All Codex RPC methods sent by Sidemesh are present in the `0.144.6` stable
  schema.
- Sidemesh opts into `experimentalApi` for permission profiles and client input
  identity. It also advertises the stable
  `mcpServerOpenaiFormElicitation` capability because the adapter supports the
  extended form response shape.
- Codex `0.144.6` accepts `untrusted`, `on-request`, and `never` approval
  policies. The removed `on-failure` value remains available to other Sidemesh
  providers but is neither advertised nor forwarded by the Codex adapter.
- Reasoning effort is a non-empty, model-advertised string. Do not replace it
  with a closed local enum; providers can add values such as `max`.
- Every unsupported server-initiated request receives JSON-RPC error `-32601`.
  Known requests with malformed parameters receive `-32600`, preventing the
  app-server from waiting indefinitely for a response.
- `initialize.clientInfo.version` is read from the installed Sidemesh
  `package.json` rather than a duplicated constant.
- Activity lifecycle comes from the enclosing `item/started` and
  `item/completed` notification. Do not infer completion from item fields such
  as a web-search query; some item variants, including `contextCompaction`, do
  not carry their own status.
- Keep generalized activity mappings aligned with the stable `ThreadItem`
  union, including MCP, dynamic, and collaboration tool-call variants.
- `thread/read` with `includeTurns: true` owns transcript messages, native IDs,
  and execution state. Complete native `clientId` values confirm host inputs;
  both `turn/start` and `turn/steer` send `clientUserMessageId`.
- The generated snapshot and input types in `src/codex-protocol.ts` come from
  CLI `0.144.6`. Regenerate them with
  `node scripts/generate-codex-protocol.mjs <codex-binary>`.
- Two file compatibility gaps remain explicit: `thread/read` does not include
  all saved runtime settings or token usage in `0.144.6`, and its legacy
  projection drops persisted function-call output. Legacy file data supplies
  missing tool output and system errors. It never replaces native user or
  assistant messages. File ordering is used only after both complete visible
  sequences agree, retaining each native message ID and each repeated prompt.
- `0.144.6` rejects paginated history despite exposing related protocol types.
  `0.154.0` supports it through `thread/read`. Seeded paginated JSONL fixtures
  need ordinals and native resume to build the native SQLite projection.
  Sidemesh does not write that projection. Native read failures propagate;
  they do not mark a cached transcript as current.

## Native history check

Set `SIDEMESH_TEST_CODEX_BIN` to the selected CLI and run
`node --import tsx --test src/codex-thread-history.test.ts`. The check uses an
isolated native home, canonical fixture history, resume, and process restart.
It sends no model prompt. It checks legacy history on `0.144.6` and paginated
history on `0.154.0`, including client input identity. Shared fixtures cover
reasoning, plans, errors, command output, and image-bearing tools.

## Upgrade audit

Generate both stable and experimental schemas from the candidate Codex binary:

```bash
codex app-server generate-json-schema --out /tmp/codex-schema-stable
codex app-server generate-json-schema --experimental --out /tmp/codex-schema-all
```

Before declaring a Codex version compatible:

1. Confirm every outbound method used by `src/codex-provider.ts` and
   `src/codex-client.ts` exists in the stable schema.
2. Diff request parameter schemas, approval and sandbox enums, notification
   variants, and server-initiated request variants against the last audited
   version.
3. Add or update regression tests for every changed assumption.
4. Run the required TypeScript gates and an app-server smoke test with the
   candidate binary.

The [Codex changelog](https://learn.chatgpt.com/docs/changelog) is useful for
triage, but generated schemas remain authoritative for wire compatibility.
