#!/usr/bin/env bash
# live_wall.sh - wallpaper only runs while you're actively watching
#
# Detects: focus on configured monitor(s) (or all), fullscreen windows,
#          suspend/lock, idle
# Uses:     hyprctl -j + jq, loginctl, mpvpaper
#
# Subcommands:
#   live_wall.sh               # daemon (default)
#   live_wall.sh start|stop|restart|status
#   live_wall.sh install       # detects distro, installs dependencies
#   live_wall.sh --help
#
# Config: top-of-file variables below, optionally overridden by
#         ~/.config/mpvpaper/live_wall.conf (KEY=VALUE, one per line)
#
# Copyright (C) 2026
# SPDX-License-Identifier: GPL-3.0-or-later
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version. See LICENSE.
#
# Developed with AI assistance (Claude).

set -u

# ── Default configuration (overridden by ~/.config/mpvpaper/live_wall.conf) ─
WALL_DIR="$HOME/Videos/wallpapers"
FALLBACK_WALL=""             # optional; empty = no fallback
MONITORS=()                  # empty = auto-detect all via hyprctl
STRETCH_MODE=false           # true = one mpvpaper spanning the full virtual desktop
IDLE_THRESHOLD=300           # seconds (5 min) of inactivity = stop
CHECK_INTERVAL=3             # seconds between checks

# ── Internal state (do not modify) ─────────────────────────────────────────
STATE_DIR="/tmp/test_wall"
PIDFILE="$STATE_DIR/mpvpaper.pid"
DAEMON_PIDFILE="$STATE_DIR/daemon.pid"
STATUSFILE="$STATE_DIR/status"
LOGFILE="$STATE_DIR/test_wall.log"

CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/mpvpaper"
CONFIG_FILE="$CONFIG_DIR/live_wall.conf"

# ── Load user config ───────────────────────────────────────────────────────
load_config() {
  [ -f "$CONFIG_FILE" ] || return 0
  # Read each non-empty, non-comment line as KEY=VALUE
  while IFS= read -r line; do
    case "$line" in
      ''|\#*) continue ;;
    esac
    # support both "KEY=value" and "export KEY=value"
    case "$line" in
      export\ *) eval "${line#export }" ;;
      *)        eval "$line" ;;
    esac
  done < "$CONFIG_FILE"
}

load_config
mkdir -p "$STATE_DIR"
: > "$LOGFILE"

log() { printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*" >> "$LOGFILE"; }

# ── Distro detection ───────────────────────────────────────────────────────
detect_distro() {
  if [ -r /etc/os-release ]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    DISTRO_ID="${ID:-unknown}"
    DISTRO_LIKE="${ID_LIKE:-}"
  else
    DISTRO_ID="unknown"
    DISTRO_LIKE=""
  fi

  # Map to a package manager family for installing packages
  case "$DISTRO_ID" in
    arch|manjaro|endeavour|garuda|cachyos) PKG_FAMILY="arch" ;;
    debian|ubuntu|pop|linuxmint|elementary|zorin) PKG_FAMILY="debian" ;;
    fedora|nobara|rhel|centos|rocky|almalinux) PKG_FAMILY="fedora" ;;
    opensuse*|suse*) PKG_FAMILY="suse" ;;
    *)
      case "$DISTRO_LIKE" in
        *arch*) PKG_FAMILY="arch" ;;
        *debian*) PKG_FAMILY="debian" ;;
        *fedora*|*rhel*) PKG_FAMILY="fedora" ;;
        *suse*) PKG_FAMILY="suse" ;;
        *) PKG_FAMILY="unknown" ;;
      esac
      ;;
  esac
}

have() { command -v "$1" >/dev/null 2>&1; }

