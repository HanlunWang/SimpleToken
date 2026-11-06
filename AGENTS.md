# AGENTS.md

SimpleToken (formerly Lumen): a macOS menu-bar and window tracker for AI coding usage (Claude Code, Codex, Cursor, Gemini CLI and others). v2 is a Go app on [mygo](https://github.com/egoist/mygo)'s native UI (branch `v2`); the SwiftUI 0.1.x app stays in `App/` + `SimpleTokenKit/` until v2 ships and gets fixes only when the owner asks. User-facing docs: [README.md](README.md). The repo is public: everything (code, comments, docs, commits) is English; the only non-English text is the translation catalogs.

## Build and verify

```bash
go vet ./... && go test ./...                  # core + headless UI tests (leak checks, a long-run memory test)
test -z "$(gofmt -l cmd gui internal)"         # gofmt -l alone exits 0
SIMPLETOKEN_SHOTS=/tmp/shots go test ./gui/    # renders of window, panel, settings, menu bar (demo data)
go tool mygo build -skip-dmg -sign -           # ad-hoc build/mygo/darwin-arm64/SimpleToken.app
```

README images: `SIMPLETOKEN_README_IMAGES=docs/images go test ./gui/ -run TestReadmeImages`. Swift 0.1.x: `cd SimpleTokenKit && swift test`, then `xcodegen generate` and `xcodebuild -project SimpleToken.xcodeproj -scheme SimpleToken -configuration Release build`.

Releases: a `vX.Y.Z` tag runs `.github/workflows/release.yml` → `scripts/release.sh` (`mygo build`, Developer ID, notarization, signed update archive; [docs/RELEASING.md](docs/RELEASING.md)). `main` changes only through a PR. Bundle id `dev.hanlun.simpletoken` (same data dir and formats as 0.1.x; settings import once from UserDefaults; keep the pre-rename `dev.hanlun.lumen` migration). `SIMPLETOKEN_DATA_DIR` points a build at a copy of the data: never run a dev build against the live data dir while another version runs. `SIMPLETOKEN_DEMO=1` is synthetic data; `SIMPLETOKEN_TOKSCALE_PATH` overrides the bundled tokscale. Measure resource use on a release build.

## Layout

`internal/` is the UI-free core (collector, history, intraday, limits, analytics, settings, format, platform/darwin); `gui/` is the only package importing mygo (named `gui`, not `app`: `App/` collides on a case-insensitive disk); `cmd/simpletoken` is the entry. Data lives in `~/Library/Application Support/SimpleToken/`. `designs/` is git-ignored: `designs/simpletoken-v3/project` is the design source. `docs/images/` holds the README screenshots (demo data only).

## Localization

English is the source language. `L("…")` keys are the English text (`%lld`, `%@`, positional `%1$@`); translations live in `gui/i18n/Localizable.xcstrings` (embedded; `App/Localizable.xcstrings` is the Swift app's). Dates and numbers go through `fmtr` (`ShortDate`, `Weekday`, `ResetTime`, CJK units). No CJK characters anywhere else: `grep -rnP '[\x{4e00}-\x{9fff}]' --exclude=*.xcstrings`.

## Design constraints (owner decisions, v3 design, 2026-11-05)

Implementation detail: [docs/agent-reference.md](docs/agent-reference.md).

- SimpleToggle's Graphite language: hierarchy from the ink's opacity, one signal colour. Colour lives in the data; the interface stays neutral. Palettes Graphite (default), Paper, Ice, each dark and light; the theme follows the system unless set.
- No Liquid Glass: cards are the card ground and one hairline; only the drop-down panel uses vibrancy (Glass / Solid).
- Glow only for what is happening now (the live end point, the gauge needle, today's cell, refreshing) and for over-threshold limits. Nothing animates at idle; only a manual refresh spins.
- Colour follows the model family, never its rank: opus clay, sonnet dark clay, gpt / codex slate, gemini violet, haiku rose, fable violet; the rest fold into Other (ink). Tools: Claude Code clay, Codex slate, Gemini CLI violet, Cursor and Grok ink. The Ink mode uses the ink ladder by 30-day rank. No yellow family; no teal, mint or green for a series (Codex never green). Light values were validated on white, dark on #161616: run the dataviz validator before adding a colour.
- A model's name always carries its vendor's logo in the model's colour. Brand logos are mono SVGs tinted by the UI (normalise SVG path data when adding one).
- The window and the panel render at 90 % zoom (`uiZoom`, owner decision 2026-11-05); layout values stay the design's. The grid uses even column counts.
- Big figures: Geist Regular, −0.04 em, tabular digits; a gauge centres its figure and hangs the % off the right. Labels and numbers: Geist Mono.
- Limit gauge: 270°, 42 ticks; used in the vendor colour, at-this-pace-by-reset in the same hue at 30 %, a glowing needle for time gone; red with "!" over the threshold; dotted with "—" without data; no needle when stale. Forecast: a straight line once 5 % of a window has passed, Claude usage history before (owner decision 2026-10-26).
- Colour slots and folding follow the trailing 30 days, never the selected range. Token numbers honour short / exact except axis ticks (always short).
- Dashboard: 184-pt rows, columns of at least 290 pt; cards S 1×1, M 2×1, L 2×2, W 4×1, each size its own layout; edit mode (grip, size chips, remove, drawer); options on the card back. Settings live in the main window: seven sections, two columns.
- Menu bar: one image (gauge, numbers or bars), up to four values in two rows with short English codes (default) or one line; a template image unless a value is over the alert threshold. Limit alerts post once per window period, at the threshold and at 95 %.

## Performance budget

v2 build, same data, menu bar only, 2 min (2026-11-05): 43 MB footprint and 1.7 CPU-s against 0.1.5's 184 MB and 4.0 CPU-s; about 129 MB with the window open. Keep it that way:

- Views never block on mygo app calls: read once and cache; appearance comes from `c.Theme().Dark`.
- Live updates (collector live mode, intraday scans) pause when nothing visible needs them; a paused loop keeps no timer. The window and the panel drop their UI tree when closed.
- tokscale's period scans stay serial and throttled (`liveRefreshSeconds`, full rescans every `fullRefreshMinutes`); every spawned CLI goes through `proc.Run`'s clean environment (an inherited `CLAUDE_CODE_*` turns a child `claude` into an API-billed session).
- Bounded state: derived values are memoized per data version (reports, tool × model pairs, colours, month cost); the intraday scanner prunes everything past its kept days; bitmap caches are capped. `internal/leakcheck` tests guard every background store, `TestLongRunMemoryIsStable` the UI.
- Dense grids (calendar, time of day, waffle, ticks) draw in one `Draw` and hit-test by coordinates; no formatter construction in render paths.
- Limit probes go through `darwin.URLSessionTransport` (claude.ai's Cloudflare challenges Go's TLS).

## Data sources and gotchas

Details (tokscale scans, the Cursor sync, the intraday scanner, the Claude / Codex / Cursor limit probes, legacy import) are in [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md), written for 0.1.x; the Go ports keep the same behaviour. The Claude plan comes from claude.ai's organisation record first, Claude Code's Keychain item (this user's account) second.
