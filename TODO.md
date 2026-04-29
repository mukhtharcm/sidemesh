# Sidemesh Release TODO

## Developer Preview Gate

- [x] Keep Sidemesh private for now; do not add an open-source license yet.
- [x] Add release-readiness TODO tracking.
- [x] Add `SECURITY.md` with honest private-network and host-access caveats.
- [x] Add `CONTRIBUTING.md` for private collaborators.
- [x] Add a release/playbook doc.
- [x] Add CI for server typecheck/tests/build/package dry-run.
- [x] Add CI for focused Flutter tests and analysis.
- [x] Add manual GitHub Actions artifact builds for Android, macOS, and iOS simulator.
- [x] Add `sidemesh service uninstall` for Linux/systemd and macOS/LaunchAgent.
- [x] Clean package metadata while keeping the package private and unlicensed.
- [x] Document private GitHub install as the current daemon distribution path.
- [x] Document the required full git-history secret scan before any public release.
- [ ] Decide the future license only after the product/security model stabilizes.

## Should Tackle Soon

- [ ] Add real pairing and device/token revocation.
- [ ] Define an HTTPS or mTLS story for non-Tailscale/private-LAN use.
- [ ] Decide app distribution: TestFlight/APK first, app stores later.
- [ ] Publish a provider maturity matrix; Codex is primary, Copilot is still early.
- [ ] Polish terminal reconnect/restart UX and service restart flows.
- [ ] Add a signed/notarized macOS release workflow once Apple signing secrets are ready.
- [ ] Add TestFlight deployment once App Store Connect secrets/profiles are ready.
