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
the identity stays put. Remove it any time from Keychain Access — it is named
"AIMeter Local Signing" and signs nothing else.

`build.sh` calls `swiftc` directly rather than `swift build`, because SwiftPM
spawns its own `sandbox-exec` for manifest evaluation, which cannot nest inside
some sandboxed environments.

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
| **Local AI** | Ollama on `127.0.0.1:11434` and LM Studio on `127.0.0.1:1234`; reports memory held by loaded models. | Live |

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

### A note on Antigravity

Antigravity's quota lives behind an internal Google endpoint. This app does
**not** call it; it reads what the CLI already logged. Repeated automated calls
against a vendor's internal endpoints — multiplied by several accounts — are the
traffic pattern that gets accounts flagged. `agyAllowDirectQuotaCall: true` in
the settings file turns the direct call on. Consider carefully before using it
across more than one account.

## Adding accounts

Everything is done in **Accounts…** in the menu. Nothing requires editing a file.

- **Detect automatically** finds what is already on this Mac and tests each find
  immediately, so a key file holding a credential that was revoked months ago
  shows up as a failure right away instead of as a silently wrong number.
- **Add account** takes a pasted key (stored in the keychain), a key file, or —
  for Codex and Antigravity — the folder that acts as that account's home.
- **Test** runs one account through its real provider and shows the result.
- Every service accepts more than one account. For Codex and Antigravity an
  account is a separate home directory; folders placed in
  `~/.config/aimeter/pools/<service>/` are picked up by auto-detect.

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

## Antigravity: how the quota is read

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
