# Changelog

All notable changes to Tentacle are documented here.

## 1.0.1 — 2026-08-12

### Fixed

- Tab count badges (Errors, Groups, Slow) no longer read as tab number keys. Each count now renders in its own italic gold style instead of inheriting the tab label style, and a `·` separator binds the count to its own tab, so `4:Errors·20` cannot be misread as a tab `20`. The count keeps the active tab's chip background, and the tab row occupies exactly the same width as before.

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
