import AppKit
import SwiftUI

// Liquid Glass on macOS 26, with material fallbacks for the macOS 15 deployment target.
extension View {
    @ViewBuilder
    func liquidGlass<S: Shape>(in shape: S, tint: Color? = nil, interactive: Bool = false, clear: Bool = false) -> some View {
        if #available(macOS 26.0, *) {
            glassEffect((clear ? Glass.clear : Glass.regular).tint(tint).interactive(interactive), in: shape)
        } else {
            background {
                ZStack {
                    shape.fill(clear ? Material.ultraThinMaterial : Material.regularMaterial)
                    if let tint { shape.fill(tint.opacity(0.35)) }
                }
            }
        }
    }

    @ViewBuilder
    func glassButtonStyle(prominent: Bool = false) -> some View {
        if #available(macOS 26.0, *) {
            if prominent { buttonStyle(.glassProminent) } else { buttonStyle(.glass) }
        } else {
            if prominent { buttonStyle(.borderedProminent) } else { buttonStyle(.bordered) }
        }
    }
}

struct LiquidGlassGroup<Content: View>: View {
    var spacing: CGFloat? = nil
    @ViewBuilder var content: () -> Content
    var body: some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { content() }
        } else {
            content()
        }
    }
}

struct GlassSearchField: View {
    let prompt: String
    @Binding var text: String
    var large = false
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField(prompt, text: $text).textFieldStyle(.plain)
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }.buttonStyle(.plain)
            }
        }
        .font(.system(size: large ? 17 : 13))
        .padding(.horizontal, 14).padding(.vertical, large ? 12 : 8)
        .liquidGlass(in: Capsule(), interactive: true)
    }
}

/// Borderless floating panel whose whole surface is glass, used for search and the window picker.
@MainActor
final class GlassPanel: NSPanel {
    init(size: NSSize) {
        super.init(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        isOpaque = false; backgroundColor = .clear; hasShadow = true
        level = .floating; isMovableByWindowBackground = true
        isReleasedWhenClosed = false; hidesOnDeactivate = false
        collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
    }
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    override func resignKey() { super.resignKey(); close() }
    override func cancelOperation(_ sender: Any?) { close() }

    static func make<V: View>(size: NSSize, cornerRadius: CGFloat = 26, view: V) -> GlassPanel {
        let panel = GlassPanel(size: size)
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height).clipShape(shape).liquidGlass(in: shape))
        host.sizingOptions = []
        // The glass backdrop is drawn in a rectangular layer; without clipping the host itself,
        // its square corners (and a square shadow) show around the rounded panel.
        host.wantsLayer = true
        host.layer?.cornerRadius = cornerRadius
        host.layer?.cornerCurve = .continuous
        host.layer?.masksToBounds = true
        panel.contentView = host
        panel.center()
        // The shadow follows the rounded content once it has been drawn.
        DispatchQueue.main.async { panel.invalidateShadow() }
        return panel
    }
}
