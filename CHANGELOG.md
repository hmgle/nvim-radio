# Changelog

All notable changes to this project are documented in this file. The format
follows Keep a Changelog, and the project adheres to Semantic Versioning.

## [0.1.0] - 2026-10-24

Initial release: a Neovim Lua radio player modeled on radio-cli.

### Added

- mpv playback over its JSON IPC socket with the same startup flags as
  radio-cli: ICY/track metadata, pause, mute, volume, audio device selection,
  and loudness normalization when the build provides dynaudnorm.
- Playback resilience: stream candidates (resolved URL, raw URL, backups),
  reconnect backoff of 1/3/7 seconds with a six-per-minute budget, directory
  refresh of stale stations, and random-station fallback.
- ffmpeg recording as a stream copy with codec probing (mp3, aac/adts,
  vorbis/ogg, opus), `.part` staging, progress and reconnect tracking,
  graceful SIGINT stop, ffprobe verification, atomic publication, JSON
  sidecars, and crash recovery on start.
- SQLite persistence via a LuaJIT FFI binding with radio-cli's schema v5:
  stations, favorites, history (capped at 1000), custom stations with backup
  URLs, recordings, meta, and facet counts. FTS5 trigram search candidates
  with a LIKE-based fallback.
- Radio Browser catalog sync: server discovery, single-request bootstrap,
  paged sync with staging, shrink protection above 25 %, station refresh,
  and click reporting.
- Chinese territory names widen text searches ("刚果" matches both Congos).
- Floating-window browser with sources, search, filters, sorting, favorites,
  recordings management, and a details preview pane.
- Statusline component and a status HUD.
- `:Radio` command family and an opt-in global keymap set.
- `:RadioDoctor` diagnostics for tools, paths, free space, database, and
  catalog state.
- Headless test suite covering store, player, recorder, directory, engine,
  and UI against local HTTP servers with real mpv/ffmpeg/ffprobe.

### Differences from radio-cli

- Lua `setup()` configuration instead of `config.toml`.
- HTTP mirror-list server discovery instead of a DNS SRV lookup first.
- pidfile session lock instead of flock.
- No artwork rendering, TUI, shell completions, or man page.

[0.1.0]: https://github.com/hmgle/nvim-radio/releases/tag/v0.1.0
