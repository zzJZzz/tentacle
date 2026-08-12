# Changelog

All notable changes to Tentacle are documented here.

## 1.0.0 — 2026-08-12

First stable public release.

### Highlights

- Keyboard-first fullscreen Heroku log investigation with focused Web, Errors, Groups, Slow, Worker, Heroku, and Database views.
- PostgreSQL and MySQL/MariaDB log classification without connecting directly to a database.
- Incident/reproduction sessions, request correlation, release context, persistent mute rules, and live overview sparklines.
- Redacted LLM-ready clipboard export plus dual-screen preview.
- Non-interactive Heroku authentication preflight before the TUI starts.
- Adaptive terminal colors and scrollable detail/help views.
- Read-only Heroku behavior, no telemetry, and no automatic log uploads.
- macOS, Linux, and WSL installation guidance.
- MIT license.

### 1.0 stability polish

- Added clear validation for invalid `--max-lines` and `--slow-ms` values.
- Added public-facing Quick Start, CLI option reference, roadmap, and release documentation.
- Kept mouse/clickable navigation out of 1.0 to preserve the focused keyboard-first interface.
