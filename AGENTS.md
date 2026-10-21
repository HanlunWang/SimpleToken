# AGENTS.md

SimpleToken (formerly Lumen) — native SwiftUI macOS menu-bar + window tracker for AI coding usage (Claude Code, Codex). Successor to an Electron token monitor; detection logic is ported from it. User-facing docs: [README.md](README.md). The repo is public: everything (code, comments, docs, commits) is English; the only non-English text is the translation catalog.

## Build and verify

```bash
cd SimpleTokenKit && swift test                # Core unit tests (Swift Testing)
xcodegen generate                              # after adding/removing App files or editing project.yml
xcodebuild -project SimpleToken.xcodeproj -scheme SimpleToken -derivedDataPath build -configuration Release build
```

Releases: a `vX.Y.Z` tag runs `.github/workflows/release.yml` ([docs/RELEASING.md](docs/RELEASING.md)). Signing: `Config/Signing.xcconfig` signs ad-hoc; put your identity and team in the git-ignored `Config/Signing.local.xcconfig`. Bundle id `dev.hanlun.simpletoken` (`AppPaths.migrateFromLumenIfNeeded()` imports the pre-rename `dev.hanlun.lumen` data; keep it). Measure resource use on a **Release** build. `SIMPLETOKEN_TOKSCALE_PATH` overrides the bundled tokscale (release builds need it outside the app bundle).

## v2 rewrite (Go + mygo, branch `v2`)

