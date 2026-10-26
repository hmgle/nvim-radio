# Changelog

All notable changes to this project are documented in this file. The format
follows Keep a Changelog, and the project adheres to Semantic Versioning.

## [Unreleased]

### Fixed

- Run automatic recording recovery only while holding the exclusive
  session lock, preserving live recordings in shared or forced sessions.
- Use Unicode lowercase mappings consistently for search indexes, queries,
  language and tag filters, and facets; upgrade existing derived text.
- Show complete recording IDs in command listings so they can be copied
  directly into playback and removal commands.
- Track original partial paths and remove superseded sidecars after
  metadata recovery. Keep cleanup failures retryable and verify ownership
  before cleaning sidecars for older records.
- Always settle catalog sync after storage errors, even when saving the
  diagnostic report also fails, so later sync attempts can proceed.
- Preserve existing sidecar JSON on write, close, or rename failures.
  Report metadata errors and keep recovery retryable until repair succeeds.
- Refresh open recording lists on creation, completion, and deletion,
  including the published path, without querying on progress ticks.
- Preserve Ex-escaped spaces and backslashes in recording output paths;
  reject extra durations, unknown options, and repeated output options.
- Keep recording cleanup and completion callbacks running after database
  write failures; report persistence errors and retain recovery metadata.
- Treat JSON null values from radio-cli as absent optional fields.
- Render multiline station data and recording errors safely in browser
  lists, details, the status HUD, and statusline.
- Preserve recording indexes on file deletion errors other than ENOENT;
  share deletion behavior between the browser and public API.
- Remove plugin-owned keymaps when repeated setup disables or changes them,
  preserving user replacements and buffer-local mappings.
- Support Neovim 0.10 filesystem statistics without a `frsize` field.
- Restore `false` as the disabled global keymap value, report zero-byte
  recordings explicitly, and avoid adopting a mismatched final recording file
  during recovery.
- Use an `interrupted` recording state for interrupted writers and fall back
  to unnormalized playback when the normalization capability probe times out.
- Preserve optional recording fields (`track`, `final_path`, `stopped_at`,
  `media_duration_ms`, and `error`) in model and database round trips.
- Upgrade schema v2 databases with populated stations; make the URL
  backfill transactional and restore finalizing recordings on startup.
- Replace PID-file ownership with the same kernel `flock` on
  `run/media.lock` as radio-cli. Concurrent processes cannot both acquire
  a session; the OS releases ownership after a crash. The lock inode stays
  in place, and `single_instance = false` still disables exclusion.
- Ignore successful and failed station refreshes from superseded playback
  requests. Cancel discovery, catalog requests, and probes on shutdown
  before their continuations can access closed storage.
- Bound dead-station refresh to one attempt per playback request.
- Share cancellable probe ownership between playback and independent
  recordings, including backup attempts; starting a second probe is busy.
- Track each recording finalizer and retired player until it completes.
  Older recordings cannot overwrite a newer recording's status or path.
- Use real elapsed time for ffmpeg's three-second SIGINT grace period.
  Reap the child before verification and close its process/stderr handles.
- On shutdown timeout, cancel verification, preserve the partial recording
  and recovery metadata, and kill outstanding writers. Keep storage and
  the session lock until all child writers and players have exited.
- Send mpv's quit command, complete startup cancellation exactly once,
  wait for child exit before notifying close waiters, and release process,
  timer, connection, and IPC handles.
- Generate recording/station UUIDs and fixed-length mpv socket suffixes
  from OS randomness. Lua PRNG seeds cannot repeat persistent IDs, and
  socket suffixes cannot randomly exceed the path-length limit.
- Report missing-curl and ffprobe failures through callbacks; enforce
  probe timeouts and suppress cancelled results.
- Refresh the browser on the main loop, unsubscribe when its window
  closes, and recreate it with its engine. Bootstrap and catalog changes
  populate an already-open list; recording timers update once per second.
- Honor `resume = false`, restore playback with `resume = true`, and
  restore the browsed source with `resume = "selection"`.
- Truncate names by UTF-8 characters, parse recording output directories
  without consuming them as durations, and make favorite add/remove
  operations idempotent.

### Added

- Prefix search and page navigation for country, language, and tag values.
- Fault injection, radio-cli JSON fixtures, and CI coverage for Neovim
  0.10.0 and the latest stable release.
- Result paging with `L` / `H` / PageDown / PageUp and a visible range.
- Unsubscribe functions returned by engine status subscriptions.
- Offline regression coverage for separate-process lock contention and
  crash release, stale network responses, overlapping finalizers,
  cancelled verification, delayed child exits, repeated mpv sessions,
  SIGINT-ignoring ffmpeg, browser replacement, paging, and command parsing.

### Changed

- Skip redundant station writes during catalog publication and refresh
  search statistics in one SQL transaction. Add a manual sync benchmark
  with 50,000 synthetic stations. Catalog publication remains synchronous.

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
