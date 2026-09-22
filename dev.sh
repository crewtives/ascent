#!/usr/bin/env bash
#
# Ascent - development entry point.
#
#   ./dev.sh test      run the headless domain suite (LuaJIT, Lua 5.1 semantics)
#   ./dev.sh lint      static analysis + the architecture dependency rule + TOC consistency
#   ./dev.sh link      symlink the addon into the WoW AddOns folders
#   ./dev.sh package   build a distributable zip
#   ./dev.sh same-code [<rev>] [-- <path>...]  prove the Lua changed since <rev> is comments only
#   ./dev.sh hooks     check commit messages with .githooks/commit-msg in this clone
#
set -euo pipefail

ADDON="Ascent"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"

die() { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }
info() { printf '\033[36m==>\033[0m %s\n' "$*"; }
ok() { printf '\033[32m  ok\033[0m %s\n' "$*"; }

resolve_busted() {
  if [ -x "$HOME/.luarocks/bin/busted" ]; then
    echo "$HOME/.luarocks/bin/busted"
  elif command -v busted >/dev/null 2>&1; then
    command -v busted
  else
    die "busted not found. Install it with:
    luarocks --lua-version=5.1 --lua-dir=\$(brew --prefix luajit) install --local busted"
  fi
}

addon_version() {
  sed -n 's/^## Version: *//p' "$ADDON/$ADDON.toc" | head -1
}

# Every .lua file must be listed in the TOC and every TOC entry must exist: the
# client silently skips a file that is not listed.
check_toc() {
  local toc="$ADDON/$ADDON.toc"
  [ -f "$toc" ] || die "missing $toc"

  local listed on_disk missing_from_toc missing_on_disk
  listed="$(grep -E '^[^#[:space:]].*\.lua[[:space:]]*$' "$toc" | tr -d '\r' | tr '\\' '/' | sed 's/[[:space:]]*$//' | sort || true)"
  on_disk="$(cd "$ADDON" && find . -name '*.lua' -not -path './test/*' | sed 's|^\./||' | sort)"

  missing_from_toc="$(comm -13 <(printf '%s\n' "$listed") <(printf '%s\n' "$on_disk"))"
  missing_on_disk="$(comm -23 <(printf '%s\n' "$listed") <(printf '%s\n' "$on_disk"))"

  if [ -n "$missing_from_toc" ]; then
    printf '\033[31m  lua files not listed in the TOC (they will never load):\033[0m\n'
    printf '    %s\n' $missing_from_toc
    return 1
  fi
  if [ -n "$missing_on_disk" ]; then
    printf '\033[31m  TOC lists files that do not exist:\033[0m\n'
    printf '    %s\n' $missing_on_disk
    return 1
  fi

  local count
  count="$(printf '%s' "$on_disk" | grep -c . || true)"
  ok "TOC lists all $count lua file(s)"
}

# The in-game changelog is generated from CHANGELOG.md. Regenerating and comparing
# catches an edit to one without the other, which the client would never show.
check_changelog() {
  local generated="$ADDON/core/constants/Changelog.lua"
  [ -f "$generated" ] || die "missing $generated -- run: luajit tools/changelog.lua"

  local lua
  if command -v luajit >/dev/null 2>&1; then
    lua="luajit"
  else
    die "luajit not found; it is what the test suite runs on too"
  fi

  # Cleaned up on both paths by hand: a RETURN trap fires again in whatever
  # function runs next, and under `set -u` that reads a variable that is gone.
  local temp status
  temp="$(mktemp)"

  if ! "$lua" tools/changelog.lua "$temp" >/dev/null; then
    rm -f "$temp"
    die "the changelog generator failed"
  fi

  status=0
  if ! diff -q "$generated" "$temp" >/dev/null; then
    printf '\033[31m  %s disagrees with CHANGELOG.md:\033[0m\n' "$generated"
    diff -u "$generated" "$temp" | head -40
    printf '  regenerate it with: \033[1mluajit tools/changelog.lua\033[0m\n'
    status=1
  fi

  rm -f "$temp"
  [ "$status" -eq 0 ] || return 1
  ok "the embedded changelog matches CHANGELOG.md"
}

