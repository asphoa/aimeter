# AIMeter

v1.0.34 centralises configuration in `ConfigStore`, routes refreshes through
`RefreshCoordinator` (per-account slots, manual coalescing, generation checks),
and runs subprocesses via `ProcessRunner` (monotonic deadlines, SIGTERM→SIGKILL,
output caps). See `VERSION`.

A macOS menu bar app that shows how much of each AI service you have left —
Claude Code, Codex, Antigravity, OpenRouter, DeepSeek, and whatever is loaded
into local inference right now — as a two-ring icon you can read without
clicking anything.

Menu bar only. `LSUIElement` is set, so there is no Dock icon and no Cmd-Tab
entry.

```
   ◎    outer ring = the primary service's 5-hour pool
        inner ring = its weekly pool
        ink below 70%, amber from 70%, red from 90% — each ring on its own
        percent. A small red dot at top-right means some other service is
        at 70%+ or in an alert state.
```

The icon is one service ("primary" — Claude Code by default) shown as two
concentric arcs, not a five-line strip: everything else you're tracking still
shows up in the card panel below, and the alert dot says when it's worth a
look. On refresh the arcs sweep from the old value to the new one; past 90%
the outer arc breathes gently rather than sitting still. Both the sweep and
the breathing are off automatically when macOS's Reduce Motion is on, and can
be turned off in Settings regardless. Add a numeral next to the ring
("Ring + number") if you'd rather read a percentage than a fraction of a
circle. The old five-line bar strip is still there as `menuBar.style: "bars"`
in `config.json` for anyone who preferred it, but it isn't offered in the
Settings UI any more.

## The panel

Clicking the icon (v1.0.27) opens a floating card, not an `NSMenu` dropdown —
it stays anchored under the icon, sits above everything else, and closes on a
click outside, Esc, clicking the icon again, or the app losing focus.

- **Header** — "AIMeter" on the left, "Updated *time* · every *interval*" (or
  "· manual" when the primary service is not polled) on the right.
- **Cards start compact** with a lamp, the service name, and one row per
  gauge. Click a card's title row to expand or collapse it; the choice is
  remembered separately for every service, and the primary service starts
  expanded by default. An expanded card keeps the existing hero layout: for
  Claude, "reads usage without spending quota"; for a snapshot service,
  how old the snapshot is. A 64pt ring plus a big number is the 5-hour window;
  under it, a chip per remaining window — the weekly window first, then any
  per-model weekly window sorted by name, then anything else (overage, extra
  usage) — each with its own tiny ring, value, and reset time. Below the chips,
  a trend line: the last 24h of that 5-hour window, read straight from the
  usage ledger on disk (see **Usage history** below); with fewer than two
  points recorded, that section is omitted.
- **Remaining cards**, in a fixed order — Codex, then OpenRouter (one row per
  key), then a compact two-column row of DeepSeek, Antigravity, Local AI, and
  Cursor — followed by anything else you've added. A failed reading shows its
  message in red instead of a meter.
- **Click below a card's title** to check that one service by hand — the same "Check now"
  the old dropdown had, now with a brief highlight flash instead of its own
  menu row. **Hover** lifts a card slightly and shows the exact reset time as
  a tooltip.
- **Footer** — four icon buttons (refresh ⌘R, usage report, settings,
  quit ⌘Q) and a **…** menu for the remaining quick actions. The gear opens
  Settings at the same 372pt width; each page pushes over the current one.
  Esc goes back one page first, then closes the panel from the usage page.

Prefer the old `NSMenu` dropdown? Set `"panel": "menu"` under `menuBar` in
`config.json` (there is no Settings toggle for it) — every card above becomes
the same rows and footer items the pre-v1.0.27 dropdown drew.

## Requirements

- macOS 14 or later, Apple silicon (the build targets `arm64` only)
- Xcode command line tools (`xcode-select --install`) — `swiftc` is all that is
  needed; there are no package dependencies

## Build and run

```bash
./tools/make_signing_cert.sh   # once: a stable local signing identity
./build.sh                     # produces dist/AIMeter.app
open dist/AIMeter.app
```

Move `dist/AIMeter.app` into `/Applications` if you want it filed properly, then
tick **Start at login** from the panel footer's **…** menu.

