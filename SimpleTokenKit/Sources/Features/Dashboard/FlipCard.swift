import SwiftUI
import Core
import DesignSystem

/// Flips like a widget: the front is the chart, the back holds this card's settings.
/// The back is mounted only while flipped; while open the card takes the taller of the two faces, and shrinks back after flipping back.
struct FlipCard<Front: View, Back: View>: View {
    let flipped: Bool
    @ViewBuilder var front: Front
    @ViewBuilder var back: Back
    @State private var angle: Double = 0
    @State private var backMounted = false

    private static var spring: Animation { .spring(duration: 0.6, bounce: 0.16) }

    var body: some View {
        ZStack(alignment: .top) {
            front.modifier(FlipFace(angle: angle, isBack: false))
            if backMounted {
                back.modifier(FlipFace(angle: angle, isBack: true))
            }
        }
        .onChange(of: flipped) { _, now in
            if now {
                backMounted = true
                withAnimation(Self.spring) { angle = 180 }
            } else {
                withAnimation(Self.spring) { angle = 0 } completion: {
                    if !flipped { withAnimation(.smooth(duration: 0.3)) { backMounted = false } }
                }
            }
        }
    }
}

/// One face: rotates around the vertical axis; past 90° the other face becomes visible (checked per frame on the interpolated angle)
private struct FlipFace: ViewModifier, Animatable {
    var angle: Double
    let isBack: Bool

    nonisolated var animatableData: Double {
        get { angle }
        set { angle = newValue }
    }

    func body(content: Content) -> some View {
        let shown = isBack ? angle >= 90 : angle < 90
        content
            .rotation3DEffect(.degrees(isBack ? angle - 180 : angle), axis: (x: 0, y: 1, z: 0), perspective: 0.35)
            .opacity(shown ? 1 : 0)
            .allowsHitTesting(shown)
    }
}

// MARK: - Back face layout

/// Card back: title + options + color + hide / reset + done
struct CardBack<Content: View>: View {
    let title: String
    var accentKey: String?
    var accentDefault: Accent = .blue
    var onHide: (() -> Void)?
    var onReset: (() -> Void)?
    var padding: CGFloat = 16
    var radius: CGFloat = 18
    let done: () -> Void
    @ViewBuilder var content: Content
    @Bindable private var settings = SettingsStore.shared
    @Environment(\.dashboardCard) private var card

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(title).cardTitle().lineLimit(1).minimumScaleFactor(0.85)
                Spacer(minLength: 4)
                if let onHide {
                    Button(action: onHide) {
                        Image(systemName: "eye.slash").font(.app(Typo.small, .semibold))
                            .frame(width: 24, height: 24).contentShape(Circle())
                    }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .help("Hide this widget (bring it back from ▦ in the top bar)")
                }
                Button("Done", action: done)
                    .buttonStyle(.glassProminent).tint(Accent.blue.color)
                    .controlSize(.small)
                    .keyboardShortcut(.defaultAction)
            }
            // Widget height is fixed: many options scroll inside the back face
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 8) {
                    if let card, card.sizes.count > 1 {
                        OptionRow(L("Size")) { CardSizePicker(card: card) }
                    }
                    content
                    if let accentKey {
                        OptionRow(L("Color")) { AccentPicker(key: accentKey, fallback: accentDefault) }
                    }
                    if let onReset {
                        Button { onReset() } label: { Label("Reset to Default", systemImage: "arrow.counterclockwise") }
                            .buttonStyle(.plain).font(.app(Typo.small)).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.automatic)
            .frame(maxHeight: .infinity)
        }
        .glassCard(padding: padding, radius: radius, tint: accentKey.map { Accent.resolve(settings.cardAccents[$0], fallback: accentDefault) })
    }
}

/// A back-face row: label on the left, control on the right
struct OptionRow<Control: View>: View {
    let label: String
    @ViewBuilder var control: Control

    init(_ label: String, @ViewBuilder control: () -> Control) {
        self.label = label
        self.control = control()
    }

    var body: some View {
        // Control sits on the label's line when it fits, otherwise (narrow card / long segments) wraps below it
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                Text(label).font(.app(Typo.body)).foregroundStyle(.secondary).lineLimit(1).fixedSize()
                Spacer(minLength: 8)
                control.fixedSize()
            }
            VStack(alignment: .leading, spacing: 5) {
                Text(label).font(.app(Typo.body)).foregroundStyle(.secondary).lineLimit(1)
                control
            }
        }
        .frame(minHeight: 22)
    }
}

/// Toggle for the back face (mini size)
struct MiniToggle: View {
    @Binding var isOn: Bool
    var body: some View {
        Toggle("", isOn: $isOn).labelsHidden().toggleStyle(.switch).controlSize(.mini).tint(Accent.blue.color)
    }
}

/// Accent picker: preset dots + custom color
struct AccentPicker: View {
    let key: String
    let fallback: Accent
    @Bindable private var settings = SettingsStore.shared

    var body: some View {
        let stored = settings.cardAccents[key]
        HStack(spacing: 5) {
            ForEach(Accent.allCases) { a in
                let selected = stored == a.rawValue || (stored == nil && a == fallback)
                Circle().fill(a.color)
                    .frame(width: 14, height: 14)
                    .overlay(Circle().stroke(Color.white.opacity(selected ? 0.9 : 0), lineWidth: 1.5).padding(-3))
                    .contentShape(Circle().inset(by: -3))
                    .onTapGesture {
                        withAnimation(.smooth(duration: 0.3)) {
                            if a == fallback { settings.cardAccents.removeValue(forKey: key) } else { settings.cardAccents[key] = a.rawValue }
                        }
                    }
                    .help(a.localizedName)
            }
            ColorPicker("", selection: Binding(
                get: { Accent.resolve(stored, fallback: fallback) },
                set: { settings.cardAccents[key] = $0.hexString }
            ), supportsOpacity: false)
            .labelsHidden()
            .controlSize(.mini)
            .help("Custom color")
        }
        .padding(.leading, 3)
    }
}

extension SettingsStore {
    /// Card accent color (the card's default when unset)
    func accent(_ key: String, _ fallback: Accent) -> Color {
        Accent.resolve(cardAccents[key], fallback: fallback)
    }
}
