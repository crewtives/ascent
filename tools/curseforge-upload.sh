#!/usr/bin/env bash
#
# Ascent - upload a packaged zip to CurseForge.
#
# Everything this needs is already declared somewhere else, so nothing here is
# typed twice: the version and the supported clients come out of the TOC, the
# changelog out of CHANGELOG.md, and the zip out of ./dev.sh package. The only
# things that come from outside are the token and the project id.
#
#   CF_API_TOKEN=...  required to upload (authors-old.curseforge.com/account/api-tokens)
#   CF_PROJECT_ID=... the number in the project's authors URL
#
#   ./tools/curseforge-upload.sh --dry-run          print what would be sent
#   ./tools/curseforge-upload.sh --release-type beta
#
set -euo pipefail

ADDON="Ascent"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

API_HOST="${CF_API_HOST:-wow.curseforge.com}"
RELEASE_TYPE="beta"
DRY_RUN=0

die() { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }
info() { printf '\033[36m==>\033[0m %s\n' "$*"; }
ok() { printf '\033[32m  ok\033[0m %s\n' "$*"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    --release-type) RELEASE_TYPE="${2:-}"; shift 2 ;;
    *) die "unknown argument: $1" ;;
  esac
done

case "$RELEASE_TYPE" in
  alpha|beta|release) ;;
  *) die "release type must be alpha, beta or release (got '$RELEASE_TYPE')" ;;
esac

TOC="$ADDON/$ADDON.toc"
[ -f "$TOC" ] || die "missing $TOC"

VERSION="$(sed -n 's/^## Version: *//p' "$TOC" | head -1 | tr -d '\r')"
[ -n "$VERSION" ] || die "could not read ## Version from the TOC"

ZIP="dist/$ADDON-$VERSION.zip"
[ -f "$ZIP" ] || die "missing $ZIP -- run ./dev.sh package first"

# The TOC's interface numbers ARE the list of supported clients, so the upload
# derives its game versions from them rather than carrying a second list that
# would quietly drift. 11509 is 1.15.9, 20506 is 2.5.6: XYYZZ, no padding.
interface_to_name() {
  local n="$1"
  printf '%d.%d.%d\n' "$((10#$n / 10000))" "$(((10#$n / 100) % 100))" "$((10#$n % 100))"
}

INTERFACES="$(sed -n 's/^## Interface: *//p' "$TOC" | head -1 | tr -d '\r' | tr ',' ' ')"
[ -n "$INTERFACES" ] || die "could not read ## Interface from the TOC"

VERSION_NAMES=()
for iface in $INTERFACES; do
  [ -n "$iface" ] || continue
  VERSION_NAMES+=("$(interface_to_name "$iface")")
done
[ ${#VERSION_NAMES[@]} -gt 0 ] || die "the TOC declares no interface version"

info "$ADDON $VERSION as $RELEASE_TYPE, for ${VERSION_NAMES[*]}"

# The section at the top of the changelog, without its own heading: the file is
# Keep a Changelog, so the first "## " block is always the one being released.
CHANGELOG_BODY="$(awk '
  /^## / { if (seen) exit; seen = 1; next }
  # Reference-style link definitions are markdown plumbing for the file, not part
  # of the release notes, and they read as a stray line once pasted.
  /^\[[^]]+\]: / { next }
  seen { print }
' CHANGELOG.md)"
[ -n "$CHANGELOG_BODY" ] || die "could not read a section out of CHANGELOG.md"

if [ "$DRY_RUN" -eq 1 ] && [ -z "${CF_API_TOKEN:-}" ]; then
  # Without a token the game version ids cannot be resolved, which is fine for a
  # dry run: what it is checking is that this file can read everything it needs.
  info "dry run without a token: skipping game version lookup"
  GAME_VERSION_IDS="[]"
else
  [ -n "${CF_API_TOKEN:-}" ] || die "CF_API_TOKEN is not set"

  info "resolving game version ids"
  VERSIONS_JSON="$(curl -fsS -H "X-Api-Token: $CF_API_TOKEN" "https://$API_HOST/api/game/versions")" \
    || die "could not read the game version list (is the token valid?)"

  GAME_VERSION_IDS="$(printf '%s' "$VERSIONS_JSON" | VERSION_NAMES="${VERSION_NAMES[*]}" python3 -c '
import json, os, sys

versions = json.load(sys.stdin)
wanted = os.environ["VERSION_NAMES"].split()
by_name = {}
for entry in versions:
    by_name.setdefault(entry["name"], entry["id"])

ids, missing = [], []
for name in wanted:
    if name in by_name:
        ids.append(by_name[name])
    else:
        missing.append(name)

if missing:
    # Refusing beats uploading against the wrong clients: a file tagged for a
    # version nobody runs is invisible, and one tagged for the wrong one is worse.
    sys.stderr.write("no game version id for: %s\n" % ", ".join(missing))
    sys.exit(1)

print(json.dumps(ids))
')" || die "the TOC declares a client CurseForge does not list"
  ok "game versions: $GAME_VERSION_IDS"
fi

METADATA="$(CHANGELOG_BODY="$CHANGELOG_BODY" DISPLAY_NAME="$ADDON $VERSION" \
  RELEASE_TYPE="$RELEASE_TYPE" GAME_VERSION_IDS="$GAME_VERSION_IDS" python3 -c '
import json, os

print(json.dumps({
    "changelog": os.environ["CHANGELOG_BODY"].strip(),
    "changelogType": "markdown",
    "displayName": os.environ["DISPLAY_NAME"],
    "gameVersions": json.loads(os.environ["GAME_VERSION_IDS"]),
    "releaseType": os.environ["RELEASE_TYPE"],
}))
')"

if [ "$DRY_RUN" -eq 1 ]; then
  info "dry run -- this is what would be sent with $ZIP"
  printf '%s' "$METADATA" | python3 -m json.tool
  exit 0
fi

[ -n "${CF_PROJECT_ID:-}" ] || die "CF_PROJECT_ID is not set"

info "uploading $ZIP"

# The body of a rejection is the whole point of reading one: "the upload was
# rejected" is what this said before, which is a report that a person then has to
# go and reproduce by hand. -f would throw the body away, so the status comes back
# separately and the body is kept either way.
BODY_FILE="$(mktemp)"
# The metadata goes through a FILE and not through -F metadata=... on the command
# line. curl reads a form value up to the first semicolon and takes the rest as
# parameters, and the changelog is prose: one "; " inside it truncated the JSON
# mid-string and CurseForge answered "Invalid JSON" -- about a document that was
# perfectly valid when it left here. Reading it from a file removes the whole
# class of quoting problem rather than escaping one character of it.
META_FILE="$(mktemp)"
printf '%s' "$METADATA" > "$META_FILE"
trap 'rm -f "$BODY_FILE" "$META_FILE"' EXIT

STATUS="$(curl -sS -o "$BODY_FILE" -w '%{http_code}' \
  -H "X-Api-Token: $CF_API_TOKEN" \
  -F "metadata=<$META_FILE;type=application/json" \
  -F "file=@$ZIP;type=application/zip" \
  "https://$API_HOST/api/projects/$CF_PROJECT_ID/upload-file")"

if [ "$STATUS" != "200" ] && [ "$STATUS" != "201" ]; then
  printf '\033[31mCurseForge answered %s:\033[0m\n' "$STATUS" >&2
  cat "$BODY_FILE" >&2
  printf '\n' >&2
  die "the upload was rejected"
fi

ok "uploaded: $(cat "$BODY_FILE")"
