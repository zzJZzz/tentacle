# Tentacle

**Heroku logs, untangled.**

*A terminal-first Heroku log parser for debugging production.*

Tentacle is a local, fullscreen TUI for investigating Heroku logs without leaving the terminal. It runs **one** `heroku logs --tail` subprocess, parses each line once, and gives you focused views, grouped errors, release/deploy context, incident/reproduction sessions, request correlation, slow-request tracking, a compact live health dashboard, persistent mute rules, and a redacted LLM-ready export.

**Ruby 3.3+ · macOS / Linux / WSL · MIT licensed**

Tentacle is intentionally **keyboard-first** and **read-only**. It does not restart dynos, change config, modify releases, connect directly to your database, send telemetry, or upload logs anywhere.

## Quick start

If Ruby 3.3+, Git, and the Heroku CLI are already installed:

```bash
heroku login
git clone YOUR_REPOSITORY_URL tentacle
cd tentacle
./bin/setup
tentacle YOUR_HEROKU_APP
```

Replace `YOUR_REPOSITORY_URL` with this repository's clone URL. The detailed macOS and Linux/WSL setup below covers installing prerequisites and shell `PATH` configuration.

Built with:

- **[Bubble Tea Ruby](https://github.com/marcoroth/bubbletea-ruby)** — application/event loop
- **[Bubbles Ruby](https://github.com/marcoroth/bubbles-ruby)** — spinner, scrollable viewports, and shared key/help hints
- **[Lipgloss Ruby](https://github.com/marcoroth/lipgloss-ruby)** — tabs, badges, panels, selected rows, and adaptive light/dark styling
- **[NTCharts Ruby](https://github.com/marcoroth/ntcharts-ruby)** — live request/error/slow-request sparklines
- **Heroku CLI** — live logs and read-only release metadata

## Requirements

Before running Tentacle you need:

- **[Ruby](https://www.ruby-lang.org/) 3.3 or newer**. Ruby **3.4+ is recommended** because Ruby 3.3 is now in security-maintenance mode.
- **Bundler**. `bin/setup` installs it if it is missing.
- **[Heroku CLI](https://devcenter.heroku.com/articles/heroku-cli)** available as `heroku` in your `PATH`.
- **An authenticated Heroku CLI session** (`heroku login`).
- **Git**, which the Heroku CLI also requires.
- **Access to the Heroku app** whose logs you want to inspect.
- A terminal with ANSI support. macOS Terminal/iTerm2, modern Linux terminals, Windows Terminal + WSL, and tmux are good fits.

Verify the important pieces before launching:

```bash
ruby --version
git --version
heroku --version
heroku auth:whoami
```

### Authentication behavior

Tentacle performs a non-interactive Heroku authentication preflight **before** Bubble Tea takes control of the terminal. If you are logged out, Tentacle exits with a clear message telling you to run:

```bash
heroku login
```

It does **not** allow the Heroku CLI's interactive browser-login prompt to open inside the TUI. This avoids terminal/raw-mode failures such as `process.stdin.setRawMode is not a function`.

## Install

Clone or download the repository, then run the setup script from the project directory.

### macOS

Install a supported Ruby and the Heroku CLI. With Homebrew:

```bash
brew install ruby
brew install heroku/brew/heroku
```

Homebrew may install Ruby outside the default shell `PATH`. If `ruby --version` still shows Apple's system Ruby, add Homebrew Ruby first:

```bash
# zsh (~/.zshrc)
export PATH="$(brew --prefix ruby)/bin:$PATH"

# bash (~/.bashrc or ~/.bash_profile)
export PATH="$(brew --prefix ruby)/bin:$PATH"
```

For fish (`~/.config/fish/config.fish`):

```fish
fish_add_path (brew --prefix ruby)/bin
```

Reload your shell, authenticate Heroku, then install Tentacle:

```bash
# zsh
source ~/.zshrc
# bash (use one of these depending on where you added PATH)
source ~/.bashrc
source ~/.bash_profile

ruby --version
heroku login
heroku auth:whoami

cd tentacle
chmod +x bin/setup bin/tentacle
./bin/setup
```

Make sure `~/.local/bin` is in your `PATH`:

```bash
# zsh (~/.zshrc) or bash (~/.bashrc / ~/.bash_profile)
export PATH="$HOME/.local/bin:$PATH"
```

For fish:

```fish
fish_add_path $HOME/.local/bin
```

### Linux / WSL

Install Ruby **3.3+** using your preferred Ruby manager/package manager, then install the Heroku CLI using Heroku's Linux instructions. Authenticate before launching Tentacle:

```bash
ruby --version
heroku --version
heroku login
heroku auth:whoami
```

Then:

```bash
cd tentacle
chmod +x bin/setup bin/tentacle
./bin/setup
```

Make sure `~/.local/bin` is in your `PATH`:

```bash
# zsh (~/.zshrc) or bash (~/.bashrc / ~/.bash_profile)
export PATH="$HOME/.local/bin:$PATH"
```

For fish:

```fish
fish_add_path $HOME/.local/bin
```

### Verify Tentacle

```bash
tentacle --version   # tentacle 1.0.0
tentacle YOUR_HEROKU_APP
```

`bin/setup` checks the Ruby version and that the Heroku CLI exists. Tentacle itself checks authentication before starting the fullscreen UI.

## Choose the Heroku app

There is **no hardcoded Heroku app**. Pass the app you want to inspect when you start the tool:

```bash
tentacle my-production-app
```

The explicit Heroku-style flag works too:

```bash
tentacle --app my-production-app
# or
tentacle -a my-production-app
```

If you run `tentacle` without an app, it exits with usage instructions instead of connecting to somebody else's default app.

You can still set reusable personal defaults with environment variables if you want:

```bash
export TENTACLE_APP="my-production-app"
export TENTACLE_MAX_LINES="5000"
export TENTACLE_SLOW_MS="1000"
```

fish equivalent:

```fish
set -gx TENTACLE_APP "my-production-app"
set -gx TENTACLE_MAX_LINES "5000"
set -gx TENTACLE_SLOW_MS "1000"
```

A positional app or `--app` value overrides `TENTACLE_APP` for that run.

## CLI options

| Option | Purpose |
|---|---|
| `-a APP`, `--app APP` | Select the Heroku app |
| `--max-lines N` | Maximum log lines kept in memory; default `5000` |
| `--slow-ms N` | Slow-request threshold in milliseconds; default `1000` |
| `--no-color` | Disable ANSI colors |
| `-v`, `--version` | Print the Tentacle version |
| `-h`, `--help` | Print command-line help |

Environment equivalents are `TENTACLE_APP`, `TENTACLE_MAX_LINES`, and `TENTACLE_SLOW_MS`. `NO_COLOR` also disables ANSI colors. Invalid negative thresholds or non-positive buffer sizes are rejected before the TUI starts.

## Views

| Key | View | What it does |
|---|---|---|
| `1` | **Overview** | Health snapshot with request/error/slow sparklines and top recurring errors |
| `2` | **All** | Every buffered log line |
| `3` | **Web** | Web dyno activity; best first stop when reproducing a request bug |
| `4` | **Errors** | Chronological application exceptions, 5xxs, H-codes, and database failures |
| `5` | **Groups** | Repeated errors grouped by exception/H-code/status/message |
| `6` | **Slow** | Requests whose `service=` time exceeds the configured threshold |
| `7` | **Worker** | Background jobs / worker dynos |
| `8` | **Heroku** | Router/platform output, H-codes, restarts, warnings |
| `9` | **Database** | PostgreSQL and MySQL/MariaDB-related log output and database-side failures |

Every view has a one-line description directly below the tabs and above the search/filter line.

## Security & privacy

`tentacle` is intentionally **read-only** with respect to Heroku. It starts one live log stream with:

```bash
heroku logs --tail --app APP
```

and reads recent release metadata with:

```bash
heroku releases --json -n 20 --app APP
```

It does not change config, restart dynos, modify releases, connect directly to databases, or issue write operations against your app. It also has **no telemetry** and does not upload logs to a hosted service.

The `L` action builds an LLM-ready package **locally and copies it to your clipboard**; it does not contact an LLM or API. That export masks the Heroku app name and redacts common credential shapes, URL credentials, Bearer tokens, cookies/sessions, database/Redis URLs, and email addresses. Redaction is best-effort, not a guarantee: production logs can contain business data or PII in arbitrary formats, so review the payload before pasting it into any external service.

The `y` and `Y` copy actions are intentionally **raw** for local debugging and do not apply LLM redaction.

Muted error groups are stored locally per app under `~/.config/tentacle/` with user-only file permissions. Release author email addresses are not retained by the application.

This is an independent community tool and is not affiliated with or endorsed by Heroku or Salesforce.

## Controls

Press **`?` from anywhere** for full in-app help. The bottom footer always shows the controls relevant to the current view.

| Key | Action |
|---|---|
| `1`–`9` | Select a view |
| `Tab` / `Shift-Tab` | Next / previous view |
| `↑` / `↓`, `j` / `k` | Move the highlighted selection |
| `PgUp` / `PgDn` | Page |
| `g` / `Home` | Jump to oldest / first item |
| `G` / `End` / `f` | Jump to newest and resume following live logs |
| `n` / `N` | Jump to next / previous **unmuted** error in the current view |
| `Enter` | Inspect selected event; in Groups, open occurrences |
| `m` | Mute/unmute the selected error group |
| `M` | In Groups, show/hide muted groups |
| `s` | Start/stop an incident reproduction session |
| `i` | Toggle incident-only scope |
| `r` | Show buffered lines for selected `request_id` |
| `/` | Search/filter current view |
| `x` | Clear active search |
| `y` | Copy request ID, or raw line if no request ID |
| `Y` | Copy full raw log line |
| `L` | Copy a redacted, LLM-ready diagnostic context |
| `d` | Toggle dual-screen mode: normal UI left, LLM copy preview right |
| `Esc` | Go back from a nested view; from the main view, quit |
| `Space` | Pause/resume consuming new logs |
| `c` | Clear in-memory buffer |
| `R` | Restart/reconnect the Heroku stream |
| `?` | Show/hide help |
| `q` | Quit when not typing in search |
| `Ctrl-C` | Quit immediately |

## Database log view

`9 Database` keeps the same chronological log-list UI as the other raw views. It does not connect to a database or call a database add-on API; it only classifies lines already present in the Heroku log stream.

The parser currently recognizes PostgreSQL and MySQL/MariaDB signatures. Database identity is tracked separately from the dyno/source category, so an application-generated database failure can stay a `WEB` or `WORK` event while also appearing in Database:

```text
10:43:16 WEB    [PG]    PG::QueryCanceled: canceling statement due to statement timeout
10:43:20 WORK   [MYSQL] Mysql2::Error: Lock wait timeout exceeded
10:43:24 PG     [PG]    FATAL: remaining connection slots are reserved...
```

This matters for open-source use: an app without PostgreSQL or MySQL still works normally. If no matching lines are in the current buffer, Database simply shows `No database-related log lines detected.`

Recognized signals include native database process/source names plus strong application error signatures such as `PG::...`, `Mysql2::...`, PostgreSQL connection/timeout messages, MySQL/MariaDB connection errors, lock timeouts, and deadlocks.

## Selection and investigation

The currently selected line is deliberately obvious:

```text
▶ 18:35:04 WEB    ActiveRecord::RecordNotFound ...
```

With color enabled the whole row receives a strong Lipgloss highlight. The footer also shows where you are:

```text
selected 42/318 · ↑↓ select · Enter detail · n/N error · f follow ...
```

When live follow is active it says `FOLLOW`. The moment you move up/down, follow mode turns off so new logs do not steal your selection. Press `f`, `G`, or `End` to return to the newest line and follow again.

Press `Enter` on a selected event to see:

- parsed timestamp/source/process/status/method/path/service time
- request ID
- error classification/group
- full raw line
- **±3 nearby buffered lines** for immediate context
- related buffered lines sharing the same request ID

## Search

On a log view, press `/` and type:

```text
🔎 checkout▌  Enter apply · Esc cancel · Ctrl-U clear
```

Results preview live while typing. `Enter` keeps the filter; `Esc` restores the filter that existed before you opened search.


## Copy for an LLM

Press **`L`** from the normal views or event detail to copy a ready-to-paste troubleshooting package to your clipboard. It includes:

- Heroku app and current view
- incident/session state and current search
- request, error, muted-error, and slow-request counts
- release context
- the top recurring unmuted error groups
- selected-event metadata when an event is selected
- up to the last **80 relevant log lines** from the current investigation context
- a short analysis request telling the LLM to identify likely root causes, cite evidence, separate facts from guesses, and prioritize safe troubleshooting steps

The export masks the app name and redacts common secret shapes before copying, including passwords, tokens, API/access keys, authorization values, cookies/sessions, database/Redis URLs, Bearer credentials, credentials embedded in URLs, and email addresses. Redaction is a safety net, not a guarantee, so still review sensitive production data before sharing it outside your approved tools.

Clipboard support is automatic when one of these is available:

```text
WSL / Windows   clip.exe
macOS           pbcopy
Wayland         wl-copy
X11             xclip
```

After pressing `L`, paste into the LLM normally (`Ctrl-V`, `Cmd-V`, etc.).

## Dual-screen mode

Press **`d`** to split the terminal into two panes:

```text
┌──────────────────────────────────────┬──────────────────────────────┐
│ normal Heroku investigation UI       │ LLM COPY PREVIEW             │
│                                      │                              │
│ logs / errors / groups / detail      │ app + health summary         │
│ selection stays keyboard-driven      │ release + error groups       │
│                                      │ selected event + log context │
│                                      │                              │
│                                      │ L copies the full package    │
└──────────────────────────────────────┴──────────────────────────────┘
```

The right pane is a preview of the same redacted context copied by `L`; the clipboard receives the full package even when the preview cannot show every line. Dual-screen requires a terminal at least **120 columns** wide. Press `d` again to return to the normal single-pane layout.

## Incident / reproduction sessions

This is designed for the workflow: **alert arrives → open `tentacle` → start a session → reproduce the bug in the browser → inspect only what happened during that reproduction**.

Press `s` when you are about to reproduce the problem. `tentacle` inserts a visible local marker into the buffered stream:

```text
──────── INCIDENT STARTED · 16:22:03 ────────
```

The status line also becomes explicit:

```text
● INCIDENT ACTIVE · started 16:22:03 · 1m 14s · all logs · s stops · i toggles scope
```

Press `s` again when you are finished reproducing. An `INCIDENT ENDED` marker is inserted and the session boundary is frozen. Logs received after that point are outside the session.

Press `i` to toggle **incident-only scope**. When it is on:

- All/Web/Worker/Heroku/Database/Slow show only lines received during the current reproduction session
- Errors shows only errors from the session, while keeping the session markers visible
- Groups recomputes counts from only the session, so old production noise does not dominate the repro
- Overview metrics/charts are recomputed from only the incident window
- searches and `n`/`N` error navigation operate inside the scoped view

The boundary is based primarily on **buffer position** — what arrived after you pressed `s` — rather than trusting Heroku timestamps alone. This is deliberate because log delivery can be slightly out of order.

Starting another incident with `s` makes the new session the active scope; older marker lines remain in the raw buffer as history. Clearing the buffer with `c` also resets the current incident.

## Mute / ignore known noise

Press `m` on an error or error group to mute that exact group. Mutes are saved per Heroku app in:

```text
~/.config/tentacle/muted-groups.json
```

Muted groups are intentionally **not deleted**:

- hidden from the high-signal **Errors** and default **Groups** views
- excluded from Overview error counts/charts and `n` / `N` error jumps
- still visible, dimmed, in raw **All / Web / Worker / Database** views
- recoverable in **Groups** by pressing `M`, then selecting the `[MUTED]` group and pressing `m` again

This is meant for known recurring noise such as a harmless database probe or repeated application exception that would otherwise dominate incident debugging.

## Release / deploy context

At startup, `tentacle` runs:

```bash
heroku releases --json -n 20 --app APP
```

The release context line beneath the incident status shows the latest release before the selected event, for example:

```text
🚀 v418 Deploy 8f31dbe · selected 7m after · success
```

Event detail also includes `Prior release` and `After release` fields. This makes it easier to answer "did this begin right after a deploy/config change?" when opening the tool from an error alert.

If a deploy happens while the tool is open, matching `app[api]` deploy/release lines in the live Heroku stream are highlighted as `RELEASE` events in the raw log views.

`R` refreshes both release history and the live log stream.

## Error groups

The Groups view combines repeated failures, for example:

```text
▶    12  NoMethodError
      6  Heroku H12
      4  Postgres: permission denied for database "postgres"
      3  HTTP 500
```

Select a group and press `Enter` to see occurrences. Select an occurrence and press `Enter` again for detail, then `r` to correlate its request ID.

## Overview and charts

The Overview is designed to answer “does production look unhealthy right now?” quickly.

It shows:

- buffered event count
- request count
- error count
- slow-request count
- requests in the latest minute bucket
- **Requests / min** sparkline
- **Errors / min** sparkline
- **Slow / min** sparkline
- top recurring error groups

Charts use the most recent 24 one-minute buckets present in the buffered logs.

## Slow requests

The default slow threshold is 1000 ms:

```bash
tentacle --slow-ms 750
```

or:

```bash
export TENTACLE_SLOW_MS=750
```

fish equivalent:

```fish
set -gx TENTACLE_SLOW_MS 750
```

## Terminal polish

The UI stays keyboard-first and logs-focused, using a few focused Charm Ruby components for polish:

- **Bubbles Spinner** for the startup `CONNECTING` state
- **Bubbles Viewport** for scrollable event detail and help content
- **Bubbles Key + Help** to generate compact footer hints from shared key definitions
- **Lipgloss AdaptiveColor** so the palette remains readable on both light and dark terminal backgrounds
- **ntcharts Sparkline** remains the compact Overview visualization and still falls back cleanly if the native chart extension is unavailable
- startup uses **Bubbletea.batch** so release history and the Heroku log stream begin connecting together

These are presentation and orchestration improvements only. Tentacle still runs a single `heroku logs --tail --app APP` stream and remains a log investigation tool.

## Tests

```bash
ruby -Itest/support test/parser_test.rb
ruby -Itest/support test/app_test.rb
ruby -Itest/support test/mute_store_test.rb
ruby -Itest/support test/release_history_test.rb
ruby -Itest/support test/stream_test.rb
ruby -Itest/support test/preflight_test.rb
```

## Architecture

```text
heroku logs --tail --app APP
            │
            ▼
       LogStream
            │ one line at a time
            ▼
         Parser
            │
            ▼
      in-memory events             heroku releases --json
            │                              │
            │                              ▼
            │                        release context
            │                              │
  ┌─────────┼──────────┬────────┬───────┬─────────┐
Overview   Web       Errors    Groups   Slow      ...
  │          │
  │          └── LLM context builder → redaction → clipboard / dual-screen preview
  └── NTCharts metrics

Lipgloss styles tabs, status, panels, incident/release markers, muted noise, and the active keyboard selection
Bubble Tea handles keys, resize, and stream commands
```

## Roadmap

Tentacle 1.0 intentionally keeps the interface keyboard-first and the runtime scope logs-only. Possible future polish includes:

- optional mouse support, including clickable tabs and mouse-wheel scrolling, while preserving every keyboard workflow
- easier package-manager / gem installation so cloning the repository is not required
- additional database-engine log classifiers when there are strong, reliable log signatures
- small accessibility and terminal-compatibility improvements that do not add diagnostic bloat

Roadmap items are intentionally non-binding; the project should stay focused on fast, read-only Heroku log investigation.

## Contributing

Issues and pull requests are welcome. Tentacle intentionally stays focused on **read-only Heroku log investigation**: keep features logs-first, avoid app/company-specific assumptions, and add parser or UI regression coverage for behavior changes.

See [CHANGELOG.md](CHANGELOG.md) for release history.

## License

Tentacle is released under the [MIT License](LICENSE).

Tentacle is an independent community tool and is not affiliated with or endorsed by Heroku or Salesforce.
