# Changelog

All notable changes to this project are documented in this file. The format
follows Keep a Changelog, and the project adheres to Semantic Versioning.

## [Unreleased]

### Fixed

- Recording metadata no longer disappears: `track`, `final_path`,
  `stopped_at`, `media_duration_ms`, and `error` were dropped by the model
  constructors, so songs, durations, errors, and publication targets were
  lost in the database and in recovery. Both constructors copy through an
  explicit field list.
- Databases from schema v2 with stations upgrade again; the migration called
  `primary_url` without `self` and now runs inside one transaction.
- `Recorder.recover` publishes `finalizing` recordings instead of failing
  with `final_path_missing` (the call passed shifted arguments).
- A failing `ffprobe` no longer crashes inside its own error handler (it
  called `table.concat` on a string), and probes honor their timeout.
- Recording finalization verifies asynchronously instead of blocking the
  editor for up to two seconds.
- The session lock no longer calls the nonexistent `vim.uv.fs_readfile`, so
  a leftover pidfile cannot block startup. It honors `single_instance`,
  checks the `uv.kill` return value, treats zombies as dead, takes over
  stale locks, and releases the lock only while it names this process.
- Stopping playback invalidates stale player callbacks and cancels a pending
  reconnect, so a late callback cannot resurrect playback.
- A station whose directory refresh keeps returning the same dead URL
  refreshes once per play request instead of looping.
- Shutdown waits for the recording to finish publishing before closing the
  database and releasing the lock.
- The mpv `quit` command is delivered before the closing guard engages, so
  shutdown no longer waits for the 800 ms SIGKILL fallback; player handles
  (timers, connect retries, pipes) are released completely.
- The browser refreshes from the main loop instead of the HTTP callback's
  fast-event context (E5560), subscribes to engine status for a live
  header, and pages through results with `L` / `H`.
- Station and track names truncate by UTF-8 characters instead of bytes.
- `:RadioRecord 30m --output-dir DIR` no longer treats the directory as the
  duration, and `:RadioFavorites add|remove` no longer toggles.

### Added

- Result paging in the browser with the range shown in the header.
- `resume = true` restores the last station; `resume = "selection"` restores
  the last browsed source.
- Regression suite covering field persistence, schema migration, session
  locks, session isolation, refresh bounds, shutdown finalization, probe
  failures, paging, and command arguments.

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