The Swift app is being replaced by a Go app on [mygo](https://github.com/egoist/mygo) native UI; both live in the repo until v2 ships. Design reference: the local prototype `designs/simpletoken-v2/` (git-ignored).

```bash
go test ./internal/... && go vet ./...         # core (UI-free) + everything
SIMPLETOKEN_SHOTS=/tmp/shots go test ./gui/    # headless renders of window / panel / settings / menu bar (demo data)
go tool mygo build -skip-dmg -sign -           # ad-hoc build/mygo/darwin-arm64/SimpleToken.app
```

- `internal/` knows nothing of mygo; `gui/` is the only package that imports it (named `gui`, not `app`: `App/` would collide on a case-insensitive disk). `cmd/simpletoken` is the entry.
- On-disk formats stay those of the Swift app (same data dir and bundle id); settings move from UserDefaults to `settings.json`, imported once. Never run a dev build against the live data dir while 0.1.x runs: point `SIMPLETOKEN_DATA_DIR` at a copy.
- Limit probes go through `darwin.URLSessionTransport` (claude.ai's Cloudflare challenges Go's TLS). Views never block on mygo app calls (they hang headless tests); read them once and cache.

## Layout

`SimpleTokenKit` SwiftPM package: `Core` (collection, analytics, limits, persistence — no UI), `DesignSystem` (palette, glass components), `Features` (views, windows, menu bar). `App/` is the thin xcodegen shell. Data lives in `~/Library/Application Support/SimpleToken/`. `designs/logo/` holds the icon sources; `docs/images/` the README screenshots (demo data only).

## Localization

English is the source language. Strings reach the UI through SwiftUI `LocalizedStringKey` literals or `L("…")` (Core; `String(localized:)` in DesignSystem) for anything passed around as `String`. Translations live in `App/Localizable.xcstrings`; numbers and dates go through `Fmt`. No CJK characters anywhere else; check with `grep -rnP '[\x{4e00}-\x{9fff}]'`. Placeholders and `Fmt` units: [docs/agent-reference.md](docs/agent-reference.md) ▸ Localization.

## Design constraints (owner decisions)

Implementation detail (icon grid, widget sizes and anatomy, menu bar styles, chart marks): load only when working on that area, [docs/agent-reference.md](docs/agent-reference.md).

- Logo: glass token with a ¾ gauge arc, black and white only.
- Dark only: opaque near-black ground, faint white ambient light, **no glow effects** on marks or text. Cards and controls use native Liquid Glass; the drop-down panel (`PanelBackground`) is the one surface translucent over the desktop.
- Model colours default to **vendor ladders** (`ModelPalette.Vendor.ladder`: Anthropic terracotta, OpenAI teal, Google indigo). The colour-blind-safe mode uses three CVD-validated slots (`Palette.slots`), everything else grey. No yellow family. Do not give Codex a green: terracotta + green is indistinguishable for deuteranopes. Token composition uses its own validated four (`Palette.composition`). Single-series cards take a per-card accent (`SettingsStore.cardAccents`); run the dataviz validator before adding palette colours.
- Model colour slots follow the trailing-30-day ranking (`AppState.modelColors`), never the selected range.
- Token numbers honour the short/exact toggle everywhere except axis ticks (always short).
- Settings live inside the main window (`AppState.showingSettings` → `SettingsPage`, tabbed), not a separate window. Widget options are on the back face (`FlipCard` + `CardBack`).
- The dashboard is a widget grid (`WidgetGrid`); every widget is a `SettingsStore.Card` with its own allowed sizes and a distinct layout per size; shared anatomy lives in `WidgetParts.swift`.
- Brand logos are mono SVGs, always tinted by the UI, never brand-coloured; normalise SVG path data when adding one (CoreSVG mis-parses compact arc flags).
- Limit alerts: `LimitNotifier` posts once per window period per threshold; it needs a bundle id.
- The menu bar item is one image drawn by `MenuBarRenderer`: a template image unless a value is over the alert threshold.
- Every chart comes from `ChartKit.swift` (no Swift Charts); `Motion.data` / `Motion.hover` honour reduce-motion; `Entrance` grow-in is off for the drag copy.
- The top bar is a ZStack overlay with `TopBarScrim` (material + gradient mask), content inset via `safeAreaPadding`. Do not switch back to `safeAreaBar`: on macOS it draws its own hard-edged bar background.
- Excluded models / tools (`SettingsStore.usageFilter`) apply to every derived number: history summaries are filtered per observation, live periods via `UsagePeriod.byPair` (client × model slices).

## Performance budget

Release build, 2026-09-29: ~110 MB footprint with the window open, ~0.3% CPU idle, ~5 CPU-s at launch. Keep it that way:

- Each tokscale scan costs ~1.2 CPU-s and a ~570 MB child process. Watch ticks are **throttled** (`liveRefreshSeconds`, default 30 s; throttle, not debounce), full rescans run every `fullRefreshMinutes` (15), and live updates pause when neither the window nor the panel is visible and the menu bar does not show today's numbers.
- **Never put scroll offsets in dashboard state.** They live in `ScrollTracker` (read only by the top-bar scrim and the hover-tip layer). Hover is ignored mid-scroll (`HoverTip.scrolling`).
- The main window and drop-down panel **drop their SwiftUI hierarchy when closed** and rebuild on show; hidden views would otherwise keep re-rendering on every data change.
- Dense grids (calendar, punchcard, active-day strip) draw with `Canvas` and hit-test by coordinates. Do not go back to one view per cell.
- Never create `DateFormatter` / `NumberFormatter` / `ISO8601DateFormatter` in render or per-line paths (ICU init is expensive): use the cached ones in `Fmt`. The intraday scanner parses timestamps by hand.
- Only a manual refresh spins the top-bar refresh icon. Background ticks and limit-probe retries must not drive continuous animations.
- `AppState.report(range:metric:)`, `pairs(for:)` (tool × model tokens for the map and flow widgets) and `modelColors` are memoized on a data-version key; derive new views from them rather than recomputing `RangeAnalytics` in bodies.

## Data sources and gotchas

Details (tokscale scans, the Cursor sync, the intraday scanner, Claude / Codex / Cursor limit probes, legacy import) are in [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md). Two rules that must not be broken: tokscale's period scans stay serial, and every spawned CLI gets `ProcessRunner.cleanEnvironment()` (an inherited `CLAUDE_CODE_*` turns a child `claude` into an API-billed session).
