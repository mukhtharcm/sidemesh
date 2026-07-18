# Security

Sidemesh is open source under Apache-2.0, but it should still be deployed only
on networks you trust.

## Supported Use

Run Sidemesh only on networks you trust, such as Tailscale or a private LAN. The
daemon exposes powerful host capabilities through authenticated clients:

- coding-agent sessions and approvals,
- workspace filesystem reads/writes,
- local git status and diffs,
- optional integrated terminal access.

Do not expose a Sidemesh daemon directly to the public internet.

## Current Auth Model

The daemon uses a shared bearer token. This is intentionally simple for
dogfooding, but it has important limits:

- no per-device enrollment,
- no built-in token revocation list,
- no scoped tokens,
- no built-in HTTPS termination.

If a token leaks, rotate it with:

```bash
sidemesh token rotate
sidemesh service restart --yes
```

Then update every trusted client with the new token.

## Terminal Access

Integrated terminal support is disabled by default. Enabling it exposes an
interactive shell to authenticated clients, so enable it only on trusted hosts:

```bash
sidemesh setup
```

or:

```bash
SIDEMESH_TERMINAL=1 sidemesh daemon
```

## Reporting Issues

Report security issues privately through
[GitHub Security Advisories](https://github.com/mukhtharcm/sidemesh/security/advisories/new).
Do not file public issues with tokens, hostnames, logs, screenshots, or private
workspace paths.

## Before Any Public Release

Before making the repository public or distributing builds to untrusted users:

```bash
npm run secret:scan
scripts/secret-scan.sh --history
```

The history scan requires `gitleaks`. Treat any finding as blocking until it is
understood, removed, rotated, or explicitly accepted as a false positive.