**Run `tools/make_signing_cert.sh` before the first build.** Without it the app
is signed ad hoc, which means macOS identifies it by the hash of its own bytes:
every rebuild looks like a different application, and the keychain permission
you granted no longer applies, so you are asked again after every build. The
script creates a self-signed code-signing certificate in your login keychain so
the identity stays put. The certificate is deliberately left **untrusted** and its key is granted to
`codesign` alone. A trust anchor is not needed here — a signature from an
untrusted self-signed certificate still binds the app's designated requirement
to that certificate, which is what keeps the keychain grant valid across
rebuilds. Making it a trusted code-signing anchor would instead mean anything
signed with it passed "anchor trusted" checks on your Mac for a decade.

To remove it, delete **both** the certificate and the private key of the same
name in Keychain Access — they are separate rows under "login".

`build.sh` calls `swiftc` directly rather than `swift build`, because SwiftPM
spawns its own `sandbox-exec` for manifest evaluation, which cannot nest inside
some sandboxed environments.

### Testing

```bash
./tools/test.sh
```

A lightweight, dependency-free assertion suite — not XCTest, for the same
reason `build.sh` calls `swiftc` directly rather than `swift build`: `swift
test` goes through SwiftPM, which spawns its own `sandbox-exec` and cannot
nest inside some sandboxed environments. `tools/test.sh` compiles the app's
source files (everything except `main.swift`, which has its own top-level
code) together with `tools/tests/*.swift` and runs the result.

The recipe coverage is pure logic — no network, keychain contents, or vendor
subprocess is needed — including the URL-safety guarantee now shared by custom
recipes in `RecipeURL` (`approvedHost`/`safeURL`): a credential's destination
cannot be redirected by anything in the settings file, including the exact
attacker payloads found during the security review below. The rest covers
parsing that has broken silently before — Antigravity's screen capture
(mixed line endings, ANSI stripping) and its print-mode JSON (against a real
captured fixture: two groups, four percentages, both reset-time formats), the
settings file's tolerant decoding of older configs — plus the menu bar strip's
gauge-to-bar mapping and a few formatting helpers.

