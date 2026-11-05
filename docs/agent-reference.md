# Agent reference

Implementation detail behind the design constraints in [AGENTS.md](../AGENTS.md), for the Go app (v2). Load only for the task named in each section; the rules in `AGENTS.md` stay binding. The design source is `designs/simpletoken-v3/project` (git-ignored): `theme.css` holds every token, each `.dc.html` board computes its geometry in `renderVals()`.

## Colour and type

Load when touching colours, fonts or a palette.

- `gui/theme.go` is `theme.css` in Go: `palDark` / `palLight` per palette, `palette.Model`, `Tool`, `Vendor`, `Accent` (Slate, Clay, Violet, Rose with 4-step ramps, lowest value first), `Ink[0…4]` (92 / 62 / 42 / 26 / 14 % ink over the card, opaque). `dim(c)` is a series' 30 % tone.
- `model.modelColor` maps a model id to its family (`modelFamily`); `toolColor`, `vendorTint` likewise. `ctrl.accent` / `ramp` give a card's accent (`defaultAccents`, the user's `cardAccents`).
- Fonts are embedded (`gui/fonts`): Geist and Geist Mono. `bigText` / `bigSpan` are the big-figure face.

## Widgets and the grid

Load when adding or changing a dashboard widget or the grid.

- Every widget is in `cardDefs` (`gui/cards.go`) with its sizes and a layout per size in `cards*.go`; shared anatomy: `cardShell` (header, note, edit chrome, back face), `figure`, `miniBars`, `modelLabel` / `modelMark`, `footRow`, `factInline`.
- `pack` places cards dense first-fit; W (4 × 1) becomes L or M below four columns. Card backs are `cardBack` in `settings_page.go`.
- The limit gauge is `gauge` / `gaugeLine` (`gui/gauge.go`), fed by `limitItems` (`cards_limits.go`), which takes forecasts from `limits.Store.Projected`.

## Charts

Load when adding or changing a chart or hover readout.

- Charts are painter-drawn in `gui/charts.go` and the card files: `areaChart` (cumulative line, previous period, columns, projection, the now dot), `usageBars`, `barChart` (intraday), `treemap`, `sankey`, `calendarDots`, the time-of-day lanes, `waffle`. Lines are Catmull-Rom (`smoothPath`); projections are hatched (`hatch`) or dotted. Hover readouts are `tooltip`s, hit-tested by coordinates.
- `animData` grows marks on change; nothing loops at idle except `dotRun` while refreshing.

## Menu bar, panel and settings

Load when changing the menu bar item, the drop-down panel or a settings section.

- `renderMenuBar` (`gui/menubar.go`) draws the item with x/image: `gauge` (a 22-tick glyph), `numbers`, `bars`; secondary values at 62 % ink. 0.1.x styles map onto gauge / numbers in `settings.normalize`.
- The panel (`gui/panel.go`) is a column of `panelFrame`s with the title on the border; `runsOut` gives the run-out time shown beside an over-threshold window and in alerts.
- Settings (`gui/settings_page.go`): `sGroup` / `sRow` (a hairline above all but a group's first row), `orderList` (grip to drag, switch to include), `thresholdRow` (the alert slider).

## Localization

Load when adding or translating strings.

- New `L("…")` keys need a zh-Hans entry in `gui/i18n/Localizable.xcstrings`; strings passed through tables (`cardDefs`, `settingsTabs`, segment options) count too. A translation may reorder arguments with `%1$@`. Keep the file's two-space JSON and key order (case-insensitive sort).
