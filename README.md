# AIMeter

A macOS menu bar app that shows how much of each AI service you have left —
Claude Code, Codex, Antigravity, OpenRouter, DeepSeek, and whatever is loaded
into local inference right now — as a strip of stacked bars you can read without
clicking anything.

Menu bar only. `LSUIElement` is set, so there is no Dock icon and no Cmd-Tab
entry.

```
   ▁▁▁▁▁▁    ← each line is one service
   ███░░░       upper half = the 5-hour pool
   ██░░░░       lower half = the weekly pool
   · · ·        three dots = no reading (not "zero used")
```

Click the strip for the full panel: every window, every account, when each one
resets, and the plain-language reason when something cannot be read.

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
tick **Start at login** in the menu.

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

It covers pure logic only — no network, no keychain, no subprocess launch —
so it runs in well under a second. The heaviest coverage is the URL-safety
guarantee in `GenericProvider` (`approvedHost`/`safeURL`): that a credential's
destination cannot be redirected by anything in the settings file, including
the exact attacker payloads found during the security review below. The rest
covers parsing that has broken silently before — Antigravity's screen capture
(mixed line endings, ANSI stripping), the settings file's tolerant decoding of
older configs — plus the menu bar strip's gauge-to-bar mapping and a few
formatting helpers.