# ── Check / install dependencies ───────────────────────────────────────────
check_deps() {
  local missing_pkg=()

  # Tools that should always be present (coreutils / bash)
  for c in bash find sort sed cp; do
    have "$c" || missing_pkg+=("$c (coreutils/bash)")
  done

  # ffmpeg + ffprobe (transcode_wall.sh)
  have ffmpeg  || missing_pkg+=("ffmpeg")
  have ffprobe || missing_pkg+=("ffprobe (ships with ffmpeg)")

  # live_wall.sh specific
  have hyprctl || missing_pkg+=("hyprctl (ships with hyprland)")
  have jq     || missing_pkg+=("jq")
  have loginctl || missing_pkg+=("loginctl (ships with systemd)")

  # mpvpaper
  if have mpvpaper; then
    log "mpvpaper: $(mpvpaper --version 2>&1 | head -1)"
  else
    missing_pkg+=("mpvpaper")
  fi

  echo "${missing_pkg[@]+${missing_pkg[*]}}"
  return 0
}

install_pkg_native() {
  # Install a single package via the native package manager for the family.
  # $1 = package name
  local pkg="$1"
  case "$PKG_FAMILY" in
    arch)
      sudo pacman -S --needed --noconfirm "$pkg"
      ;;
    debian)
      sudo apt-get update
      sudo apt-get install -y "$pkg"
      ;;
    fedora)
      sudo dnf install -y "$pkg"
      ;;
    suse)
      sudo zypper install -y "$pkg"
      ;;
    *)
      echo "ERROR: cannot install '$pkg' - unknown package family ($PKG_FAMILY)"
      return 1
      ;;
  esac
}

ensure_aur_helper() {
  # On Arch without an AUR helper: install yay (or use paru if already present).
  if have yay; then
    AUR_HELPER="yay"
    return 0
  fi
  if have paru; then
    AUR_HELPER="paru"
    return 0
  fi
  echo "Arch-based distro detected but no AUR helper found."
  echo "Installing yay from AUR..."
  local tmp
  tmp=$(mktemp -d)
  (
    cd "$tmp"
    sudo pacman -S --needed --noconfirm git base-devel
    git clone https://aur.archlinux.org/yay.git
    cd yay
    makepkg -si --noconfirm
  )
  AUR_HELPER="yay"
  rm -rf "$tmp"
}

install_mpvpaper_arch() {
  ensure_aur_helper
  $AUR_HELPER -S --noconfirm mpvpaper
}

build_mpvpaper_from_source() {
  echo "mpvpaper must be built from source."
  echo "Source: https://github.com/GhostNaN/mpvpaper"
  echo "Dependencies: mpv, wlroots"
  echo "Build tools: ninja, meson, libmpv (libmpv-dev / mpv-dev)"
  echo
  read -rp "Build and install mpvpaper from source now? [Y/n] " ans
  [[ "$ans" =~ ^[Nn] ]] && { echo "Skipped."; return 1; }

  for c in git meson ninja; do
    have "$c" || { echo "ERROR: missing build tool: $c"; return 1; }
  done

  local tmp
  tmp=$(mktemp -d)
  (
    cd "$tmp"
    git clone --single-branch --depth 1 https://github.com/GhostNaN/mpvpaper
    cd mpvpaper
    meson setup build --prefix=/usr/local
    ninja -C build
    sudo ninja -C build install
  )
  local rc=$?
  rm -rf "$tmp"
  return $rc
}

