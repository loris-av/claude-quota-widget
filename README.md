# Claude Quota — KDE Plasma widget

A panel/desktop widget for KDE Plasma that tracks your **Claude usage** — both the
rolling **5-hour window** and the **weekly** limit — at a glance.

It has two data sources:

- **online** — your *real* claude.ai utilization percentages (the same numbers
  shown on the claude.ai *Settings → Usage* page and by Claude Code's `/usage`).
- **local** — an offline estimate computed from your local Claude Code
  transcripts via [`ccusage`](https://github.com/ryoppippi/ccusage). Always works,
  no credentials, but it's a *proxy* (see [How it works](#how-it-works)).

![screenshot](docs/screenshot.png)

---

## Features

- **Online mode mirrors `/usage`:** one bar per limit the API reports — current
  session, current week (all models), current week per scoped model (e.g. Fable) —
  with true percentages, reset times in your own timezone, and your overage-credit
  balance. Titles and ordering come from the API, so a limit Anthropic starts
  returning shows up without a widget update.
- **Local mode** shows token counts, cost, burn rate, and a **projection / ETA-to-limit
  early warning** ("⚠ cap in ~22m") so you know *before* you get throttled.
- **`auto` mode:** use online when available, fall back to local automatically.
- **Stable layout under rate limits:** the endpoint rate-limits well below a
  per-minute poll, so a successful response is cached and replayed when the API
  refuses — same bars, badge showing the reading's age ("● live · 3m ago") —
  instead of the card flipping to the local layout every other tick.
- Compact panel view (session % · week %) that expands to the full card, fronted by
  a pixel-art Claude mascot that waves every so often. It is drawn as a grid of
  rectangles, not an image, so it stays sharp at any panel height and costs nothing
  between waves.
- Everything configurable from the widget's own settings dialog.

## Requirements

- **KDE Plasma 5** (built and tested on 5.27; Plasma 6 would need minor QML import changes).
- `bash`, `curl`, `node`, `jq`. Note that Plasma runs the widget with the *session*
  `PATH`, not your shell rc — the script therefore looks for `node`/`ccusage` in the
  usual per-user runtime locations too (nvm, fnm, bun, volta, asdf, mise, n, nodenv).
- For **local** mode: [`ccusage`](https://github.com/ryoppippi/ccusage). No install
  needed if you have `npx` (it's fetched on demand); for speed, `npm i -g ccusage`.
- For **online** mode: [Claude Code](https://claude.com/claude-code) logged in on the
  same machine (the widget reuses its login token — see [Online mode](#online-mode)).

## Install

### One-liner (always the latest)

```bash
curl -L https://github.com/DdeDamian/claude-quota-widget/releases/latest/download/claude-quota.plasmoid -o /tmp/claude-quota.plasmoid \
  && kpackagetool5 --type Plasma/Applet --install /tmp/claude-quota.plasmoid
```

`claude-quota.plasmoid` is a stable, version-less asset on every release, so that URL
always points at the newest build. To upgrade later, swap `--install` for `--upgrade`.

### From a release (manual)

Download `claude-quota.plasmoid` (or the versioned `claude-quota-X.Y.plasmoid`) from the
[Releases](../../releases) page, then either:

```bash
kpackagetool5 --type Plasma/Applet --install claude-quota.plasmoid
```

…or in the GUI: right-click panel/desktop → **Add Widgets** → **Get New Widgets** →
**Install Widget From Local File…** → pick the `.plasmoid` (on most setups you can also
just double-click the file).

### From source

```bash
git clone https://github.com/DdeDamian/claude-quota-widget.git
cd claude-quota-widget
./install.sh
```

Then add it: right-click your panel or desktop → **Add Widgets** → search **"Claude Quota"**.

## Configuration

Right-click the widget → **Configure Claude Quota**.

**General**
- **Data source** — `local`, `online`, or `auto` (default).
- **Refresh interval** — seconds between updates (default 60).
- **5h / Weekly limit** — token caps used as the % denominators in *local* mode.
  Leave `0` to auto-size against the p90 of your history.

**Online data**
- Nothing required — online mode reuses your Claude Code login token automatically.
- *Override (optional):* a pasted Bearer token (must have the `user:profile` scope).

## Modes

### Online mode

Online mode calls Claude's internal usage endpoint:

```
GET https://api.anthropic.com/api/oauth/usage
    Authorization:     Bearer <token>
    anthropic-beta:    oauth-2025-04-20
    anthropic-version: 2023-06-01
```

The `<token>` is read from your local Claude Code credentials
(`~/.claude/.credentials.json` → `claudeAiOauth.accessToken`). That token carries the
`user:profile` scope the endpoint requires and is auto-refreshed by Claude Code as you
use it. The response carries a `limits` array — the same one `/usage` renders — plus
the overage-credit balance:

```json
{
  "limits": [
    { "kind": "session",       "percent": 20, "resets_at": "…T16:59:59Z", "scope": null },
    { "kind": "weekly_all",    "percent": 36, "resets_at": "…T12:59:59Z", "scope": null },
    { "kind": "weekly_scoped", "percent": 10, "resets_at": "…T12:59:59Z",
      "scope": { "model": { "display_name": "Fable" } } }
  ],
  "extra_usage": { "is_enabled": true, "monthly_limit": 10000, "used_credits": 0.0, "currency": "EUR" }
}
```

Each entry becomes one titled bar. `kind` and `scope` produce the label
(`session` → "Current session", `weekly_all` → "Current week (all models)",
`weekly_scoped` → "Current week (Fable)"); an unrecognised `kind` is still shown,
labelled from its own fields rather than dropped. Reset times are rendered in your
local timezone, which is named under each bar. The extra-usage line only appears
once there is a credit limit or spend to report.

The older top-level `five_hour` / `seven_day` objects are still read as a fallback,
so the widget keeps working if `limits` disappears.

Auth: a pasted Bearer token override if you set one, otherwise the Claude Code login
token. When the endpoint answers with an error of its own — a rate limit, a rejected
token — the widget reports that reason rather than guessing.

**Rate limiting.** This endpoint tolerates far fewer calls than one per minute; a 60s
poll gets `429` most of the time (Claude Code queries it too). Hence the 5-minute
default interval, and hence the cache: the last good *raw* response is kept and, when a
call fails, re-rendered so every derived value (reset times, minutes left) is recomputed
against the current clock — only the utilization figures are as old as the badge says.
Past `CLAUDE_QUOTA_ONLINE_MAX_AGE` (default 3600s) the cache is abandoned and `auto`
drops to the local estimate.

> **Note:** `claude setup-token` tokens are *inference-scoped* and lack `user:profile`,
> so they are rejected (403) by this endpoint. Use the Claude Code login token (the default).

### Local mode

Local mode runs `ccusage` over `~/.claude/projects/**/*.jsonl` — the transcripts Claude
Code writes as you work, each of which records its own token usage. It sums those and
buckets them into the 5-hour and weekly windows.

Because the local data has no notion of your account's real limit, the **percentage is a
proxy**: it's your token total divided by a denominator. By default that denominator is
the **p90 of your historical windows** (robust against one-off huge sessions); you can
set an explicit cap in Configure once you learn where you actually hit limits.

The raw `ccusage` scan is cached for 30s to avoid re-reading your transcripts every tick,
and is handed to `node` as a file path — a busy `~/.claude` produces a scan larger than
`MAX_ARG_STRLEN` (128 KiB), which would fail as a command-line argument.

The week-start field is read as `week` (ccusage 18.x) with `period` accepted as a
fallback for older builds.

## Privacy & security

- **Local mode is fully offline** — it only reads files on your machine and makes no
  network calls (pricing uses `ccusage`'s bundled `--offline` table).
- **Online mode** reads your Claude Code login token from `~/.claude/.credentials.json`
  on each refresh and sends it **only** to `api.anthropic.com` over HTTPS — the same
  place Claude Code itself sends it. The token is never logged, printed, or sent anywhere
  else. Credentials entered in the config dialog are stored in plain text in your local
  plasma config, same as any other widget setting.

## Building

```bash
./build.sh        # produces claude-quota-<version>.plasmoid
./tests/run-tests.sh   # data-source tests (no network, no ccusage needed)
```

The tests drive `claude-quota-json` against recorded API bodies in `tests/fixtures/`
via `CLAUDE_QUOTA_USAGE_FILE`, and the local path against pre-seeded cache files.

CI (`.github/workflows/build.yml`) validates the package and builds the `.plasmoid` on
every PR; pushing a `vX.Y` tag also attaches the built `.plasmoid` to a GitHub release.

## Layout

```
package/
  metadata.json              # plasmoid manifest
  contents/
    ui/main.qml              # the widget (compact + full views)
    ui/ClaudeMascot.qml      # panel icon: pixel mascot, drawn as a grid
    ui/configGeneral.qml     # Configure → General page
    ui/configOnline.qml      # Configure → Online data page
    config/config.qml        # config category registration
    config/main.xml          # config keys + defaults
    scripts/claude-quota-json# data-source: emits the JSON the widget renders
tests/
  run-tests.sh               # data-source tests
  fixtures/                  # recorded API bodies + ccusage scans
```

The QML never talks to the network itself — it just runs the bundled script on an
interval and renders the JSON it prints.

## Disclaimer

This is an **unofficial** tool, not affiliated with or endorsed by Anthropic. The online
endpoint (`/api/oauth/usage`) is **undocumented** and reverse-engineered from Claude Code;
it can change or break at any time, in which case `auto` mode keeps working via the local
estimate. Use it for your own account only.

The panel icon is a pixel rendition of the Claude mascot, included to identify the
service the widget reports on. "Claude" and the mascot are Anthropic's; they are not
covered by this project's MIT licence, and their use here implies no endorsement.

## License

[MIT](LICENSE)
