import SwiftUI
import AppKit
import Core
import DesignSystem

/// Entity colours: colours follow the model / tool, not the selected range or ranking.
public enum ModelPalette {
    /// Default tool (provider) colours: Claude terracotta, Codex teal, Copilot indigo, others grey
    public static func defaultToolColor(_ id: String) -> Color {
        switch id.lowercased() {
        case "claude": Palette.claude
        case "codex": Palette.teal
        case "copilot": Palette.indigo
        case "gemini": Color(hex: "#6b8fd6")
        default: Palette.other
        }
    }

    /// Tool colour (including user overrides)
    @MainActor public static func toolColor(_ id: String) -> Color {
        if let hex = SettingsStore.shared.toolColorOverrides[id.lowercased()] { return Color(hex: hex) }
        return defaultToolColor(id)
    }

    public static let toolLabels: [String: String] = [
        "claude": "Claude Code", "codex": "Codex", "copilot": "Copilot",
        "opencode": "OpenCode", "gemini": "Gemini", "cursor": "Cursor", "kiro": "Kiro",
    ]

    public static func toolLabel(_ id: String) -> String {
        id == otherKey ? L("Other") : toolLabels[id] ?? id
    }

    /// Short model name: claude-opus-5-5 → opus-5-5; `<synthetic>` → Synthetic
    public static func shortName(_ model: String) -> String {
        if model == otherKey { return L("Other") }
        if model.lowercased().contains("synthetic") { return L("Synthetic") }
        return model.replacingOccurrences(of: "claude-", with: "")
    }

    public static let otherKey = "__other__"

    // MARK: Vendors

    public enum Vendor: String, CaseIterable, Sendable {
        case anthropic, openai, google, other

        public var localizedName: String {
            switch self {
            case .anthropic: "Anthropic"
            case .openai: "OpenAI"
            case .google: "Google"
            case .other: L("Other")
            }
        }

        /// Vendor base colour: matches the tool colour (Claude terracotta, OpenAI/Codex teal, Google indigo)
        public var base: Color { ladder[0] }

        /// Colours taken in usage-rank order within a vendor: base → very light → very dark → hue-shifted light;
        /// the four steps are pairwise ΔE ≈ 14+ (dataviz-validated); further models get shade variations within the hue
        public var ladder: [Color] {
            switch self {
            case .anthropic: ["#c17755", "#f8d7be", "#6e3a28", "#f59aa1"].map(Color.init(hex:))
            case .openai: ["#209993", "#b3e6e2", "#185a56", "#72b4d8"].map(Color.init(hex:))
            case .google: ["#505ba7", "#c5ccf2", "#323a70", "#8fa3e0"].map(Color.init(hex:))
            case .other: ["#8a8a8e", "#c8c8cc", "#5a5a5e", "#a8a8ac"].map(Color.init(hex:))
            }
        }

        public func color(step: Int) -> Color {
            step < ladder.count ? ladder[step] : ladder[step % ladder.count].shade(1 + step / ladder.count)
        }
    }

    public static func vendor(_ model: String) -> Vendor {
        let m = model.lowercased()
        if ["claude", "opus", "sonnet", "haiku", "fable", "mythos"].contains(where: m.contains) { return .anthropic }
        if m.contains("gpt") || m.contains("codex") || m.hasPrefix("o1") || m.hasPrefix("o3") || m.hasPrefix("o4") { return .openai }
        if m.contains("gemini") { return .google }
        return .other
    }
}

/// Model → colour / group / display name. One instance is shared across a render so a model has the same colour on every chart.
public struct ModelColors: Sendable {
    /// Models with their own colour (by usage rank; also the stacking and legend order); the rest go into "Other"
    public let ordered: [String]
    private let colors: [String: Color]
    private let aliases: [String: String]
    private let toolOverrides: [String: String]

    /// - ranked: models sorted by trailing-30-day usage
    /// - mode: "vendor" (vendor colours, shades by rank within a vendor) / "ranked" (top three get the three slots, colour-blind safe)
    public init(rankedModels: [String], mode: String = "vendor", overrides: [String: String] = [:],
                aliases: [String: String] = [:], toolOverrides: [String: String] = [:], separate: Int = 4) {
        let models = rankedModels.filter { !$0.lowercased().contains("synthetic") }
        let limit = mode == "ranked" ? Palette.slots.count : max(1, separate)
        ordered = Array(models.prefix(limit))
        var map: [String: Color] = [:]
        if mode == "ranked" {
            for (i, m) in ordered.enumerated() { map[m] = Palette.slots[i] }
        } else {
            var perVendor: [ModelPalette.Vendor: Int] = [:]
            for m in models {
                let v = ModelPalette.vendor(m)
                let step = perVendor[v, default: 0]
                perVendor[v] = step + 1
                map[m] = v.color(step: step)
            }
        }
        for (m, hex) in overrides { map[m] = Color(hex: hex) }
        colors = map
        self.aliases = aliases
        self.toolOverrides = toolOverrides
    }

    /// Colour of any model (models without their own slot are "Other" in charts but keep their own colour in tooltips)
    public func color(_ model: String) -> Color {
        if model == ModelPalette.otherKey { return Palette.other }
        return colors[model] ?? ModelPalette.vendor(model).color(step: 4)
    }

    /// Colour after grouping: models without their own slot are grey
    public func groupColor(_ key: String) -> Color {
        ordered.contains(key) ? color(key) : Palette.other
    }

    /// Grouping: models with a colour slot keep their name, the rest go into "Other"
    public func group(_ model: String) -> String {
        ordered.contains(model) ? model : ModelPalette.otherKey
    }

    /// Stacking and legend order: slot order + Other
    public var stackOrder: [String] { ordered + [ModelPalette.otherKey] }

    public func name(_ model: String) -> String {
        if let alias = aliases[model], !alias.isEmpty { return alias }
        return ModelPalette.shortName(model)
    }

    public func toolColor(_ id: String) -> Color {
        if id == ModelPalette.otherKey { return Palette.other }
        if let hex = toolOverrides[id.lowercased()] { return Color(hex: hex) }
        return ModelPalette.defaultToolColor(id)
    }
}