# ── install subcommand ─────────────────────────────────────────────────────
cmd_install() {
  detect_distro
  echo "Detected distro: $DISTRO_ID (family: $PKG_FAMILY)"

  # Ask about monitors before installing so we can write it to config immediately.
  echo
  echo "Which monitors should the wallpaper run on?"
  echo "  - Enter a comma-separated list (e.g. eDP-1,HDMI-A-1)"
  echo "  - Leave blank to use ALL connected monitors"
  echo "  - Find monitor names with: hyprctl monitors"
  read -rp "Monitors: " monitors_input

  echo
  read -rp "Stretch one wallpaper across all monitors instead of per-monitor? [y/N] " stretch_input
  if [[ "$stretch_input" =~ ^[Yy] ]]; then
    STRETCH_MODE=true
  fi

  # What's missing?
  local missing=()
  while IFS= read -r m; do
    [ -n "$m" ] && missing+=("$m")
  done < <(check_deps)

  if [ "${#missing[@]}" -eq 0 ]; then
    echo "All dependencies already installed."
  else
    echo
    echo "Missing dependencies:"
    for m in "${missing[@]}"; do echo "  - $m"; done
    echo
    echo "Planned install actions for $PKG_FAMILY:"
    for m in "${missing[@]}"; do
      case "$m" in
        mpvpaper)
          if [ "$PKG_FAMILY" = "arch" ]; then
            echo "  - mpvpaper (via AUR helper)"
          else
            echo "  - mpvpaper (build from source: https://github.com/GhostNaN/mpvpaper)"
          fi
          ;;
        ffmpeg|ffprobe*)
          case "$PKG_FAMILY" in
            arch)   echo "  - $m (pacman -S ffmpeg)" ;;
            debian) echo "  - $m (apt install ffmpeg)" ;;
            fedora) echo "  - $m (dnf install ffmpeg)" ;;
            suse)   echo "  - $m (zypper install ffmpeg)" ;;
            *)      echo "  - $m (unknown - please install manually)" ;;
          esac
          ;;
        *coreutils*|*bash*) echo "  - $m (should be preinstalled; if not: install coreutils/bash)" ;;
        jq)
          case "$PKG_FAMILY" in
            arch|debian|fedora|suse) echo "  - jq (native repo)" ;;
            *) echo "  - jq (install via package manager)" ;;
          esac
          ;;
        *hyprland*|*hyprctl*)
          echo "  - hyprland - WARNING: not in most distro repos. See https://hyprland.org"
          ;;
        *systemd*|*loginctl*) echo "  - $m (systemd; preinstalled on most distros)" ;;
        *) echo "  - $m" ;;
      esac
    done
    echo
    read -rp "Proceed with installation? [Y/n] " ans
    [[ "$ans" =~ ^[Nn] ]] && { echo "Aborted."; exit 1; }
  fi

  # Run the actual installs.
  for m in "${missing[@]}"; do
    case "$m" in
      mpvpaper)
        if [ "$PKG_FAMILY" = "arch" ]; then
          install_mpvpaper_arch || { echo "mpvpaper install failed"; exit 1; }
        else
          build_mpvpaper_from_source || { echo "mpvpaper build failed"; exit 1; }
        fi
        ;;
      ffmpeg)
        [ "$PKG_FAMILY" != "unknown" ] && install_pkg_native ffmpeg || { echo "Install ffmpeg manually"; exit 1; }
        ;;
      ffprobe*) [ "$PKG_FAMILY" != "unknown" ] && install_pkg_native ffmpeg ;;
      jq)       [ "$PKG_FAMILY" != "unknown" ] && install_pkg_native jq ;;
      *coreutils*|*bash*) echo "Note: $m should be present. If not, install via your package manager." ;;
      *systemd*|*loginctl*) echo "Note: $m (systemd) should be present by default." ;;
      *hyprland*|*hyprctl*)
        echo "Skipping hyprland install - it's typically not in distro repos."
        echo "Install manually: https://hyprland.org"
        ;;
    esac
  done

  # Write config.
  write_config "$monitors_input"

  echo
  echo "Install complete."
  echo "Config written to: $CONFIG_FILE"
  echo "Run './live_wall.sh' to start the daemon."
}

write_config() {
  local monitors_input="$1"
  mkdir -p "$CONFIG_DIR"
  {
    echo "# live_wall.sh configuration"
    echo "# Generated by ./live_wall.sh install on $(date)"
    echo
    echo "WALL_DIR=\"$WALL_DIR\""
    if [ -n "$FALLBACK_WALL" ]; then
      echo "FALLBACK_WALL=\"$FALLBACK_WALL\""
    else
      echo "# FALLBACK_WALL=\"\""
    fi
    echo "STRETCH_MODE=$STRETCH_MODE"
    echo "IDLE_THRESHOLD=$IDLE_THRESHOLD"
    echo "CHECK_INTERVAL=$CHECK_INTERVAL"
    if [ -n "$monitors_input" ]; then
      echo "MONITORS=($monitors_input)"
    else
      echo "# MONITORS=(eDP-1 HDMI-A-1)   # empty = auto-detect all"
    fi
  } > "$CONFIG_FILE"
}

