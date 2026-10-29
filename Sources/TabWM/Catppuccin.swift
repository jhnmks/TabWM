import AppKit
import SwiftUI
import TabWMCore

/// The official Catppuccin palettes (https://catppuccin.com/palette): Latte for light mode,
/// Mocha for dark mode. Each accent has the same name in both, so one choice works in both.
enum Catppuccin {
    struct Palette {
        let accents: [String: UInt32]
        let base: UInt32, mantle: UInt32, crust: UInt32
        /// Tab strip background.
        let strip: UInt32
        let surface0: UInt32, surface1: UInt32
        let text: UInt32, subtext: UInt32
    }
    static let latte = Palette(
        accents: [
            "rosewater": 0xdc8a78, "flamingo": 0xdd7878, "pink": 0xea76cb, "mauve": 0x8839ef,
            "red": 0xd20f39, "maroon": 0xe64553, "peach": 0xfe640b, "yellow": 0xdf8e1d,
            "green": 0x40a02b, "teal": 0x179299, "sky": 0x04a5e5, "sapphire": 0x209fb5,
            "blue": 0x1e66f5, "lavender": 0x7287fd,
        ],
        base: 0xeff1f5, mantle: 0xe6e9ef, crust: 0xdce0e8, strip: 0xe6e9ef, surface0: 0xccd0da, surface1: 0xbcc0cc,
        text: 0x4c4f69, subtext: 0x6c6f85)
    static let mocha = Palette(
        accents: [
            "rosewater": 0xf5e0dc, "flamingo": 0xf2cdcd, "pink": 0xf5c2e7, "mauve": 0xcba6f7,
            "red": 0xf38ba8, "maroon": 0xeba0ac, "peach": 0xfab387, "yellow": 0xf9e2af,
            "green": 0xa6e3a1, "teal": 0x94e2d5, "sky": 0x89dceb, "sapphire": 0x74c7ec,
            "blue": 0x89b4fa, "lavender": 0xb4befe,
        ],
        base: 0x1e1e2e, mantle: 0x181825, crust: 0x11111b, strip: 0x1e1e2d, surface0: 0x313244, surface1: 0x45475a,
        text: 0xcdd6f4, subtext: 0xa6adc8)

    /// A color that switches between Latte and Mocha with the current appearance.
    static func color(_ pick: @escaping (Palette) -> UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return nsColor(pick(dark ? mocha : latte))
        })
    }
    static func accent(_ name: String) -> Color { color { $0.accents[name] ?? $0.accents["blue"]! } }
    static func accent(_ name: String, dark: Bool) -> Color { Color(nsColor: nsColor((dark ? mocha : latte).accents[name] ?? 0)) }
    static func nsColor(_ hex: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
                blue: CGFloat(hex & 0xff) / 255, alpha: 1)
    }
    static let base = color(\.base), strip = color(\.strip), surface0 = color(\.surface0)
    static let text = color(\.text), subtext = color(\.subtext)

    static func title(_ name: String) -> String { name.prefix(1).uppercased() + name.dropFirst() }
}

/// The empty dot in the tab strip: opens the color picker.
struct PaletteDot: View {
    @ObservedObject var controller: AppController
    @State private var hovering = false
    @State private var open = false
    var body: some View {
        let catppuccin = controller.settings.frameStyle == "catppuccin"
        Button { open.toggle() } label: {
            Circle()
                .strokeBorder(catppuccin ? Catppuccin.text : Color.secondary, lineWidth: 1.5)
                .frame(width: 11, height: 11)
                .frame(width: 24, height: 22)
                .background(hovering ? Color.primary.opacity(0.08) : Color.clear, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain).help("Frame colors").onHover { hovering = $0 }
        .popover(isPresented: $open, arrowEdge: .bottom) { FrameStylePicker(controller: controller).padding(18).frame(width: 340) }
    }
}

/// Glass or Color (Catppuccin), and the accent for the border. Used in the tab strip popover
/// and in Settings → Appearance.
struct FrameStylePicker: View {
    @ObservedObject var controller: AppController
    let columns = Array(repeating: GridItem(.fixed(36), spacing: 8), count: 7)
    var body: some View {
        let catppuccin = controller.settings.frameStyle == "catppuccin"
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                styleButton("Glass", symbol: "drop", style: "glass")
                styleButton("Color", symbol: "paintpalette", style: "catppuccin")
            }
            Text(catppuccin
                 ? "Solid colors from the Catppuccin palette: Latte in light mode, Mocha in dark mode. Pick the border color:"
                 : "See-through Liquid Glass that picks up the colors behind it.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if catppuccin {
                LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
                    ForEach(AppSettings.frameColors, id: \.self) { name in swatch(name) }
                }
                HStack(spacing: 6) {
                    Text(Catppuccin.title(controller.settings.frameColor)).font(.callout.weight(.semibold))
                    Text("· Latte").font(.callout).foregroundStyle(.secondary)
                    Circle().fill(Catppuccin.accent(controller.settings.frameColor, dark: false)).frame(width: 10, height: 10)
                    Text("· Mocha").font(.callout).foregroundStyle(.secondary)
                    Circle().fill(Catppuccin.accent(controller.settings.frameColor, dark: true)).frame(width: 10, height: 10)
                }
            }
        }
    }
    /// A glass button; the chosen style is the filled one.
    @ViewBuilder func styleButton(_ title: String, symbol: String, style: String) -> some View {
        let selected = controller.settings.frameStyle == style
        Button { controller.settings.frameStyle = style } label: {
            Label(title, systemImage: symbol).frame(minWidth: 84)
        }
        .glassButtonStyle(prominent: selected)
        .controlSize(.large)
    }
    /// Each swatch shows the Latte color on the left half and the Mocha color on the right.
    func swatch(_ name: String) -> some View {
        let selected = controller.settings.frameColor == name
        return Button { controller.settings.frameColor = name } label: {
            ZStack {
                HStack(spacing: 0) {
                    Catppuccin.accent(name, dark: false)
                    Catppuccin.accent(name, dark: true)
                }
                .clipShape(Circle())
                .frame(width: 28, height: 28)
                Circle().strokeBorder(selected ? Color.primary : Color.clear, lineWidth: 2).frame(width: 36, height: 36)
            }
            .frame(width: 36, height: 36).contentShape(Circle())
        }
        .buttonStyle(.plain).help(Catppuccin.title(name))
    }
}