One test (`trustedHome`'s ownership check) needs to run outside a sandbox that
restricts `FileManager.attributesOfItem`'s owner field — the same class of
restriction that already applies to network and keychain access elsewhere in
this project. It is not expected to affect a normal `swift`/Xcode environment
or CI.

What it does not cover: anything that talks to a vendor API, drives the
keychain, or launches `agy` (print mode or a pty). Those paths have been verified by hand,
repeatedly, against the running app — see Diagnostics below — rather than
mocked, since a mock of the exact bug class this project has hit (bytes lost
to a full pty buffer, a capture with mixed CR/LF/CRLF) would likely have
missed the bug too.

### Diagnostics

```bash
./dist/AIMeter.app/Contents/MacOS/AIMeter --once            # every reading, as text
./dist/AIMeter.app/Contents/MacOS/AIMeter --icon out        # ring on light, dark, blue, selected backgrounds + states
./dist/AIMeter.app/Contents/MacOS/AIMeter --panel out.png --page usage
./dist/AIMeter.app/Contents/MacOS/AIMeter --panel settings.png --page settings
./dist/AIMeter.app/Contents/MacOS/AIMeter --panel services.png --page services
./dist/AIMeter.app/Contents/MacOS/AIMeter --panel catalogue.png --page catalogue
./dist/AIMeter.app/Contents/MacOS/AIMeter --panel custom.png --page custom --demo-tested
./dist/AIMeter.app/Contents/MacOS/AIMeter --panel menubar.png --page menubar
./dist/AIMeter.app/Contents/MacOS/AIMeter --panel general.png --page general
./dist/AIMeter.app/Contents/MacOS/AIMeter --panel history.png --page history
./dist/AIMeter.app/Contents/MacOS/AIMeter --recipe-test <recipe-id>
./dist/AIMeter.app/Contents/MacOS/AIMeter --menushot out.png # the real translucent NSMenu — "menu" style only
```

`--icon` and `--panel` render the same views the app shows: `--panel` hosts
the actual `PanelView` SwiftUI content offscreen, once under a light
appearance and once dark, so a change to the panel can be checked as a PNG
rather than by opening it and describing what's there. Add `--demo-high` for
five near-limit services, or `--demo-contrast` for the reported 19% 5-hour /
97% weekly Claude shape (plus a 9% "Fable" model-scoped chip), without
reading credentials or making a request; both keep working through `--panel`.
`--menushot` only has something to track when `menuBar.panel` is set to
`"menu"` — the default card panel has no `NSMenu` to open, and the command
says so rather than screenshotting something misleading.

## Security: what this app reads, and what it sends

This is the part worth reading before you trust it with your credentials.

- **Claude Code**: the OAuth token is read from the login keychain (item
  `Claude Code-credentials`, written by Claude Code itself) by running
  `/usr/bin/security find-generic-password` — the same route the `claude` CLI
  itself uses to read its own token back — which is why there is no keychain
  permission panel for this item. That is a deliberate choice, not an
  oversight: the CLI's own write path resets the item's access-control list on
  every token refresh, so an ordinary in-process read kept re-triggering
  macOS's password prompt no matter how many times it had been answered.
  Routing around that prompt is scoped to this one item by an explicit
  allowlist in `Keychain.securityToolServices` — nothing else this app might be
  told to read (in particular nothing from `config.json`, which is untrusted
  plain text) can be pointed at this code path. The token is read once per
  launch, kept in memory, and used for exactly one request per refresh:
  `GET api.anthropic.com/api/oauth/usage` — the CLI's own usage endpoint,
  confirmed by a binary grep of Claude Code 2.1.260 as the only usage path it
  calls. Nothing is charged to your subscription per refresh any more; the
  earlier version of this app spent a real 1-token `POST v1/messages` request
  every time solely to read rate-limit headers off the response, and that
  request is gone. The row shows the 5-hour and weekly windows, any
  per-model weekly entries the account reports (Claude reports these
  per-model, not just per-account, so a row like "Fable weekly window" can
  appear alongside the overall weekly figure), and extra (pay-as-you-go)
  usage when it is enabled. The token goes nowhere else.
  If the item is there but holds an empty token — which means only that no
  token is stored in it right now, not necessarily that the CLI is signed out —
  the row says so and tells you to press **Check now** or sign in with `claude`
  in a terminal; nothing is read from anywhere else. In particular
  `~/.claude/.credentials.json`, which a Claude Code session hosted by the
  Claude desktop app writes for itself, is deliberately not consulted.
  One exception, and only ever on a button press: if you press **Check now** on
  a Claude row whose access token has gone stale, this app runs the real
  `claude` CLI, which sends a request of its own to refresh that token — a
  one-turn Haiku prompt, measured at 264 input and 83 output tokens, charged to
  your own subscription window. The row says so before you press it, and
  `claudeRefreshViaCLI: false` switches it off. See below for why it has to be a
  real request.
- **Keys you paste** on the panel's **Services** page are stored in your login keychain
  under `AIMeter · <service> · <account>`, never in the settings file.
- **The settings file and debug dumps are written 0600 in a 0700 directory**.
  The manual-only Antigravity screen capture has the account address removed
  before it reaches the disk; the print-mode JSON dump needs no redaction at
  all, because that response carries no account, email, or credential in the
  first place — only percentages and reset times. These are the files most
  likely to be pasted somewhere while troubleshooting.
- **The settings file is treated as untrusted input.** A recipe can describe an
  HTTP request, a fixed command invocation, or a read-only snapshot file, but
  the part that decides *where* it can send or read is approved separately when
  you press **Save** and stored in AIMeter's keychain under
  `AIMeter · recipe · <id>`. HTTP recipes pin scheme + host, HTTP method,
  normalized path/query-key policy, body digest, and credential source plus
  auth placement; command recipes pin the executable, argument hash, permitted
  environment hash, HOME mode, and credential source; file recipes pin the
  folder and credential source. Editing `config.json` afterwards cannot change
  an approved host, credential source, command environment, or HTTP operation;
  any mismatch makes the recipe stop with **Re-approval required after you
  save**. Public HTTP destinations must be HTTPS; plain HTTP is accepted only
  for `127.0.0.1` and `localhost`. Recipe HTTP requests reject all redirects.
- **Recipe credentials can come from a pasted key, a key file, an environment
  variable, another app's keychain item, or nowhere at all.** A pasted key is
  stored in AIMeter's own keychain item and never in `config.json`. A key file
  or environment variable can be changed by someone who can edit your settings,
  but its contents can only be sent to the host you already approved. Pinning
  protects the destination; it does not claim that a mutable file path or
  environment variable is itself trustworthy. An `appKeychain` source always
  uses the normal in-process Keychain API, so macOS may show its authorization
  panel. Recipes can never opt into the special `/usr/bin/security` silent-read
  allowlist reserved in code for `Claude Code-credentials`, and that service is
  rejected for recipes regardless of source spelling.
- **Recipes do not run a shell or interpolate strings.** HTTP supports GET or
  POST with a fixed JSON body; the only credential-in-query form is the explicit
  `auth: query` setting. Non-recipe HTTP redirects must stay on the same origin
  (scheme, host, and port); HTTPS downgrades are rejected. Command recipes use
  `Process.executableURL` directly, a fixed allowlisted environment (PATH, HOME,
  LANG, TERM, plus approved custom keys — never `NODE_OPTIONS`, `DYLD_*`, or
  other injection variables), closed stdin, a 30-second ceiling and a 1 MB output
  limit; executable paths are restricted to the documented install roots and
  `/usr/bin/security` is explicitly excluded. File recipes are read-only, their
  glob may not contain `..`, and the resolved file must remain under the pinned
  folder. Recipes never write files.
- The Antigravity CLI —
  print mode or the pty fallback — is only ever run from a known install
  location (`AgyTUI.allowedBinaries`), against a HOME that must already exist
  and already contain `.gemini/antigravity-cli` (`trustedHome`), and with a
  minimal environment built from nothing rather than the inherited one. This
  app never calls Google's quota endpoint itself in either mode; it only ever
  launches the genuine, vendor-installed client and reads what it prints.
- **Keys in files** are read from the paths you point at, and are not copied.
- **Network**: only the vendor endpoints listed below, plus `127.0.0.1` for
  local model runtimes. There is no telemetry, no analytics, and no server
  belonging to this project.
- The parsed usage structure (kinds, percents, resets, extra_usage numbers —
  never the request headers or the token) is written to
  `~/.config/aimeter/last-usage-<account>.json` so you can check the parsing
  against reality.
- **Cursor is a link, not a reading.** Cursor has no public usage API. Two
  routes would work anyway — reading Cursor's own stored token to call its
  private RPC, or scraping the dashboard with a browser session — and both were
  deliberately rejected: neither is something this project wants to depend on
  for a menu-bar number. The row shows only a message pointing at
  `cursor.com/dashboard/spending`, opened from the row's own menu item, never
  polled, and never written to the usage ledger (there is nothing to chart).

## Usage history

Every completed refresh — timer or manual, for every provider — appends one
line per gauge to a monthly ledger at
`~/.config/aimeter/history/YYYY-MM.jsonl` (UTC month), written 0600 in a 0700
directory. Each line carries only what the panel already shows: the provider
and account, the gauge's label, kind, percentage and text, its reset time, and
the reading's state — never a token, header, or any other credential. A
provider that failed outright is logged as one line with the error message, so
a gap in the chart is explained rather than silent; the Cursor row, which
never carries a percentage, is not logged at all.

Retention defaults to 12 months (`history.retentionMonths` in the settings
file); older monthly files are deleted once at launch. Set
`history.enabled: false` to stop the ledger being written at all.

The panel footer's chart-icon button rebuilds the report from every ledger
file and opens it (the **…** menu's **Open debug folder** is right next to it). The same thing happens from
the command line with `AIMeter --export-history [dir]`, which writes
`history.csv` (one row per ledger line) and `history.html` — a self-contained
page, inline CSS and JS, no external resources of any kind, drawn with a small
hand-written SVG line chart per provider·account, a legend, the last 24 hours
in a table, and an errors list. Because nothing it references lives outside
the file, `history.html` can be copied anywhere and still renders correctly.

## Where each number comes from

| Row | Source | Live or snapshot |
|---|---|---|
| **Claude Code** | One `GET api.anthropic.com/api/oauth/usage` request — the CLI's own usage endpoint; nothing is charged per refresh. | Live |
| **Codex** | The `rate_limits` block Codex writes into its own session files under `~/.codex/sessions/`. No network call and no credential needed. | **Snapshot** — as of the last time Codex ran. Labelled with its age; dimmed once stale; a window that ended since is shown as `—` rather than as a number. |
| **Antigravity** | `agy -p "/usage" --output-format json` — the CLI's own read-only print-mode command, run non-interactively; spends no quota and takes ~4s (measured). Checked hourly by default. | Live |
| **OpenRouter** | `GET openrouter.ai/api/v1/key`, once per key. | Live |
| **DeepSeek** | `GET api.deepseek.com/user/balance`. This is money, not a percentage, so it has no bar. Also flags peak-hour pricing. | Live |
| **Local AI** | Ollama on `127.0.0.1:11434`, LM Studio on `127.0.0.1:1234`, and an MLX server (`mlx_lm.server`/`mlx_vlm.server`) on `127.0.0.1:8081`; reports memory held by loaded models. | Live |
| **Cursor** | Nothing — a link only. Cursor has no public usage API; see the Security section below for why the two undocumented routes were rejected. | — |
| **Recipe** | A user-defined, pinned HTTP / command / file source mapped through the recipe's JSON fields. The service name, units and reset windows come from that saved recipe; missing fields are warnings, never invented zeroes. | Live for HTTP/command; **snapshot** for file recipes. |

A snapshot ages at a rate that depends on the window, not on the snapshot, and
one age label cannot speak for both. Fifteen hours off a weekly figure is a
rounding error; fifteen hours off a five-hour figure is two or three complete
cycles, and the number then describes a window that no longer exists. Each
window states its own reset time, so once that moment has passed the figure is
withdrawn and the row says the window ended, rather than showing a percentage
nothing can stand behind. Only the affected window is withdrawn — the weekly one
beside it is still right, and still shown.

A snapshot is always labelled as one. Nothing is presented as current when it is
not, and a reading that failed is drawn as three dots — never as an empty bar,
which would mean "measured zero".

### Services with nothing to query

Not every vendor exposes a balance, and this app will not invent one:

- **Google Gemini API / AI Studio keys** — no public quota or balance endpoint.
- **OpenAI platform API** — the usage endpoints need an *admin* key, which is a
  different thing from the ChatGPT plan that Codex signs in with.
- **Anthropic pay-as-you-go API** — likewise; separate from the subscription
  token used above.

### Claude Code: what “Check now” does when the token has gone stale

Claude Code's access token lasts hours; the refresh token behind it lasts days,
and **only the CLI trades one for the other**, when it runs. A menu bar app that
never launches the CLI therefore watches the access token expire while the
sign-in behind it is perfectly healthy. Earlier versions said so correctly — and
then the row's own **Check now** button could do nothing about it, because all
it did was read the same unchanged keychain item again.

So it now presses the button it was telling you to press. On a manual check of a
Claude row whose access token is stale (and whose sign-in is still good), this
app runs the real, vendor-installed `claude` — first its local `auth status`,
then a minimal one-turn prompt — waits, and re-reads the keychain. It does
**not** refresh the token itself: that would mean replaying Anthropic's private
token endpoint under the CLI's own client id, and writing a rotated refresh
token back into the CLI's keychain item while a real `claude` might be doing the
same. This app only starts the genuine program and reads the result.

#### Why it has to be a real request (v1.0.10 through v1.0.14 were wrong)

The first version of this ran `claude auth status --json` on the theory that
starting the CLI is what refreshes the token. **It is not**, and the button did
nothing for five releases. Measured on 2026-08-27 against a genuinely expired
access token, twice — once through this app's own `--once --manual` path, once
by hand outside the app:

| Command | Time | Effect on the stored token |
|---|---|---|
| `claude auth status --json` | 0.45s | **none** — reports `"loggedIn": true`, leaves the expired token exactly as it found it |
| `claude -p "."` | ~2s | **refreshed** |

`auth status` is a local read. It never contacts the network, so it never has
occasion to refresh anything. The CLI refreshes when it needs a working token
for a live request — and there is no `claude auth refresh`; that subcommand has
login, logout and status and nothing else. So the second step has to be a real
prompt, and a real prompt costs something.

- **It is made as small as the CLI allows.** Plain `claude -p "hi"` costs 57,250
  cache-creation input tokens ($0.229 at list price) — the default system
  prompt, your `CLAUDE.md`, every skill, every MCP tool definition. Run with
  `--safe-mode --tools "" --system-prompt … --model haiku --effort low`, the
  same refresh costs **264 input and 83 output tokens** ($0.00068). About 190×
  less, and the same order as the 1-token probe this app already sends on every
  ordinary refresh. It is not retried with a smaller flag set on an older CLI,
  because the only universally-safe argument list is the expensive one, and
  quietly spending 57,000 tokens where you were promised 300 is worse than
  failing visibly.
- **It cannot do anything but talk.** `--tools ""` means the spawned session
  holds no Bash, no Edit, no tools at all; `--safe-mode` means no hooks, no MCP
  servers, no plugins, no `CLAUDE.md`. A menu-bar click must not be able to set
  your own automation going, and `--no-session-persistence` means it leaves no
  transcript behind. A `--max-budget-usd` ceiling caps the spend at ~30× the
  measured cost.
- **The free step still runs first, as a gate.** `auth status` refreshes
  nothing, but it says — locally, in under half a second, with no possibility of
  a browser window — whether this machine is signed in at all. Only if it says
  yes does the prompt run. Nothing is spent discovering that you are logged out.
- **The keychain is the verdict, not the subprocess.** Whatever the run says
  about itself, what decides the row is re-reading the stored token. Trusting
  the subprocess's own report is the exact mistake that let the broken version
  pass review.
- **Manual only.** Never on the timer, never at launch, never on opening the
  menu — this one spends real quota from your own subscription window, unlike
  Antigravity's print-mode read (see below), which is on a timer precisely
  because it was measured to spend nothing.
- **Only the CLI's own account.** An account holding a pasted API key never
  causes the CLI to be launched: running `claude` would not refresh it.
- **Only from the installers' own locations** — `~/.local/bin`, `/usr/local/bin`,
  `/opt/homebrew/bin`, `~/.claude/local`. A path in the settings file is
  honoured only if it is one of these.
- **The auto-updater is switched off for the run**, so a menu click cannot
  quietly pull down a new CLI build.
- Every outcome is reported as itself — CLI not found, CLI says signed out, CLI
  ran and the token is still stale, CLI rejected an argument — rather than
  repeating the same message and leaving you to guess whether anything happened.

Set `claudeRefreshViaCLI: false` in the settings file to switch it off; set
`claudeBinary` to pick one of the allowed paths explicitly.

### Antigravity: how its quota is read

Antigravity publishes these numbers in exactly one place a third party could
otherwise ask instead: nowhere. The credential the CLI stores is not an OAuth
access token the internal quota endpoint accepts (tested, HTTP 401), so
producing a number that way would mean impersonating the client.

So, as of v1.0.28, this app does the opposite in the cheapest way the CLI
itself allows: it runs `agy -p "/usage" --output-format json`, a documented,
read-only print-mode command — the same "non-interactive answers for
read-only slash commands" the CLI added for `/usage`, `/quota`, `/credits`,
`/model`, `/effort` and `/skills`. This app never calls Google's quota
endpoint itself; the CLI is launched non-interactively with a minimal
environment (`HOME`, a fixed `PATH`, `LANG`, and
`AGY_CLI_DISABLE_AUTO_UPDATE=1` — never the parent process's own), does its
own handshake with its own credentials, prints one JSON object, and exits.
Measured 2026-09-04, n=3: ~4 seconds, no quota spent, no conversation left
behind — the conversations directory's file count is unchanged before and
after, and the response's own `usage.total_tokens` is `0`.

That is fast and cheap enough to run on a timer, so it does: **checked hourly
by default**, the same as most other rows, not "only when you press it" any
more. If a check is refused (HTTP 403 / `PERMISSION_DENIED`) or otherwise
fails, this row pauses itself — the timer stops asking until you press
**Check now** — rather than repeat a request that just failed once an hour
forever. A scheduled check also steps aside if `agy` is already running under
this account (`pgrep -x agy`), since two `agy` processes contending for the
same local state is untested.

The old pseudo-terminal screen-scrape — type `/usage` into a real `agy`
session and read the panel it draws — still exists as a **manual-only
fallback**, for an `agy` old enough not to support print mode, or for anyone
who has switched print mode off. It only ever runs on **Check now**, never on
a timer, takes tens of seconds, and will not work while you have an `agy`
session of your own open, since the CLI binds a local port.

Set `agyQuotaViaPrint: false` in the settings file to switch off the
print-mode path (falling back to the manual TUI screen-scrape on a press of
**Check now**); `agyQuotaViaTUI: false` switches that fallback off too.

## Adding accounts

Everything is done under the panel's single **Settings** gear: **Services**
lists configured accounts, and **Add** opens the built-in service catalogue.
Nothing requires editing a file.

- **Detect services on this Mac again** finds what is already on this Mac.
- **Add account** takes a pasted key (stored in the keychain), a key file, or —
  for Codex and Antigravity — the folder that acts as that account's home.
- **Test** runs one account through its real provider and shows the result,
  marked ✓ or ✗ so a working account and a broken one do not look alike.
- **Recipes** in the Add catalogue cover HTTP JSON, command JSON, latest-file
  snapshots and a fully custom form. Test shows the actual request/command,
  status, byte count, elapsed time, content type, mapped gauges, a 600-character
  redacted response preview, and unmapped top-level fields. Save is allowed
  before Test; Save pins the destination first, persists the recipe/account,
  then automatically tests once. Removing a recipe removes its pin and any
  AIMeter-owned pasted credential for that recipe. Existing `accounts.generic`
  entries remain untouched and appear as **Other · legacy** until you choose
  **Convert to recipe**.
- Every service accepts more than one account. For Codex and Antigravity an
  account is a separate home directory; folders placed in
  `~/.config/aimeter/pools/<service>/` are picked up by auto-detect.

### How often each source is checked

The **Services** page sets a check interval per source, including **only when I ask**.
A source set to manual is skipped by the timer and by **Refresh now**; it updates
when you press **Check now** under its own heading in the panel.

Reasonable settings differ by source: Codex reads local files and costs nothing,
DeepSeek is a balance that moves slowly, and Claude is the one that spends a
request per refresh.

### Recipe configuration

The panel writes recipes into `config.json`; the destination pin is deliberately
not stored there. A compact HTTP example looks like this:

```json
{
  "recipes": [{
    "id": "typhoon",
    "name": "Typhoon",
    "colour": "#3A8DDE",
    "symbol": "bolt",
    "credential": { "source": "keychain" },
    "fetch": {
      "method": "http",
      "verb": "GET",
      "baseURL": "https://api.opentyphoon.ai",
      "path": "/v1/credits",
      "auth": "bearer",
      "timeout": 30
    },
    "map": {
      "format": "json",
      "gauges": [{
        "label": "Balance",
        "value": "$.credits",
        "unit": "usd",
        "window": "other"
      }],
      "lines": []
    },
    "interval": 900
  }]
}
```

The path syntax is intentionally small: `$`, `.key`, `[n]`, or a bare key name
for the existing depth-first lookup behavior. There are no filters, scripts,
wildcards, or expression evaluation. Recipe IDs use lowercase letters, numbers
and hyphens; built-in provider IDs are reserved.

### Choosing what the ring shows

The **Menu bar** settings page has a **Primary service** picker
(Claude Code or Codex — whichever has windows), a **Ring** / **Ring + number**
choice, and two toggles — the alert dot, and the sweep/breathe animation —
with a live preview of the exact icon that will be drawn.

### Colours

Colour has one grammar throughout the app:

- **Ink / amber / red means urgency** — below 70%, 70–89%, and 90% or more.
- **Green is only the normal-status lamp**; it never fills a usage bar.
- **One colour identifies each service** only in Services, the catalogue,
  history legends, and the legacy `bars` fallback. In that fallback the weekly
  half is the same service colour blended 35% toward the current background.

There is no colour settings UI. Advanced fixed overrides remain tolerated in
`config.json` as `"ink"`, `"track"`, `"warn"`, `"alarm"`, `"ok"`, or
`"service.<id>"`; unspecified roles continue to follow light and dark mode.

## Adding a language

Four are built in — English, 繁體中文, Français, Deutsch — plus "Follow system".
The strings live in `tools/gen_l10n.py`. Add a column, add one string per row,
then:

```bash
python3 tools/gen_l10n.py
```

## Licence

MIT — © 2026 khan. See [LICENSE](LICENSE). No third-party assets are bundled: no vendor
fonts, no mascot art, no icon sets. Everything drawn on screen is drawn by the
code in this repository.
