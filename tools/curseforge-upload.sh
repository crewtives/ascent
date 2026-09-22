#!/usr/bin/env bash
#
# Ascent - upload a packaged zip to CurseForge.
#
# The version and the supported clients come from the TOC, the notes from
# CHANGELOG.md and the zip from ./dev.sh package; only the token and the project
# id come from the environment.
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

# The TOC's interface numbers are the list of supported clients, and the game
# versions derive from them. The format is XYYZZ without padding: 11509 is
# 1.15.9, 20506 is 2.5.6.
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

# The same notes the GitHub release uses, read by the same script.
CHANGELOG_BODY="$(./tools/release-notes.sh)" || die "could not read a section out of CHANGELOG.md"

if [ "$DRY_RUN" -eq 1 ] && [ -z "${CF_API_TOKEN:-}" ]; then
  # Without a token the game version ids cannot be resolved; a dry run only checks
  # that everything this needs can be read.
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
    # Refuse rather than upload against the wrong clients: players never see a file
    # tagged for a version nobody runs.
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

# No -f: the status comes back separately and the body is kept either way,
# because a rejection's body says why.
BODY_FILE="$(mktemp)"
# The metadata goes through a file, not -F metadata=...: curl reads a form value
# up to the first semicolon and takes the rest as parameters, which truncates the
# JSON when the notes contain one.
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