# The half of the layer rule luacheck cannot see: core/ must not reference the
# adapter, ui or app layers. luacheck covers the other half, since core/ is
# declared no client API.
check_layers() {
  local offenders
  offenders="$(grep -rnE 'ns\.(adapter|ui|app|fakes)\b' "$ADDON/core" 2>/dev/null || true)"

  if [ -n "$offenders" ]; then
    printf '\033[31m  core/ reaches into an outer layer:\033[0m\n'
    printf '    %s\n' "$offenders"
    return 1
  fi
  ok "core/ references no outer layer"
}

# Public text names the product, never the plan it was built from: no decision
# ids, task numbers, change names, planning documents or assistant attribution.
# The rules and the cases they must get right are in tools/public-text.*. Paths
# that are never published come from .publishignore; a tree without that file,
# like the public repository, has every tracked file checked.
PUBLIC_TEXT_RULES="tools/public-text.patterns"
PUBLIC_TEXT_CASES="tools/public-text.cases"
COMMIT_HOOK_CASES=".githooks/commit-msg.cases"

public_text_rules() {
  grep -vE '^[[:space:]]*(#|$)' "$PUBLIC_TEXT_RULES"
}

# Tracked files that are published, one per line.
public_text_files() {
  local skip=("$PUBLIC_TEXT_RULES" "$PUBLIC_TEXT_CASES" "$COMMIT_HOOK_CASES")
  local line file prefix keep
  if [ -f .publishignore ]; then
    while IFS= read -r line; do
      case "$line" in '' | '#'*) continue ;; esac
      skip+=("$line")
    done < .publishignore
  fi
  git ls-files | while IFS= read -r file; do
    keep=1
    for prefix in "${skip[@]}"; do
      case "$file" in "$prefix" | "$prefix"/*) keep=0; break ;; esac
    done
    if [ "$keep" -eq 1 ] && [ -f "$file" ]; then
      printf '%s\n' "$file"
    fi
  done
}

check_public_text() {
  [ -f "$PUBLIC_TEXT_RULES" ] || die "missing $PUBLIC_TEXT_RULES"
  [ -f "$PUBLIC_TEXT_CASES" ] || die "missing $PUBLIC_TEXT_CASES"
  local failed=0 expected text category regex hits matches files file missing=""

  # The rules first, so that a rule which stops catching what it is for, or
  # starts catching the product's own words, fails here and not in the tree.
  while IFS=$'\t' read -r expected text; do
    case "$expected" in '' | '#'*) continue ;; esac
    hits=""
    while IFS=$'\t' read -r category regex; do
      if printf '%s\n' "$text" | grep -qE -- "$regex"; then
        hits="$hits[$category]"
      fi
    done < <(public_text_rules)
    if { [ "$expected" = "clean" ] && [ -n "$hits" ]; } ||
       { [ "$expected" != "clean" ] && [[ "$hits" != *"[$expected]"* ]]; }; then
      printf '\033[31m  rule case failed:\033[0m "%s" expected %s, got %s\n' "$text" "$expected" "${hits:-nothing}"
      failed=1
    fi
  done < "$PUBLIC_TEXT_CASES"
  [ "$failed" -eq 0 ] || return 1

  files="$(public_text_files)"
  while IFS=$'\t' read -r category regex; do
    matches="$(printf '%s\n' "$files" | tr '\n' '\0' | xargs -0 grep -HInE -- "$regex" 2>/dev/null || true)"
    if [ -n "$matches" ]; then
      printf '\033[31m  %s in public text:\033[0m\n' "$category"
      printf '%s\n' "$matches" | head -20 | cut -c1-160 | sed 's/^/    /'
      [ "$(printf '%s\n' "$matches" | wc -l)" -le 20 ] || printf '    ... and %s more\n' "$(( $(printf '%s\n' "$matches" | wc -l) - 20 ))"
      failed=1
    fi
  done < <(public_text_rules)

  # Every addon file outside test/ opens with its one-line description.
  while IFS= read -r file; do
    [ -f "$file" ] || continue
    head -1 "$file" | grep -q '^-- Ascent - ' || missing="$missing $file"
  done < <(git ls-files -- "$ADDON/*.lua" | grep -v "^$ADDON/test/")
  if [ -n "$missing" ]; then
    printf '\033[31m  no "-- Ascent - " header on the first line:\033[0m\n'
    printf '    %s\n' $missing
    failed=1
  fi

  [ "$failed" -eq 0 ] || return 1
  ok "$(printf '%s\n' "$files" | wc -l | tr -d ' ') public files name no plan, and every addon file has its header"
}

# The commit-msg hook against the messages it must accept and reject: in this
# tree when it is the workshop, and always in a stand-in public repository.
check_commit_hook() {
  [ -f "$COMMIT_HOOK_CASES" ] || die "missing $COMMIT_HOOK_CASES"
  local work public head expect mode name dirs dir status failed=0 total=0
  work="$(mktemp -d)"
  public="$(mktemp -d)"
  git -C "$public" init -q
  mkdir -p "$public/.githooks" "$public/tools"
  cp .githooks/commit-msg .githooks/scopes "$public/.githooks/"
  cp "$PUBLIC_TEXT_RULES" "$public/tools/"

  awk -v dir="$work" '
    /^=== / { n++; base = sprintf("%s/%03d", dir, n); print substr($0, 5) > (base ".head"); next }
    n { print > (base ".msg") }
  ' "$COMMIT_HOOK_CASES"

  for head in "$work"/*.head; do
    read -r expect mode name < "$head"
    case "$mode" in
      both) dirs="$ROOT $public" ;;
      workshop) dirs="$ROOT" ;;
      public) dirs="$public" ;;
      *) die "$COMMIT_HOOK_CASES: unknown mode \"$mode\" for \"$name\"" ;;
    esac
    for dir in $dirs; do
      [ "$dir" != "$ROOT" ] || [ -f .publishignore ] || continue
      total=$((total + 1))
      status=0
      (cd "$dir" && ./.githooks/commit-msg "${head%.head}.msg") >/dev/null 2>"$work/err" || status=$?
      if { [ "$expect" = "accept" ] && [ "$status" -ne 0 ]; } || { [ "$expect" = "reject" ] && [ "$status" -eq 0 ]; }; then
        [ "$dir" = "$ROOT" ] && label="workshop" || label="public"
        printf '\033[31m  hook case failed:\033[0m %s (%s): expected %s\n' "$name" "$label" "$expect"
        sed 's/^/      /' "$work/err" | head -4
        failed=1
      fi
    done
  done

  rm -rf "$work" "$public"
  [ "$failed" -eq 0 ] || return 1
  ok "the commit-msg hook gets its $total cases right"
}

cmd_test() {
  info "running the domain suite"
  "$(resolve_busted)" "$@"
}

cmd_lint() {
  info "luacheck (Lua 5.1 std + the core/ dependency rule)"
  command -v luacheck >/dev/null 2>&1 || die "luacheck not found. Install it with: brew install luacheck"
  luacheck "$ADDON"
  info "TOC consistency"
  check_toc
  info "layer dependency rule"
  check_layers
  info "embedded changelog"
  check_changelog
  info "public text"
  check_public_text
  info "commit-msg hook"
  check_commit_hook
}

# Loads every file the TOC declares, in order, against a stand-in client, then
# drives the addon as a player would: the demo through every visual state, the
# panel through every tab, every skin, the options panel. The unit suite never
# touches ui/, and the composition root builds the views before it registers the
# slash commands, so one bad call there leaves an addon that records but answers
# no command, silently, because the client hides Lua errors by default.
#
# The stand-in accepts any template and any method, so client- and
# template-specific failures still need a real login. It has two profiles,
# classic and forever (which removes what that client's API lacks); both always
# run, and the gate fails if either does. `--profile <name>` runs one.
SMOKE_PROFILES=(classic forever)

cmd_smoke() {
  local profiles=("${SMOKE_PROFILES[@]}")
  case "${1:-}" in
    --profile)
      [ -n "${2:-}" ] || die "--profile needs a name"
      # A name it does not know would run as classic -- smoke.lua treats anything
      # but "forever" that way -- and a typo would report a client it never ran.
      case " ${SMOKE_PROFILES[*]} " in
        *" $2 "*) profiles=("$2") ;;
        *) die "unknown profile: $2 (expected one of: ${SMOKE_PROFILES[*]})" ;;
      esac
      ;;
    "") ;;
    *) die "unknown argument: $1 (expected --profile <name>)" ;;
  esac

  local lua
  if command -v luajit >/dev/null 2>&1; then
    lua="luajit"
  else
    die "luajit not found; it is what the test suite runs on too"
  fi

  local profile failed=()
  for profile in "${profiles[@]}"; do
    info "smoke: loading and driving the addon against a stand-in client ($profile)"
    if ! "$lua" "$ADDON/test/smoke.lua" "$ADDON" "$profile"; then
      failed+=("$profile")
    fi
  done

  if [ ${#failed[@]} -gt 0 ]; then
    die "smoke failed on: ${failed[*]}"
  fi
  ok "smoke green on: ${profiles[*]}"
}

cmd_link() {
  local targets=()
  if [ -n "${WOW_ADDONS_DIR:-}" ]; then
    targets+=("$WOW_ADDONS_DIR")
  else
    local base
    for base in \
      "/Applications/World of Warcraft/_classic_era_/Interface/AddOns" \
      "/Applications/World of Warcraft/_classic_/Interface/AddOns" \
      "/Applications/World of Warcraft/_anniversary_/Interface/AddOns" \
      "$HOME/Applications/World of Warcraft/_classic_era_/Interface/AddOns" \
      "$HOME/Applications/World of Warcraft/_classic_/Interface/AddOns" \
      "$HOME/Applications/World of Warcraft/_anniversary_/Interface/AddOns"; do
      [ -d "$base" ] && targets+=("$base")
    done
  fi

  if [ ${#targets[@]} -eq 0 ]; then
    die "no WoW AddOns folder found. Point me at one:
    WOW_ADDONS_DIR='/path/to/Interface/AddOns' ./dev.sh link"
  fi

  local dir
  for dir in "${targets[@]}"; do
    ln -sfn "$ROOT/$ADDON" "$dir/$ADDON"
    ok "linked into $dir"
  done
}

cmd_package() {
  local version out
  version="$(addon_version)"
  [ -n "$version" ] || die "could not read ## Version from the TOC"
  out="dist/$ADDON-$version.zip"
  mkdir -p dist
  rm -f "$out"
  info "packaging $ADDON $version"
  zip -qr "$out" "$ADDON" -x '*/test/*' -x '*.DS_Store'
  ok "$out"
}

cmd_hooks() {
  git config core.hooksPath .githooks
  ok "commit messages in this clone are now checked by .githooks/commit-msg"
}

cmd_same_code() {
  command -v luajit >/dev/null 2>&1 || die "luajit not found; it is what the test suite runs on too"
  info "comparing stripped bytecode"
  luajit tools/same-code.lua "$@"
}

case "${1:-}" in
  test)    shift; cmd_test "$@" ;;
  lint)    shift; cmd_lint "$@" ;;
  smoke)   shift; cmd_smoke "$@" ;;
  link)    shift; cmd_link "$@" ;;
  package) shift; cmd_package "$@" ;;
  same-code) shift; cmd_same_code "$@" ;;
  hooks)   shift; cmd_hooks "$@" ;;
  *)
    sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//'
    exit 1
    ;;
esac
