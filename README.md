# nvim-radio

A terminal radio player for Neovim, modeled on
[radio-cli](https://github.com/hmgle/radio-cli). A Neovim Lua plugin is the
controller, `mpv` is an independent playback process, and `ffmpeg` is an
independent recording process. No account or API key is required.

- Browse the [Radio Browser](https://www.radio-browser.info/) catalog, search
  locally (case-insensitive, Chinese territory names included), filter by
  country, language, tag, and minimum bitrate, and sort by clicks, votes,
  bitrate, or name.
- Play any HTTP(S) stream or a saved custom station with backup URLs; keep
  favorites, history, custom stations, and recordings in a local SQLite
  database that radio-cli can also read.
- Record MP3, AAC, Vorbis, and Opus streams as stream copies with metadata,
  a JSON sidecar, and crash recovery.
- Keyboard-first floating-window browser, a statusline component, and a status
  HUD. Zero plugin dependencies.

**English** | [简体中文](README.zh-CN.md)

## Requirements

| Requirement | Notes |
| --- | --- |
| Neovim 0.10+ | LuaJIT build (FFI is used for SQLite) |
| `mpv` | Playback, driven over its JSON IPC socket |
| `ffmpeg`, `ffprobe` | Recording and stream probing |
| `libsqlite3` | Shared library for the FFI binding |
| `curl` | Radio Browser API access |

Run `:RadioDoctor` to verify the host.

## Installation

[lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  "hmgle/nvim-radio",
  opts = {
    volume = 80,
    keys = {
      toggle = "<leader>r",
      pause = "<leader>rp",
      record = "<leader>rr",
      status = "<leader>rs",
    },
  },
  cmd = { "Radio", "RadioPlay", "RadioSync", "RadioRecord" },
}
```

With `mini.deps`:

```lua
MiniDeps.add("hmgle/nvim-radio")
require("radio").setup({ volume = 80 })
```

## Quick start

```vim
:Radio              " open the station browser
:RadioSync          " fetch the Radio Browser catalog
:RadioPlay <UUID>   " play a saved station (or any http(s) URL)
:RadioStatus        " playback/recording HUD
:RadioDoctor        " diagnostics
```

The browser opens with the current filters applied. Press `i` to search, `F`
to filter, `Enter` to play, `r` to record, `q` to close. Results are paged
(`L` / `H`), and the header tracks playback and recording live. `:RadioSync`
downloads the catalog in pages of 1000 stations and publishes it atomically;
a shrink larger than 25 % is rejected unless confirmed.

## Browser keys

| Key | Action |
| --- | --- |
| `Enter` / `o` / double-click | Play the selection |
| `i` / `/` | Search the local catalog |
| `F` | Country / language / tag / minimum-bitrate filters |
| `s` | Cycle sort: clickcount, name, bitrate, votes, random |
| `n` | Play a random station using the current filters |
| `f` | Favorite / unfavorite |
| `r` | Start / stop recording the playing station |
| `R` / `F5` | Sync the catalog / refresh the list |
| `[` / `]` | Previous / next source: stations, favorites, history, custom, recordings |
| `L` / `H`, `PageDown` / `PageUp` | Next / previous page of results |
| `y` / `Y` | Yank the UUID / stream URL (or recording ID / path) |
| `d` | Delete a recording (with confirmation) |
| `O` | Open the recordings directory |
| `q` / `Esc` | Close |

## Commands

| Command | Purpose |
| --- | --- |
| `:Radio` | Toggle the browser |
| `:RadioPlay <UUID\|URL>` | Play a station or an HTTP(S) stream |
| `:RadioStop` / `:RadioPause` / `:RadioMute` | Playback control |
| `:RadioVolume <+n\|-n\|n>` | Adjust or set the volume |
| `:RadioRecord [DURATION] [--output-dir DIR]` | Record the playing station |
| `:RadioRecordStop` | Stop and publish the recording |
| `:RadioRandom [QUERY]` | Random station, optional query |
| `:RadioSync` | Sync the catalog |
| `:RadioStatus` | Status HUD |
| `:RadioDoctor` | Diagnostics |
| `:RadioDevices` | List mpv audio output devices |
| `:RadioFavorites [add\|remove <UUID>]` | Manage favorites |
| `:RadioHistory` | Recent successful plays |
| `:RadioRecordings [list\|play ID\|remove ID [--index-only]]` | Manage recordings |
| `:RadioStationAdd <NAME> <URL>` | Add a custom station |
| `:RadioStationRemove <UUID>` | Remove a custom station |
| `:RadioOpenRecordings` | Open the recordings directory |

`DURATION` accepts `30`, `45s`, `10m`, and `2h`, from 1 second to 365 days.

## Configuration

`setup()` options with defaults:

```lua
require("radio").setup({
  mpv = "mpv",
  ffmpeg = "ffmpeg",
  ffprobe = "ffprobe",
  volume = 80,
  normalize_loudness = false,   -- mpv dynaudnorm
  audio_device = nil,           -- e.g. "alsa/plughw:CARD=USB,DEV=0"
  playback_timeout_secs = 12,
  resume = false,               -- false | true | "selection"
  api_url = nil,                -- pin a Radio Browser server
  connect_timeout_secs = 5,
  request_timeout_secs = 20,
  auto_sync_days = 7,           -- 0 disables background sync
  recording_dir = nil,          -- default <data_dir>/recordings
  probe_timeout_secs = 5,
  recording_min_free_mb = 16,
  language = nil,               -- "en" | "zh-CN" (default: environment)
  single_instance = true,       -- OS file lock, shared with radio-cli
  debug = false,
  data_dir = nil,               -- default $XDG_DATA_HOME/nvim-radio
  keys = {},                    -- opt-in global keymaps
  ui = { width = 0.8, height = 0.8, border = "rounded", preview = true },
})
```

The configuration is a Lua table rather than radio-cli's `config.toml`; the
keys match radio-cli's TOML settings one-for-one. Global keymap names are
`toggle`, `pause`, `mute`, `volume_up`, `volume_down`, `record`, `status`,
`random`, and `stop`; all default to unset.

### Paths

| Item | Path |
| --- | --- |
| Data directory | `$XDG_DATA_HOME/nvim-radio` (`$NVIM_RADIO_DATA_DIR` overrides) |
| Database | `<data_dir>/radio.db` |
| Recordings | `<data_dir>/recordings/` |
| Runtime (sockets, lock) | `<data_dir>/run/` |

## Statusline

```lua
-- lualine
require("lualine").setup({
  sections = {
    lualine_x = { function()
      return require("radio").statusline()
    end },
  },
})
```

Or with the built-in statusline:

```lua
vim.o.statusline = "%f %m %= %{v:lua.require('radio').statusline()}"
```

## Recording

Recording is a stream copy: audio is not re-encoded. The codec is probed
before recording starts and selects the container.

| Stream codec | Output |
| --- | --- |
| MP3 | `.mp3` |
| AAC (including HLS AAC) | `.aac` |
| Vorbis | `.ogg` |
| Opus | `.opus` |

Each recording starts as a `.part` file, is verified with `ffprobe` after the
stop, and is published without overwriting existing files. A JSON sidecar
records station, track, timestamps, codec, duration, size, and reconnect
count. Interrupted recordings keep their partial file; they are marked
`interrupted` and recovered on the next start. Switching stations ends the
current recording. Pausing playback does not pause recording.

## Lua API

```lua
local radio = require("radio")

radio.setup({ volume = 70 })
radio.play("https://example.com/live.mp3")     -- URL or station UUID
radio.pause()
radio.volume(5)
radio.record("30m")                            -- radio.record_stop() to finish
radio.random({ query = "jazz", country = "FR" })
radio.sync({ accept_shrink = false })
radio.stations({ query = "news", limit = 20 }) -- returns stations, total
radio.favorites()
radio.history()
radio.recordings()
radio.station_add("My Station", "https://example.com/live", { "https://example.com/backup" })
radio.statusline()
```

## Differences from radio-cli

- Configuration is `setup{}` in Lua, not `config.toml`.
- Server discovery uses the `all.api.radio-browser.info` mirror list directly;
  radio-cli additionally tries a DNS SRV lookup first. Same server set in
  practice.
- Artwork rendering, the TUI, shell completions, and the man page are
  radio-cli features with no Neovim equivalent here.
- Session exclusivity uses the same `flock` on `<data_dir>/run/media.lock`
  as radio-cli. Ownership is released by the OS after exit or a crash; the
  lock file stays in place. `single_instance = false` disables exclusion.
- The database schema matches radio-cli's, so both tools can share a data
  directory (only one media session at a time).

## Development

```sh
stylua --check lua plugin tests
nvim --headless -l tests/run.lua                    # full suite
NVIM_RADIO_TESTS=test_player nvim --headless -l tests/run.lua
```

Tests use an in-process HTTP server and real `mpv`/`ffmpeg`/`ffprobe`; the
directory tests use a fake Radio Browser server, so no network access is
required except for optional live checks.

## License

MIT, see [LICENSE](LICENSE). The bundled Chinese country/region name table is
covered by the [Unicode License V3](LICENSE.unicode).
