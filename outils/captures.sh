#!/bin/bash
# README captures — CHARTE.md §12. `make shots` delegates here.
#
# Sonde lives in the menu bar: its panel is a popover, which a capture cannot
# open without the Accessibility permission. So each view is reached at launch
# instead — `-window panel|catalog|stats` opens it as an ordinary window, and
# `-catalog.tab podcasts` picks the catalogue's tab and `-search <text>` types
# into its search field (see App.swift and CatalogView).
#
# What the views show is the amplifier on this network, playing whatever it
# plays: public radio and podcast directories, nothing personal. The amp must
# be on and reachable, or the panel shows "searching". Rerun before a release.
set -euo pipefail
cd "$(dirname "$0")/.."
capturer=${CHARTE:-../../Charte}/outils/capturer.sh
app=build/Sonde.app
[ -d "$app" ] || { echo "captures: build the app first (make package)" >&2; exit 1; }

shot() {  # shot <language> <out> <launch arguments…>
  local lang=$1 out=$2; shift 2
  pkill -x Sonde 2>/dev/null || true
  sleep 1
  open -n "$app" --args "$@" -AppleLanguages "($lang)" -AppleLocale "${lang}_$( [ "$lang" = en ] && echo GB || echo FR )"
  # Discovery, then the amp's state, artwork and catalogue over HTTP.
  sleep 10
  "$capturer" Sonde "$out"
}

for lang in en fr; do
  suffix=$( [ "$lang" = en ] && echo "" || echo ".fr" )
  shot "$lang" "docs/img/panel$suffix.png"    -window panel
  shot "$lang" "docs/img/catalog$suffix.png"  -window catalog -search jazz
  shot "$lang" "docs/img/podcasts$suffix.png" -window catalog -catalog.tab podcasts -search jazz
  shot "$lang" "docs/img/stats$suffix.png"    -window stats
done
pkill -x Sonde 2>/dev/null || true