# ── Monitor selection ──────────────────────────────────────────────────────
resolve_monitors() {
  if [ "${#MONITORS[@]}" -gt 0 ]; then
    printf '%s\n' "${MONITORS[@]}"
    return
  fi
  # Auto-detect via hyprctl.
  if have hyprctl && have jq; then
    hyprctl -j monitors 2>/dev/null | jq -r '.[].name'
  else
    log "WARN: cannot auto-detect monitors (missing hyprctl or jq)"
    return
  fi
}

# ── Pick random wall ───────────────────────────────────────────────────────
pick_wall() {
  if [ ! -d "$WALL_DIR" ]; then
    log "WARN: WALL_DIR '$WALL_DIR' does not exist"
    printf '%s' "$FALLBACK_WALL"
    return
  fi
  local pick
  pick=$(find "$WALL_DIR" -type f -iname '*.mp4' \
           ! -path "$WALL_DIR/scripts/*" 2>/dev/null | shuf -n 1)
  if [ -z "$pick" ] && [ -n "$FALLBACK_WALL" ] && [ -f "$FALLBACK_WALL" ]; then
    pick="$FALLBACK_WALL"
  fi
  printf '%s\n' "$pick"
}

# ── start / stop mpvpaper ──────────────────────────────────────────────────
start_wall() {
  # Guard: if mpvpaper is already running, do nothing.
  if pgrep -x mpvpaper >/dev/null 2>&1; then
    pgrep -x mpvpaper | head -1 > "$PIDFILE"
    return 0
  fi
  if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
    return 0
  fi

  local wall
  wall="$(pick_wall)"
  if [ -z "$wall" ]; then
    log "WARN: no wallpaper found in '$WALL_DIR' and no FALLBACK_WALL set"
    return 1
  fi
  log "START: $wall"

  local new_pids=()
  if [ "$STRETCH_MODE" = true ]; then
    # One mpvpaper spanning the entire virtual desktop (no monitor argument).
    mpvpaper "$wall" \
      --layer background \
      --fork \
      --auto-pause \
      --mpv-options="--hwdec=vaapi --hwdec-codecs=all \
                      --vo=gpu-next --gpu-api=vulkan \
                      --no-audio --loop --panscan=1" \
      >> "$LOGFILE" 2>&1 &
    new_pids+=($!)
  else
    # One mpvpaper per configured monitor.
    local mon
    while IFS= read -r mon; do
      [ -z "$mon" ] && continue
      mpvpaper "$mon" "$wall" \
        --layer background \
        --fork \
        --auto-pause \
        --mpv-options="--hwdec=vaapi --hwdec-codecs=all \
                        --vo=gpu-next --gpu-api=vulkan \
                        --no-audio --loop --panscan=1" \
        >> "$LOGFILE" 2>&1 &
      new_pids+=($!)
    done < <(resolve_monitors)
  fi

  if [ "${#new_pids[@]}" -eq 0 ]; then
    log "WARN: no monitors resolved, mpvpaper not started"
    return 1
  fi

  # Save all PIDs as a comma-separated list.
  ( IFS=,; echo "${new_pids[*]}" ) > "$PIDFILE"
  echo "running" > "$STATUSFILE"

  sleep 1
  local all_alive=true
  for p in "${new_pids[@]}"; do
    if ! kill -0 "$p" 2>/dev/null; then
      log "WARN: mpvpaper pid $p died right after start"
      all_alive=false
    fi
  done
  if [ "$all_alive" = false ]; then
    log "WARN: some mpvpaper processes died, backing off 5s"
    rm -f "$PIDFILE"
    echo "stopped" > "$STATUSFILE"
    sleep 5
  fi
}

stop_wall() {
  if [ ! -f "$PIDFILE" ]; then
    echo "stopped" > "$STATUSFILE"
    return 0
  fi

  local pid_line p
  pid_line=$(cat "$PIDFILE")
  IFS=',' read -ra pids <<< "$pid_line"
  for p in "${pids[@]}"; do
    [ -z "$p" ] && continue
    if kill -0 "$p" 2>/dev/null; then
      log "STOP: killing mpvpaper (pid $p)"
      kill "$p" 2>/dev/null
      pkill -P "$p" 2>/dev/null
      sleep 0.2
      kill -9 "$p" 2>/dev/null
    fi
  done
  # Safety net: kill any remaining mpvpaper processes.
  pkill -x mpvpaper 2>/dev/null
  rm -f "$PIDFILE"
  echo "stopped" > "$STATUSFILE"
}

