# Codex app-server compatibility

Last audited: 2026-07-21 against Codex CLI `0.144.6`.

Sidemesh treats the Codex app-server protocol as versioned provider input. The
audit source of truth is the CLI-generated stable JSON Schema together with the
official [app-server documentation](https://learn.chatgpt.com/docs/app-server).

## Current compatibility decisions

- All Codex RPC methods sent by Sidemesh are present in the `0.144.6` stable
  schema.
- Sidemesh does not opt into `experimentalApi`. It does advertise the stable
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
