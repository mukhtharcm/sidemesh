#!/usr/bin/env bash
set -euo pipefail

if [[ "$#" -ne 2 ]]; then
  echo "Usage: $0 <changelog-path> <version>" >&2
  exit 1
fi

changelog_path="$1"
version="$2"

if [[ ! -f "$changelog_path" ]]; then
  exit 0
fi

awk -v version="$version" '
function normalized_heading(line) {
  heading = line
  sub(/^##[[:space:]]+/, "", heading)
  sub(/^[[]/, "", heading)
  sub(/[]].*$/, "", heading)
  sub(/[[:space:]].*$/, "", heading)
  return heading
}

/^##[[:space:]]+/ {
  current = normalized_heading($0)
  if (in_section && current != version) {
    exit
  }
  if (current == version) {
    in_section = 1
    next
  }
}

in_section {
  print
}
' "$changelog_path"
