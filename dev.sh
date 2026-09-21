#!/usr/bin/env bash
#
# Ascent - development entry point.
#
#   ./dev.sh test      run the headless domain suite (LuaJIT, Lua 5.1 semantics)
#   ./dev.sh lint      static analysis + the architecture dependency rule + TOC consistency
#   ./dev.sh link      symlink the addon into the WoW AddOns folders
#   ./dev.sh package   build a distributable zip
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

# Every .lua file the client must load has to be listed in the TOC, and every
# path listed in the TOC has to exist. Drift here fails silently in-game -- the
# file simply never loads -- so it is cheaper to catch it on every lint run.
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

# The dependency rule has two halves. luacheck covers one (core/ has no WoW API
# declared, so touching it fails lint). This covers the other: core/ must not reach
# outward into the adapter, ui or app layers either. Both halves together are what
# make "hexagonal" a property of this repo rather than an intention in a document.
# The changelog the addon carries is GENERATED from CHANGELOG.md. Editing one and
# not the other is invisible: the addon keeps showing the old text, in the client,
# where nobody is looking at a diff. Same failure shape as check_toc, same answer.
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
}

# Loads every file the TOC declares, in TOC order, against a stand-in client, and
# then drives the addon the way a player would in their first minute: the demo
# through every visual state, the panel through every tab, every skin applied,
# the options panel refreshed.
#
# This exists because none of the unit suite touches ui/, and the failure mode it
# guards against is the worst one this addon has: the composition root builds the
# views before it registers the slash commands, so ONE bad call while building a
# frame produced an addon that recorded data perfectly and answered nothing at
# all -- with the client's Lua errors off by default, silently.
#
# It is not the client and does not pretend to be: a stub accepts any template
# and any method, so flavour-specific and template-specific failures still need a
# real login. Everything else -- a nil index, a missing field, a load-order
# mistake, a key read off a frozen table that does not have it -- it catches in
# under a second.
cmd_smoke() {
  info "smoke: loading and driving the addon against a stand-in client"
  local lua
  if command -v luajit >/dev/null 2>&1; then
    lua="luajit"
  else
    die "luajit not found; it is what the test suite runs on too"
  fi
  "$lua" "$ADDON/test/smoke.lua" "$ADDON"
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

case "${1:-}" in
  test)    shift; cmd_test "$@" ;;
  lint)    shift; cmd_lint "$@" ;;
  smoke)   shift; cmd_smoke "$@" ;;
  link)    shift; cmd_link "$@" ;;
  package) shift; cmd_package "$@" ;;
  *)
    sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'
    exit 1
    ;;
esac
