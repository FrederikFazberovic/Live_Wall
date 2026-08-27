#!/usr/bin/env bash
#
# Transcodes vidoes (4K → RESOLUTION HEVC sw encoder, everything else just copies) from folder wallpapers/.
# Output into wallpapers-tranc/.
#
# Subcommands:
#   ./transcode_wall.sh                                  # scans ~/Videos/wallpapers
#   ./transcode_wall.sh --dry-run                        # preview
#   ./transcode_wall.sh "file:///path/with%20space.mkv"  # specific wallpaper
#   ./transcode_wall.sh --from-stdin < list.txt          # paths/URIs from stdin
#   ./transcode_wall.sh --from-file list.txt             # paths/URIs from file
#   ./transcode_wall.sh --ext mkv --ext mp4              # only certain extensions
#   ./transcode_wall.sh --resolution 3840x2160           # own target resolution
#   ./transcode_wall.sh --list-resolutions               # outputs resolutions trom hyprctl monitors
#
# Copyright (C) 2026
# SPDX-License-Identifier: GPL-3.0-or-later
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version. See LICENSE.
#
# Developed with AI assistance (Claude)

set -euo pipefail

# ---- default config (overridden by ~/.config/mpvpaper/live_wall.conf) ─────
RESOLUTION="1920x1080" # cílové rozlišení pro překódovaná videa
DEFAULT_SRC="$HOME/Videos/wallpapers"
DEFAULT_DST="$HOME/Videos/wallpapers-tranc"

CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/mpvpaper"
CONFIG_FILE="$CONFIG_DIR/live_wall.conf"

# ── Internal (do not modify) ────────────────────────────────────────────────────────────────
DRY_RUN=0
FORCE=0
FROM_STDIN=0
FROM_FILE=""
EXTRA_EXTS=()
INPUTS=()
SRC_SET=0
DST_SET=0
SRC=""
DST=""
RESOLUTION_SET=0

# ── Load user config ────────────────────────────────────────────────────────────
load_config() {
  [ -f "$CONFIG_FILE" ] || return 0
  while IFS= read -r line; do
    case "$line" in
    '' | \#*) continue ;;
    esac
    case "$line" in
    export\ *) eval "${line#export }" ;;
    *) eval "$line" ;;
    esac
  done <"$CONFIG_FILE"
}

load_config

is_existing_dir() { [ -d "$1" ]; }
looks_like_uri() { case "$1" in file://* | file:/*) return 0 ;; *) return 1 ;; esac }

# ── argv parsing ───────────────────────────────────────────────────────────
for arg in "$@"; do
  case "$arg" in
  --dry-run) DRY_RUN=1 ;;
  --force) FORCE=1 ;;
  --from-stdin) FROM_STDIN=1 ;;
  --from-file=*) FROM_FILE="${arg#--from-file=}" ;;
  --src=*)
    SRC="${arg#--src=}"
    SRC_SET=1
    ;;
  --dst=*)
    DST="${arg#--dst=}"
    DST_SET=1
    ;;
  --ext=*) EXTRA_EXTS+=("${arg#--ext=}") ;;
  --resolution=* | \
    --res=*)
    RESOLUTION="${arg#*=}"
    RESOLUTION_SET=1
    ;;
  --list-resolutions | --list-monitors)
    echo "Resolutions detected via hyprctl monitors:"
    if command -v hyprctl >/dev/null 2>&1; then
      hyprctl monitors 2>/dev/null | sed 's/^/  /'
    else
      echo "  (hyprctl not found; install hyprland or use xrandr/wayland-info)"
      command -v xrandr >/dev/null 2>&1 && xrandr | sed 's/^/  /'
    fi
    echo
    echo "Current RESOLUTION setting: $RESOLUTION"
    echo "Use:  --resolution WIDTHxHEIGHT   (e.g. --resolution 2560x1440)"
    exit 0
    ;;
  -h | --help)
    sed -n '2,20p' "$0"
    echo
    echo "Config: ~/.config/mpvpaper/live_wall.conf"
    echo
    echo "Resolutions of monitors via --list-resolutions or vith hyprctl monitors"
    exit 0
    ;;
  --resolution | --res)
    # flag without value: another arg is value
    NEXT_IS_RES=1
    continue
    ;;
  *)
    # position argument - directory (SRC/DST) or INPUT (path/URI)
    if [ "${NEXT_IS_RES:-0}" -eq 1 ]; then
      RESOLUTION="$arg"
      RESOLUTION_SET=1
      NEXT_IS_RES=0
      continue
    fi
    if is_existing_dir "$arg"; then
      if [ "$SRC_SET" -eq 0 ] && [ "$DST_SET" -eq 0 ] && [ -z "$SRC" ]; then
        SRC="$arg"
        SRC_SET=1
      elif [ "$DST_SET" -eq 0 ] && [ -z "$DST" ]; then
        DST="$arg"
        DST_SET=1
      else
        INPUTS+=("$arg")
      fi
    else
      INPUTS+=("$arg")
    fi
    ;;
  esac
done

# Validates RESOLUTION
if ! [[ "$RESOLUTION" =~ ^[0-9]+x[0-9]+$ ]]; then
  echo "ERROR: RESOLUTION must be in format WIDTHxHEIGHT (got: '$RESOLUTION')" >&2
  echo "Run with --list-resolutions to see your monitor resolutions." >&2
  exit 1
fi
RES_W="${RESOLUTION%x*}"
RES_H="${RESOLUTION#*x}"

SRC="${SRC:-$DEFAULT_SRC}"
DST="${DST:-$DEFAULT_DST}"

mkdir -p "$DST"

log() { printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*"; }

# file:// URI → common path
uri_to_path() {
  local raw="$1"
  case "$raw" in
  file://*) raw="${raw#file://}" ;;
  file:/*) raw="${raw#file:}" ;;
  *)
    printf '%s' "$raw"
    return
    ;;
  esac
  local encoded="${raw//%/\\x}"
  printf '%b' "$encoded"
}

get_resolution() {
  ffprobe -v error -select_streams v:0 \
    -show_entries stream=width,height -of csv=p=0 "$1" 2>/dev/null
}

count=0
skip=0
fail=0

process_file() {
  local f="$1"
  if [ -z "$f" ] || [ ! -f "$f" ]; then
    log "skip (missing/not a file): $f"
    skip=$((skip + 1))
    return
  fi
  if [[ "$f" == *$'\n'* ]]; then
    log "skip (multi-line path, parser issue): $f"
    fail=$((fail + 1))
    return
  fi

  local base
  base=$(basename "$f")
  local name="${base%.*}"
  local out="$DST/$name.mp4"

  if [ "$FORCE" -eq 0 ] && compgen -G "$DST/$name.*" >/dev/null 2>&1; then
    if compgen -G "$DST/$name.*" >/dev/null 2>&1; then
      log "skip (exists in DST by name): $base"
      skip=$((skip + 1))
      return
    fi
  fi

  if [ "$FORCE" -eq 0 ] && [ -f "$out" ] && [ "$out" -nt "$f" ]; then
    log "skip (up-to-date): $base"
    skip=$((skip + 1))
    return
  fi

  local res
  res=$(get_resolution "$f")
  if [ -z "$res" ]; then
    log "skip (no video): $base"
    skip=$((skip + 1))
    return
  fi

  local w=${res%,*}
  local h=${res#*,}

  # Less than or equal to target → just copies
  if [ "$h" -le "$RES_H" ] && [ "$w" -le "$RES_W" ]; then
    log "copy (≤${RESOLUTION}): $base"
    if [ "$DRY_RUN" -eq 0 ]; then
      cp -n "$f" "$out"
    fi
    skip=$((skip + 1))
    return
  fi

  log "transcode ${w}×${h} → ${RES_W}×${RES_H}: $base"
  if [ "$DRY_RUN" -eq 1 ]; then
    return
  fi

  local logf="$DST/.transcode-$$.log"
  if ffmpeg -hide_banner -loglevel error -nostdin -stats -y \
    -i "$f" \
    -vf "scale=${RES_W}:${RES_H}:flags=lanczos:force_original_aspect_ratio=decrease,pad=${RES_W}:${RES_H}:(ow-iw)/2:(oh-ih)/2:color=black" \
    -c:v libx265 -preset slow -crf 23 -tag:v hvc1 \
    -c:a copy \
    -movflags +faststart \
    "$out" 2>"$logf"; then
    count=$((count + 1))
    rm -f "$logf"
  else
    log "  FAILED: $base"
    log "    --- stderr ffmpeg: ---"
    tail -10 "$logf" 2>/dev/null | sed 's/^/    /'
    log "    --- kompletní log: $logf ---"
    rm -f "$out"
    fail=$((fail + 1))
    mv "$logf" "$DST/${name}.failed.log" 2>/dev/null || rm -f "$logf"
  fi
  if [ -n "${STATS_FILE:-}" ]; then
    printf '%d\n%d\n%d\n' "$count" "$skip" "$fail" >"$STATS_FILE"
  fi
}

build_find_args() {
  if [ "${#EXTRA_EXTS[@]}" -gt 0 ]; then
    FIND_ARGS=(-type f \()
    local first=1
    for ext in "${EXTRA_EXTS[@]}"; do
      if [ $first -eq 1 ]; then
        FIND_ARGS+=(-iname "*.${ext}")
        first=0
      else
        FIND_ARGS+=(-o -iname "*.${ext}")
      fi
    done
    FIND_ARGS+=(\))
  else
    FIND_ARGS=(-type f \( -iname '*.mp4' -o -iname '*.mkv'
      -o -iname '*.webm' -o -iname '*.mov' -o -iname '*.avi'
      -o -iname '*.m4v' -o -iname '*.flv' -o -iname '*.wmv' \))
  fi
}
build_find_args

if [ "$FROM_STDIN" -eq 1 ]; then
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    f=$(uri_to_path "$line")
    if [ ! -f "$f" ]; then
      log "MISSING: $f"
      fail=$((fail + 1))
      continue
    fi
    process_file "$f"
  done
elif [ -n "$FROM_FILE" ]; then
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    f=$(uri_to_path "$line")
    if [ ! -f "$f" ]; then
      log "MISSING: $f"
      fail=$((fail + 1))
      continue
    fi
    process_file "$f"
  done <"$FROM_FILE"
elif [ "${#INPUTS[@]}" -gt 0 ]; then
  for inp in "${INPUTS[@]}"; do
    f=$(uri_to_path "$inp")
    if [ ! -f "$f" ]; then
      log "MISSING: $f"
      fail=$((fail + 1))
      continue
    fi
    process_file "$f"
  done
else
  STATS_FILE="$(mktemp)"
  trap 'rm -f "$STATS_FILE"' EXIT
  printf '0\n0\n0\n' >"$STATS_FILE"
  find "$SRC" -maxdepth 1 "${FIND_ARGS[@]}" -print0 | sort -z |
    while IFS= read -r -d '' f; do
      process_file "$f"
    done
  if [ -s "$STATS_FILE" ]; then
    count=$(sed -n '1p' "$STATS_FILE")
    skip=$(sed -n '2p' "$STATS_FILE")
    fail=$(sed -n '3p' "$STATS_FILE")
  fi
fi

echo
log "=== DONE: transcoded=$count, skipped=$skip, failed=$fail, target=${RESOLUTION} ==="
