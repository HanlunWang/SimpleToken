import SwiftUI
import AppKit

/// Vendor / tool brand logos (mono SVGs from yldm-tech/ai-logo, see THIRD_PARTY_NOTICES).
/// All are used as template images: the UI picks the colour (model, tool or white), never the brand's own.
public enum BrandLogos {
    @MainActor private static var cache: [String: NSImage?] = [:]

    @MainActor public static func image(_ name: String) -> NSImage? {
        if let cached = cache[name] { return cached }
        var image: NSImage?
        if let url = Bundle.module.url(forResource: name, withExtension: "svg", subdirectory: "logos") {
            image = NSImage(contentsOf: url)
            image?.isTemplate = true
        }
        cache[name] = image
        return image
    }

    /// Tool id (claude / codex / copilot…) → logo name
    public static func tool(_ id: String) -> String? {
        switch id.lowercased() {
        case "claude": "claudecode"
        case "codex": "codex"
        case "copilot": "githubcopilot"
        case "opencode": "opencode"
        case "gemini": "geminicli"
        case "cursor": "cursor"
        default: nil
        }
    }

    /// Limit provider → logo name
    public static func provider(_ id: String) -> String? {
        switch id.lowercased() {
        case "claude": "claude"
        case "codex": "codex"
        default: nil
        }
    }

    private static let modelRules: [(needles: [String], logo: String)] = [
        (["claude", "opus", "sonnet", "haiku", "fable", "mythos"], "claude"),
        (["gpt", "codex", "davinci"], "openai"),
        (["gemini"], "gemini"),
        (["deepseek"], "deepseek"),
        (["qwen"], "qwen"),
        (["grok"], "grok"),
        (["mistral", "codestral", "devstral"], "mistral"),
        (["llama"], "meta"),
        (["kimi", "moonshot"], "kimi"),
        (["glm"], "zhipu"),
        (["minimax"], "minimax"),
        (["doubao"], "doubao"),
    ]

    /// Model id → vendor logo name (nil if unrecognised)
    public static func model(_ id: String) -> String? {
        let m = id.lowercased()
        if let hit = modelRules.first(where: { $0.needles.contains(where: m.contains) }) { return hit.logo }
        if m.hasPrefix("o1") || m.hasPrefix("o3") || m.hasPrefix("o4") { return "openai" }
        return nil
    }
}

/// A brand logo tinted with the foreground style
public struct BrandLogo: View {
    let name: String
    let size: CGFloat

    public init(_ name: String, size: CGFloat = 14) {
        self.name = name
        self.size = size
    }

    public var body: some View {
        if let image = BrandLogos.image(name) {
            Image(nsImage: image)
                .resizable()
                .renderingMode(.template)
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: size, height: size)
                .accessibilityHidden(true)
        }
    }
}

/// Entity mark for legends / lists: the brand logo in the given colour, or a swatch when there is none.
/// Colour remains the identifier; the logo is an extra cue.
public struct EntityMark: View {
    let logo: String?
    let color: Color
    let size: CGFloat

    public init(logo: String?, color: Color, size: CGFloat = 12) {
        self.logo = logo
        self.color = color
        self.size = size
    }

    public var body: some View {
        if let logo, BrandLogos.image(logo) != nil {
            BrandLogo(logo, size: size).foregroundStyle(color)
        } else {
            Swatch(color, size: max(6, size * 0.6)).frame(width: size, height: size)
        }
    }
}

/// Provider badge: rounded square in the brand colour + white logo (a text glyph when there is no logo)
public struct BrandBadge: View {
    let logo: String?
    let fallback: String
    let color: Color
    let size: CGFloat

    public init(logo: String?, fallback: String = "•", color: Color, size: CGFloat = 18) {
        self.logo = logo
        self.fallback = fallback
        self.color = color
        self.size = size
    }

    public var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.28).fill(color)
            if let logo, BrandLogos.image(logo) != nil {
                BrandLogo(logo, size: size * 0.66).foregroundStyle(.white)
            } else {
                Text(fallback).font(.system(size: size * 0.6, weight: .bold)).foregroundStyle(.white)
            }
        }
        .frame(width: size, height: size)
    }
}
