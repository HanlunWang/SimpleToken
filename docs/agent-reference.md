# Agent reference

Implementation detail behind the design constraints in [AGENTS.md](../AGENTS.md). Load only for the task named in each section; the rules in `AGENTS.md` stay binding.

## Localization

Load when adding or translating strings.

English is the source language. Strings reach the UI through SwiftUI `LocalizedStringKey` literals (`Text("…")`, `Button`, `.help`…) or `L("…")` (Core; `String(localized:)` in DesignSystem) for anything passed around as `String`. Translations live in `App/Localizable.xcstrings` (keys are the English text; `%@` for `String`, `%lld` for `Int`, `%lf` for `Double` interpolations). Numbers and dates go through `Fmt` (K/M/B in English, CJK ten-thousand units via the catalog's `unit.*` keys; locale-aware date templates). No CJK characters anywhere else; check with `grep -rnP '[\x{4e00}-\x{9fff}]'`.

## Logo and app icon

Load when touching the logo, app icon or brand mark.

- Logo: glass token with a ¾ gauge arc, black and white only. App icon = `designs/logo/app-icon-source.webp` cut to the macOS grid (824 on 1024) in `AppIcon.appiconset`; the small mark is vector (`BrandMarkGeometry`) after `designs/logo/glyph-source.png`.

## Surfaces and glass

Load when changing backgrounds, glass or the drop-down panel.

- Dark only. Opaque near-black ground with a faint white ambient light; **no glow effects** on marks or text. Cards and controls use native Liquid Glass (`glassEffect`, `GlassEffectContainer`, `glassEffectID`). The drop-down panel is the one surface that is translucent over the desktop: a deep near-black wash over glass (`PanelBackground`), with glass cards on top like the dashboard.

## Widget grid

Load when adding or changing a dashboard widget or the grid.

- Single-series cards take a per-card accent (`SettingsStore.cardAccents`, presets in `Accent`); run the dataviz validator before adding palette colours.
- Settings live inside the main window (`AppState.showingSettings` → `SettingsPage`), not a separate window. Widget options are on the back face (`FlipCard` + `CardBack`).
- The dashboard is a widget grid (`WidgetGrid`): fixed 150 pt rows, an even number of ≥160 pt columns (2–8) chosen from the window width, dense first-fit packing. Every widget is a `SettingsStore.Card` (each stat is its own `stat.*` widget) with its own allowed `sizes` (small 1×1, medium 2×1, large 2×2, wide 4×2; wide falls back to large at 2 columns) and a distinct layout per size read from `\.cardSize`. Shared widget anatomy lives in `WidgetParts.swift` (`WidgetHeader` with a tinted icon chip, `BigNumber` / `MoneyNumber` in rounded numerals sized by `WidgetStyle.number`, `FactsRow`, `DeltaChip`): header, then the main number top-aligned, then the visual; large sizes end with a facts row. Widgets are dragged in place (`CardDrag`, `DraggableCard`: floating copy over a dashed slot). Card backs scroll inside the fixed cell.

## Brand logos, settings and menu bar

Load when adding a brand logo, a settings tab, or a menu bar style.

- Brand logos are mono SVGs from yldm-tech/ai-logo in `DesignSystem/Resources/logos`, always tinted by the UI (`EntityMark`, `BrandBadge`), never brand-coloured. Normalise SVG path data when adding one (CoreSVG mis-parses compact arc flags).
- Settings are tabbed (`SettingsTab`, `AppState.settingsTabKey`). Limit alerts: `LimitNotifier` posts once per window period per threshold; it needs a bundle id.
- The menu bar item is one image drawn by `MenuBarRenderer` (styles: single line, two lines, compact, ring, nested rings, bar; items from `SettingsStore.menuBarItems`). Template image unless a value is over the alert threshold.

## Charts

Load when adding or changing a chart or hover readout.

- Every chart comes from `ChartKit.swift` (no Swift Charts): Canvas marks in the depth look (rounded, lit top-left, grooves: `Depth`, `GraphicsContext.column/cell/dot`) that morph via `Animatable` + `AnimatableVector`; `Motion.data` / `Motion.hover` honour reduce-motion; `Entrance` grow-in is off for the drag copy. Hover readouts are `TipCard`s through `HoverTip.show(id, key:, at:, glide:)`, drawn above all cards in the dashboard coordinate space.