One test (`trustedHome`'s ownership check) needs to run outside a sandbox that
restricts `FileManager.attributesOfItem`'s owner field — the same class of
restriction that already applies to network and keychain access elsewhere in
this project. It is not expected to affect a normal `swift`/Xcode environment
or CI.

What it does not cover: anything that talks to a vendor API, drives the
keychain, or launches `agy` in a pty. Those paths have been verified by hand,
repeatedly, against the running app — see Diagnostics below — rather than
mocked, since a mock of the exact bug class this project has hit (bytes lost
to a full pty buffer, a capture with mixed CR/LF/CRLF) would likely have
missed the bug too.

### Diagnostics

```bash
./dist/AIMeter.app/Contents/MacOS/AIMeter --once          # every reading, as text
./dist/AIMeter.app/Contents/MacOS/AIMeter --icon out.png  # the strip, 8x, both colour schemes
```

Both run the same code as the menu, so they show what the app actually sees
rather than a separate approximation of it.

## Security: what this app reads, and what it sends

This is the part worth reading before you trust it with your credentials.

- **Claude Code**: the OAuth token is read from the login keychain (item
  `Claude Code-credentials`, written by Claude Code itself). macOS will ask your
  permission the first time; choose **Always Allow**. The token is read once per
  launch, kept in memory, and used for exactly one request per refresh:
  `POST api.anthropic.com/v1/messages` with `max_tokens: 1`. The usage figures
  come from that response's headers. The token goes nowhere else.
- **Keys you paste** into the Accounts window are stored in your login keychain
  under `AIMeter · <service> · <account>`, never in the settings file.
- **The settings file and debug dumps are written 0600 in a 0700 directory**,
  and the Antigravity screen capture has the account address removed before it
  reaches the disk. These are the files most likely to be pasted somewhere while
  troubleshooting.
- **The settings file is treated as untrusted input.** A custom "Other" service
  can only use a key you pasted (kept in the keychain) over https — not an
  arbitrary file path, which would otherwise make it a "read this file, post it
  to my host" gadget for anyone who could edit that file. The Antigravity CLI is
  only ever run from a known install location, with a minimal environment rather
  than the inherited one.
- **Keys in files** are read from the paths you point at, and are not copied.
- **Network**: only the vendor endpoints listed below, plus `127.0.0.1` for
  local model runtimes. There is no telemetry, no analytics, and no server
  belonging to this project.
- Every `anthropic-ratelimit-*` header received is written to
  `~/.config/aimeter/last-headers-<account>.json` so you can check the parsing
  against reality.

## Where each number comes from

| Row | Source | Live or snapshot |
|---|---|---|
| **Claude Code** | One 1-token request to `api.anthropic.com/v1/messages`; the figures are the `anthropic-ratelimit-unified-*` response headers. | Live |
| **Codex** | The `rate_limits` block Codex writes into its own session files under `~/.codex/sessions/`. No network call and no credential needed. | **Snapshot** — as of the last time Codex ran. Labelled with its age; dimmed once stale. |
| **Antigravity** | The result of the CLI's own quota refresh, read out of `~/.gemini/antigravity-cli/cli.log`. | Snapshot |
| **OpenRouter** | `GET openrouter.ai/api/v1/key`, once per key. | Live |
| **DeepSeek** | `GET api.deepseek.com/user/balance`. This is money, not a percentage, so it has no bar. Also flags peak-hour pricing. | Live |
| **Local AI** | Ollama on `127.0.0.1:11434`, LM Studio on `127.0.0.1:1234`, and an MLX server (`mlx_lm.server`/`mlx_vlm.server`) on `127.0.0.1:8081`; reports memory held by loaded models. | Live |

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
app runs the real, vendor-installed `claude auth status` once, waits for it to
finish, and re-reads the keychain. It does **not** refresh the token itself:
that would mean replaying Anthropic's private token endpoint under the CLI's
own client id, and writing a rotated refresh token back into the CLI's keychain
item while a real `claude` might be doing the same. This app only starts the
genuine program and reads the result.

- **Manual only.** Never on the timer, never at launch, never on opening the
  menu — the same rule as Antigravity.
- **Read-only subcommand.** `auth status` reports; it makes no model request, so
  nothing here is charged against the window it is reporting on. With no
  credential present it prints its report and exits, without offering to log in.
- **Only the CLI's own account.** An account holding a pasted API key never
  causes the CLI to be launched: running `claude` would not refresh it.
- **Only from the installers' own locations** — `~/.local/bin`, `/usr/local/bin`,
  `/opt/homebrew/bin`, `~/.claude/local`. A path in the settings file is
  honoured only if it is one of these.
- **The auto-updater is switched off for the run**, so a menu click cannot
  quietly pull down a new CLI build.
- Every outcome is reported as itself — CLI not found, CLI says signed out, CLI
  ran and the token is still stale — rather than repeating the same message and
  leaving you to guess whether anything happened.

Set `claudeRefreshViaCLI: false` in the settings file to switch it off; set
`claudeBinary` to pick one of the allowed paths explicitly.

### Antigravity: how its quota is read

Antigravity publishes these numbers in exactly one place — the `/usage` panel of
its own CLI. There is no endpoint a third party can ask: the credential the CLI
stores is not an OAuth access token the internal quota endpoint accepts (tested,
HTTP 401), so producing one would mean impersonating the client.

So this app does the opposite. **Check now** on the Antigravity row launches the
real `agy` client in a pseudo-terminal, types `/usage`, and reads the panel it
draws. Every request to Google is made by the genuine client with its own
credentials and headers.

It runs **only when you press it** — never on a timer, and the source defaults to
"manual only". It takes roughly half a minute, and it will not work while you
have an `agy` session of your own open, since the CLI binds a local port.

Set `agyQuotaViaTUI: false` in the settings file to switch it off entirely.

## Adding accounts

Everything is done in **Accounts…** in the menu. Nothing requires editing a file.

- **Detect automatically** finds what is already on this Mac and tests each find
  immediately, so a key file holding a credential that was revoked months ago
  shows up as a failure right away instead of as a silently wrong number.
- **Add account** takes a pasted key (stored in the keychain), a key file, or —
  for Codex and Antigravity — the folder that acts as that account's home.
- **Test** runs one account through its real provider and shows the result,
  marked ✓ or ✗ so a working account and a broken one do not look alike.
- Every service accepts more than one account. For Codex and Antigravity an
  account is a separate home directory; folders placed in
  `~/.config/aimeter/pools/<service>/` are picked up by auto-detect.

### How often each source is checked

The same window sets a check interval per source, including **only when I ask**.
A source set to manual is skipped by the timer and by **Refresh now**; it updates
when you press **Check now** under its own heading in the panel.

Reasonable settings differ by source: Codex reads local files and costs nothing,
DeepSeek is a balance that moves slowly, and Claude is the one that spends a
request per refresh.

### Choosing what appears in the menu bar

The same window has a **Menu bar** section: up to five slots, each a dropdown of
the services you have configured, reorderable, with a live preview of the
resulting strip.

Each line splits in two — the 5-hour pool above, the weekly pool below. A
service that has only one kind of window (Codex, OpenRouter) draws a single
full-height bar instead, which is how you can tell the two cases apart.

### Colours

Two schemes, switchable in the same place:

- **By service** (default) — each service has its own hue, so the strip is not a
  wall of one colour. Red is held back: any bar at 90% or more turns red
  regardless of which service it belongs to, so "nearly spent" never has to be
  decoded.
- **By window** — red for the 5-hour half, blue for the weekly half, teal for a
  single-window service. Identity then comes from position alone, and there is
  no colour alarm; length is the only signal of how full a bar is.

Every colour is yours to change, in the **Colours** section of the same window:
the text, the bar background, the nearly-spent alarm, the two panel bar states,
and — per service — one colour for the 5-hour half and one for the weekly half.

A colour you set is a fixed value and will not follow light and dark mode; the
defaults are semantic colours that do. Leave a role alone to keep the adaptive
default, or press **Reset all colours** to go back.

## Adding a language

Four are built in — English, 繁體中文, Français, Deutsch — plus "Follow system".
The strings live in `tools/gen_l10n.py`. Add a column, add one string per row,
then:

```bash
python3 tools/gen_l10n.py
```

## Licence

MIT — see [LICENSE](LICENSE). No third-party assets are bundled: no vendor
fonts, no mascot art, no icon sets. Everything drawn on screen is drawn by the
code in this repository.
