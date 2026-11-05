package gui

import (
	"github.com/egoist/mygo/ui"
)

// onboarding is the window before the first collection is in (designs/simpletoken-v3 States board): what the app
// is, and that the history is being built; the dashboard replaces it as soon as today is read.
func (a *ctrl) onboarding(c *ui.Context, p palette) {
	ui.Column(c.Key("onboard")).Fill().AlignItems(ui.Center).Justify(ui.Center).Children(func() {
		ui.Column(c.Key("card")).Width(420).Padding(28, 28, 24).Gap(16).Radius(10).Border(1, p.L2).Background(p.Surf).Children(func() {
			p.brand(c, 14, true)
			ui.Text(c, L("Usage and limits for your AI coding tools, in the menu bar.")).FontSize(13).TextColor(p.T2).Wrap()
			ui.Box(c).FillWidth().Height(1).Background(p.L2)
			ui.Row(c.Key("busy")).Gap(10).AlignItems(ui.Center).Children(func() {
				p.dotRun(c, 11)
				ui.Text(c, L("Building your history…")).FontSize(13).FontWeight(500).TextColor(p.T1).SingleLine()
			})
			ui.Text(c, L("Reading the logs Claude Code, Codex, Gemini CLI and Cursor keep on this Mac. The dashboard opens as soon as today is in.")).
				FontSize(11).TextColor(p.T3).LineHeight(1.5).Wrap()
		})
	})
}

// needsOnboarding is a first launch: nothing collected and no history yet.
func (a *ctrl) needsOnboarding() bool {
	return !a.demo && !a.m.d.Collected && len(a.m.d.History) == 0
}
