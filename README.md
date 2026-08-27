![](preview.gif)
# Live_Wall
Wallpaper daemon for Hyprland that runs `mpvpaper` only when you're actively at
your desk, plus a helper script to transcode 4K+ wallpapers down to your
monitor's resolution using HEVC.  
Transcoding wallpapers will reduce CPU usage and file size.  
### **This script supports only .mp4 files**
## Scripts

- **`live_wall.sh`** — daemon that starts/stops `mpvpaper` based on focus,
  fullscreen state, suspend/lock, and idle time. Auto-discovers monitors via
  `hyprctl monitors` and supports stretching one wallpaper across the entire
  virtual desktop.
- **`transcode_wall.sh`** — finds large video files in your wallpaper folder
  and transcodes them with `libx265` to a target resolution. Files already
  smaller than the target are just copied.

## License

GPL-3.0-or-later. See [`LICENSE`](LICENSE).

This license was chosen because the scripts shell out to GPL-licensed
programs:

| Tool      | License    |
|-----------|------------|
| [mpvpaper](https://github.com/GhostNaN/mpvpaper)  | GPL-3.0    |
| [mpv](https://github.com/mpv-player/mpv)       | GPL-2.0    |
| [ffmpeg](https://github.com/ffmpeg/ffmpeg)    | GPL-2.0+ |
| [wlroots](https://gitlab.freedesktop.org/wlroots/wlroots)   | MIT        |

The scripts themselves are not derivative works of these tools (they only
invoke them as separate processes), so other licenses would also be
legally defensible. GPL-3.0-or-later keeps the scripts aligned with the
most restrictive dependency and matches the ecosystem.

## Acknowledgements

Portions of this code were developed with AI assistance (Claude by
Anthropic, accessed via Claude Code).

## Requirements

### live_wall.sh

- Hyprland (provides `hyprctl`)
- `mpvpaper` — https://github.com/GhostNaN/mpvpaper
- `jq`, `bash`, `find`, `sort`, `sed`, `cp`, `loginctl` (systemd)

### transcode_wall.sh

- `ffmpeg` (with `libx265` enabled — this is the default in distro packages)
- `ffprobe` (ships with `ffmpeg`)
- `bash`, `find`, `sort`, `sed`, `cp`

## Installation

The easiest path is the built-in installer, which detects your distro,
prompts for missing pieces, and writes a config file:

```bash
git clone https://github.com/FrederikFazberovic/Live_Wall.git
cd ./Live_Wall/
chmod +x ./live_wall.sh 
chmod +x ./transcode_wall.sh 
./live_wall.sh install
```

The installer handles:

- **Arch / Manjaro / Endeavour / etc.**: `mpvpaper` from AUR via `yay`
  (or `paru` if `yay` is missing — it installs `yay` first).
- **Debian / Ubuntu / Fedora / openSUSE**: tries the system package manager
  first; falls back to building `mpvpaper` from source if it's not in
  the repos. See https://github.com/GhostNaN/mpvpaper for build deps.
- **Other deps** (`ffmpeg`, `jq`, etc.) are installed via your distro's
  native package manager.

During install you'll be asked:

1. Which monitors to use (comma-separated list, e.g. `eDP-1,HDMI-A-1`,
   or blank for all connected monitors — find names with `hyprctl monitors`).
2. Whether to stretch one wallpaper across all monitors (vs. one per
   monitor).

The installer writes `~/.config/mpvpaper/live_wall.conf` with your choices.

## Autostart
Add this into your hyprland config file:
 ```bash 
hl.on("hyprland.start", function()
    hl.exec_cmd("path/to/live_wall.sh")
end)
```
Change **path/to/live_wall.sh** with your **actual path**.

## Configuration

Config file: `~/.config/mpvpaper/live_wall.conf` (optional — defaults
are baked into the scripts).

Format: one `KEY=VALUE` per line. Lines starting with `#` are comments.

```bash
WALL_DIR="$HOME/Videos/wallpapers"
FALLBACK_WALL=""                # optional, used if WALL_DIR is empty
MONITORS=(eDP-1 HDMI-A-1)       # empty = auto-discover all
STRETCH_MODE=false              # true = one mpvpaper spanning all
IDLE_THRESHOLD=300              # seconds of idle = stop
CHECK_INTERVAL=3                # seconds between checks
```

For `transcode_wall.sh`, the same config can override `RESOLUTION`,
`SRC`, and `DST`.

## Usage

### live_wall.sh

```bash
./live_wall.sh                  # run daemon in foreground
./live_wall.sh start            # run daemon in background
./live_wall.sh stop
./live_wall.sh restart
./live_wall.sh status
./live_wall.sh install
./live_wall.sh --help
```

When the daemon is running, `mpvpaper` is only active when:

- The session is `active` (not suspended/locked).
- No window is fullscreen on the configured monitor(s).
- The active window's monitor is in your `MONITORS` list (or any monitor
  if the list is empty).
- You haven't been idle for longer than `IDLE_THRESHOLD` seconds.

### transcode_wall.sh

```bash
./transcode_wall.sh                                # scan ~/Videos/wallpapers
./transcode_wall.sh --dry-run                      # preview only
./transcode_wall.sh --resolution 3840x2160         # custom target
./transcode_wall.sh --list-resolutions             # print hyprctl monitor info
./transcode_wall.sh --ext mkv --ext mp4            # only certain extensions
./transcode_wall.sh --src=/some/dir --dst=/out     # custom paths
./transcode_wall.sh "file:///path/with%20space.mkv"  # specific file (URI)
./transcode_wall.sh --from-stdin < list.txt        # paths/URIs from stdin
./transcode_wall.sh --from-file list.txt           # paths/URIs from a file
```

`RESOLUTION` defaults to `1920x1080`. Set it in the config file or with
`--resolution WIDTHxHEIGHT`. Files smaller than the target resolution
in either dimension are simply copied to the output directory.

To find your monitor's resolution, run `hyprctl monitors`.

## Finding monitor info

```bash
hyprctl monitors
```

Look for the `monitor` lines — the name (e.g. `eDP-1`) goes in
`MONITORS=`, the `1920x1080` value (or similar) goes in `RESOLUTION`.

## Notes on mpvpaper

`mpvpaper` is not in standard distro repos outside of AUR. On Arch-based
systems the installer uses `yay`/`paru`. On other distros the installer
will clone https://github.com/GhostNaN/mpvpaper and build with
`meson`/`ninja` if your package manager doesn't have it. Build
dependencies: `mpv` (libmpv), `wlroots`, `meson`, `ninja`.
