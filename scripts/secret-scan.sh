#!/usr/bin/env bash
set -euo pipefail

mode="${1:-}"

if command -v gitleaks >/dev/null 2>&1; then
  if [[ "$mode" == "--history" ]]; then
    exec gitleaks git --redact --verbose --source .
  fi
  exec gitleaks dir --redact --verbose .
fi

cat >&2 <<'EOF'
gitleaks is required for Sidemesh secret scanning.

Install it, then rerun:
  brew install gitleaks
  npm run secret:scan

Before making the repo public, scan full git history:
  scripts/secret-scan.sh --history
EOF

exit 2
