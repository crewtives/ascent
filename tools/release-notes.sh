#!/usr/bin/env bash
#
# Ascent - the release notes for a version of CHANGELOG.md, the newest by default.
#
# The CurseForge upload and the GitHub release both read their notes through
# this script, so the two cannot drift apart.
#
#   ./tools/release-notes.sh            the newest section, without its heading
#   ./tools/release-notes.sh 0.2.0      that version's section, to rewrite a published release
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# The file is Keep a Changelog, so the first "## " block is the newest version.
# Reference-style link definitions are left out: pasted, they read as a stray line.
VERSION="${1:-}"
BODY="$(awk -v want="$VERSION" '
  /^## / {
    if (seen) exit
    if (want == "" || index($0, "## [" want "]") == 1) seen = 1
    next
  }
  /^\[[^]]+\]: / { next }
  seen { print }
' "$ROOT/CHANGELOG.md")"

if [ -z "$BODY" ]; then
  echo "could not read ${VERSION:+the $VERSION }section out of CHANGELOG.md" >&2
  exit 1
fi

printf '%s\n' "$BODY"
