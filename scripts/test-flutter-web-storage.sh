#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../apps/mobile"

# Flutter's browser test server serves test/, not web/.
for asset in sqlite3.wasm sqflite_sw.js; do
  if [[ -e "test/$asset" ]]; then
    echo "Remove the existing test/$asset before this check." >&2
    exit 1
  fi
done
trap 'rm -f test/sqlite3.wasm test/sqflite_sw.js' EXIT
cp web/sqlite3.wasm web/sqflite_sw.js test/
"${FLUTTER_BIN:-flutter}" test --platform chrome \
  test/session_local_store_test.dart test/session_send_outbox_store_test.dart