# ── logind session id ──────────────────────────────────────────────────────
get_session_id() {
  loginctl list-sessions --no-legend 2>/dev/null \
    | awk -v uid="$UID" '
        $2==uid && $4=="seat0" {print $1; found=1; exit}
        END { if (!found) exit 1 }' \
    || loginctl list-sessions --no-legend 2>/dev/null \
       | awk -v uid="$UID" '$2==uid {print $1; exit}'
}

# ── Hyprland IPC state queries ─────────────────────────────────────────────
should_pause() {
  # 1) Are you at the session? (not suspended/locked)
  local sid sess_state
  sid=$(get_session_id)
  if [ -z "$sid" ]; then
    log "PAUSE: no session for user $USER"
    return 0
  fi
  sess_state=$(loginctl show-session "$sid" -p State --value 2>/dev/null)
  if [ "$sess_state" != "active" ]; then
    log "PAUSE: session $sid state=$sess_state"
    return 0
  fi

  # 2) Is the active window fullscreen?
  local fs
  fs=$(hyprctl -j activewindow 2>/dev/null \
       | jq -r '.fullscreen // 0' 2>/dev/null)
  if [ -n "$fs" ] && [ "$fs" != "0" ] && [ "$fs" != "null" ]; then
    log "PAUSE: fullscreen mode $fs"
    return 0
  fi

  # 3) Is focus on one of the configured monitors?
  local focus_mon monitors_text
  focus_mon=$(hyprctl -j monitors 2>/dev/null \
              | jq -r --argjson aw "$(hyprctl -j activewindow 2>/dev/null)" \
                  '(.[] | select(.id == $aw.monitor) | .name) // ""' 2>/dev/null)
  if [ -z "$focus_mon" ]; then
    focus_mon=$(hyprctl -j activewindow 2>/dev/null \
                | jq -r '(.monitor // 0)' 2>/dev/null)
    if [ -n "$focus_mon" ] && [ "$focus_mon" != "null" ]; then
      focus_mon=$(hyprctl -j monitors 2>/dev/null \
                  | jq -r --argjson mid "$focus_mon" \
                      '(.[] | select(.id == $mid) | .name) // ""' 2>/dev/null)
    fi
  fi

  monitors_text=$(resolve_monitors)
  if [ -z "$focus_mon" ] || ! printf '%s\n' "$monitors_text" | grep -Fxq "$focus_mon"; then
    log "PAUSE: focus on '$focus_mon' (want one of: $(printf '%s' "$monitors_text" | tr '\n' ','))"
    return 0
  fi

  return 1
}

# ── Idle detection ─────────────────────────────────────────────────────────
is_idle() {
  local sid idle_hint
  sid=$(get_session_id)
  [ -z "$sid" ] && return 1

  idle_hint=$(loginctl show-session "$sid" -p IdleSinceHint --value 2>/dev/null)
  if [ -z "$idle_hint" ] || [ "$idle_hint" = "0" ] || ! [[ "$idle_hint" =~ ^[0-9]+$ ]]; then
    return 1
  fi

  local now_us idle_us diff_s
  now_us=$(date +%s%6N)
  idle_us="$idle_hint"
  diff_s=$(( (now_us - idle_us) / 1000000 ))
  [ "$diff_s" -ge "$IDLE_THRESHOLD" ]
}

