import SwiftUI

extension Color {
    // Primary Brand Colors
    static let mdPrimary = Color(hex: "4A5FFF")
    static let mdOnPrimary = Color(hex: "FFFFFF")
    static let mdPrimaryContainer = Color(hex: "DDE1FF")
    static let mdOnPrimaryContainer = Color(hex: "000C66")
    
    // Secondary
    static let mdSecondary = Color(hex: "00BCD4")
    static let mdSecondaryContainer = Color(hex: "B3E5FC")
    
    // Tertiary
    static let mdTertiaryContainer = Color(hex: "FFDDD0")
    static let mdOnTertiaryContainer = Color(hex: "5C1A00")
    
    // Error
    static let mdErrorContainer = Color(hex: "FFDAD6")
    static let mdOnErrorContainer = Color(hex: "410002")
    
    // Background & Surface (Adaptive)
    static let mdBackground = Color(uiColor: .systemBackground)
    static let mdOnBackground = Color(uiColor: .label)
    static let mdSurface = Color(uiColor: .secondarySystemBackground)
    static let mdOnSurface = Color(uiColor: .label)
    
    // Surface Containers (Adaptive)
    static let mdSurfaceContainerLow = Color(uiColor: .systemFill)
    static let mdSurfaceContainer = Color(uiColor: .secondarySystemFill)
    static let mdSurfaceContainerHigh = Color(uiColor: .tertiarySystemFill)
    
    // Outline
    static let mdOutline = Color(uiColor: .separator)
    static let mdOutlineVariant = Color(uiColor: .opaqueSeparator)
    
    // Text Colors
    static let mdOnSurfaceVariant = Color(uiColor: .secondaryLabel)
    
    // Custom Colors
    static let iosBlue = Color(hex: "007AFF") // Standard iOS Blue
}

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3: // RGB (12-bit)
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6: // RGB (24-bit)
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8: // ARGB (32-bit)
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (1, 1, 1, 0)
        }

        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue:  Double(b) / 255,
            opacity: Double(a) / 255
        )
    }
}
