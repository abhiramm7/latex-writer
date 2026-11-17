import AppKit

/// Colours for the chrome and the editor. Add a theme by adding one more static value and a case in `named`.
struct Theme {
    var name: String
    var dark: Bool?   // nil follows the system appearance
    var bg, chrome, text, dim, accent, cmd, math, comment, arg, err, warn, ok, errBg, desk: NSColor

    static let system = Theme(
        name: "system", dark: nil,
        bg: .textBackgroundColor, chrome: .windowBackgroundColor, text: .textColor, dim: .secondaryLabelColor,
        accent: .controlAccentColor, cmd: .systemBlue, math: .systemOrange, comment: .systemGray, arg: .systemTeal,
        err: .systemRed, warn: .systemOrange, ok: .systemGreen,
        errBg: NSColor.systemRed.withAlphaComponent(0.15), desk: .underPageBackgroundColor)

    static let nord = Theme(
        name: "nord", dark: true,
        bg: hex(0x2e3440), chrome: hex(0x3b4252), text: hex(0xd8dee9), dim: hex(0x7b88a1),
        accent: hex(0x88c0d0), cmd: hex(0x81a1c1), math: hex(0xd08770), comment: hex(0x616e88), arg: hex(0x8fbcbb),
        err: hex(0xbf616a), warn: hex(0xebcb8b), ok: hex(0xa3be8c),
        errBg: hex(0x4a3540), desk: hex(0x242933))

    static func named(_ name: String) -> Theme { name == "system" ? system : nord }

    /// IBM Plex Mono when it is installed, otherwise the system monospaced font.
    static func mono(_ size: CGFloat) -> NSFont {
        NSFont(name: "IBM Plex Mono", size: size) ?? .monospacedSystemFont(ofSize: size, weight: .regular)
    }

    private static func hex(_ v: Int) -> NSColor {
        NSColor(srgbRed: CGFloat(v >> 16 & 0xff) / 255, green: CGFloat(v >> 8 & 0xff) / 255,
                blue: CGFloat(v & 0xff) / 255, alpha: 1)
    }
}