# ── Main loop ──────────────────────────────────────────────────────────────
run_daemon() {
  log "=== live_wall daemon start (user=$USER, monitors=$(resolve_monitors | tr '\n' ','), stretch=$STRETCH_MODE, idle=${IDLE_THRESHOLD}s) ==="

  if ! command -v jq >/dev/null; then
    log "FATAL: jq not found"
    exit 1
  fi
  if ! command -v hyprctl >/dev/null; then
    log "FATAL: hyprctl not found (is Hyprland installed?)"
    exit 1
  fi
  if ! command -v mpvpaper >/dev/null; then
    log "FATAL: mpvpaper not found. Run './live_wall.sh install' first."
    exit 1
  fi

  # Record our own PID so start/stop/status can identify the daemon
  # reliably (pgrep -f "live_wall.sh" would also match this very
  # status/start/stop invocation's command line and always report
  # "running").
  echo "$$" > "$DAEMON_PIDFILE"
  trap 'rm -f "$DAEMON_PIDFILE"' EXIT

  # Safety: kill any old mpvpaper on start.
  pkill -x mpvpaper 2>/dev/null
  rm -f "$PIDFILE"
  echo "stopped" > "$STATUSFILE"

  if ! should_pause && ! is_idle; then
    start_wall
  else
    log "INIT: starting in stopped state"
  fi

  while true; do
    if should_pause || is_idle; then
      stop_wall
    else
      start_wall
    fi
    sleep "$CHECK_INTERVAL"
  done
}

# ── Control subcommands ────────────────────────────────────────────────────
daemon_pid() {
  # Prints the running daemon's PID and returns 0, or returns 1 if not running.
  [ -f "$DAEMON_PIDFILE" ] || return 1
  local pid
  pid=$(cat "$DAEMON_PIDFILE" 2>/dev/null)
  [ -n "$pid" ] || return 1
  if kill -0 "$pid" 2>/dev/null; then
    echo "$pid"
    return 0
  fi
  # Stale pidfile from a crashed/killed daemon.
  rm -f "$DAEMON_PIDFILE"
  return 1
}

cmd_start() {
  if daemon_pid >/dev/null; then
    echo "live_wall is already running."
    return 0
  fi
  nohup "$0" >> "$LOGFILE" 2>&1 &
  echo "live_wall started (pid $!)"
}

cmd_stop() {
  local pid
  if pid=$(daemon_pid); then
    kill "$pid" 2>/dev/null
    sleep 0.2
    kill -9 "$pid" 2>/dev/null
  fi
  # Safety net for any daemon started before this pidfile mechanism existed.
  pkill -f "live_wall\.sh$" 2>/dev/null
  pkill -x mpvpaper 2>/dev/null
  rm -f "$PIDFILE" "$DAEMON_PIDFILE"
  echo "stopped" > "$STATUSFILE"
  echo "live_wall stopped."
}

cmd_restart() {
  cmd_stop
  sleep 1
  cmd_start
}

cmd_status() {
  if pgrep -x mpvpaper >/dev/null 2>&1; then
    echo "mpvpaper: running"
  else
    echo "mpvpaper: stopped"
  fi
  if daemon_pid >/dev/null; then
    echo "daemon:   running"
  else
    echo "daemon:   stopped"
  fi
  echo "config:   $CONFIG_FILE $([ -f "$CONFIG_FILE" ] && echo "(present)" || echo "(not found, using defaults)")"
  echo "WALL_DIR: $WALL_DIR"
  echo "monitors: $(resolve_monitors | tr '\n' ',' | sed 's/,$//')"
  echo "stretch:  $STRETCH_MODE"
}

# ── usage ──────────────────────────────────────────────────────────────────
usage() {
  cat <<EOF
live_wall.sh - wallpaper that only runs while you're actively watching

Usage:
  live_wall.sh                  run daemon in foreground (default)
  live_wall.sh start            run daemon in background
  live_wall.sh stop             stop daemon and mpvpaper
  live_wall.sh restart          restart
  live_wall.sh status           print status
  live_wall.sh install          detect distro, ask about monitors, install deps
  live_wall.sh --help           this help

Config (optional):  ~/.config/mpvpaper/live_wall.conf
Variables:          WALL_DIR, FALLBACK_WALL, MONITORS=(), STRETCH_MODE,
                    IDLE_THRESHOLD, CHECK_INTERVAL

To find monitor names and resolutions, run: hyprctl monitors
EOF
}

# ── main entry ─────────────────────────────────────────────────────────────
case "${1:-}" in
  "")            run_daemon ;;
  start)         cmd_start ;;
  stop)          cmd_stop ;;
  restart)       cmd_restart ;;
  status)        cmd_status ;;
  install)       cmd_install ;;
  -h|--help|help) usage ;;
  *)
    echo "Unknown subcommand: $1" >&2
    usage
    exit 2
    ;;
esac
