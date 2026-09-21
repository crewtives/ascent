#!/usr/bin/env bash
#
# Ascent - the release notes for the version at the top of CHANGELOG.md.
#
# One reader, two consumers: the CurseForge upload and the GitHub release. A
# second copy of this awk is a second set of release notes the day somebody edits
# one of them, and the one that goes stale is whichever nobody was looking at.
#
#   ./tools/release-notes.sh            the newest section, without its heading
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# The file is Keep a Changelog, so the first "## " block is always the one being
# released. Reference-style link definitions are markdown plumbing for the file,
# not part of the notes, and they read as a stray line once pasted.
BODY="$(awk '
  /^## / { if (seen) exit; seen = 1; next }
  /^\[[^]]+\]: / { next }
  seen { print }
' "$ROOT/CHANGELOG.md")"

if [ -z "$BODY" ]; then
  echo "could not read a section out of CHANGELOG.md" >&2
  exit 1
fi

printf '%s\n' "$BODY"
