import SwiftUI
import CoreImage

// MARK: - Blend modes (iOS addition, CapCut-style "Blend")
//
// A clip's blend mode decides how it mixes with everything drawn BELOW it (lower tracks, in the compositor's
// layer order) instead of just covering it. `normal` is the plain "over" the app always had.
//
// Rules:
//  * The clip's opacity still applies: it scales the clip's alpha before the blend.
//  * A clip with nothing drawn below it (the bottom picture clip at that moment) is drawn normally: blending
//    with the empty black canvas would only make Multiply / Overlay clips go black.
//  * In a transition the mode of the clip that is more on screen (outgoing before the middle, incoming after) is used.
//  * Effect clips have no blend mode; text, image and video clips do.
//
// Persistence: `blendMode` key on the clip JSON (the raw names below); absent = normal. Other platforms ignore the
// key until they implement it.

extension EditingView {
    
    enum ClipBlendMode: String, Codable, CaseIterable {
        case normal, multiply, screen, overlay, darken, lighten
        case colorDodge, colorBurn, softLight, hardLight
        case difference, exclusion, add
        case hue, saturation, color, luminosity
        
        var title: String {
            switch self {
            case .normal: return "Normal"
            case .multiply: return "Multiply"
            case .screen: return "Screen"
            case .overlay: return "Overlay"
            case .darken: return "Darken"
            case .lighten: return "Lighten"
            case .colorDodge: return "Color Dodge"
            case .colorBurn: return "Color Burn"
            case .softLight: return "Soft Light"
            case .hardLight: return "Hard Light"
            case .difference: return "Difference"
            case .exclusion: return "Exclusion"
            case .add: return "Add"
            case .hue: return "Hue"
            case .saturation: return "Saturation"
            case .color: return "Color"
            case .luminosity: return "Luminosity"
            }
        }
        
        /// Core Image filter that mixes the clip (input) with the picture below it (background); nil = plain over.
        var filterName: String? {
            switch self {
            case .normal: return nil
            case .multiply: return "CIMultiplyBlendMode"
            case .screen: return "CIScreenBlendMode"
            case .overlay: return "CIOverlayBlendMode"
            case .darken: return "CIDarkenBlendMode"
            case .lighten: return "CILightenBlendMode"
            case .colorDodge: return "CIColorDodgeBlendMode"
            case .colorBurn: return "CIColorBurnBlendMode"
            case .softLight: return "CISoftLightBlendMode"
            case .hardLight: return "CIHardLightBlendMode"
            case .difference: return "CIDifferenceBlendMode"
            case .exclusion: return "CIExclusionBlendMode"
            case .add: return "CIAdditionCompositing"
            case .hue: return "CIHueBlendMode"
            case .saturation: return "CISaturationBlendMode"
            case .color: return "CIColorBlendMode"
            case .luminosity: return "CILuminosityBlendMode"
            }
        }
        
        /// The same mode for the tile previews drawn with SwiftUI.
        var swiftUI: SwiftUI.BlendMode {
            switch self {
            case .normal: return .normal
            case .multiply: return .multiply
            case .screen: return .screen
            case .overlay: return .overlay
            case .darken: return .darken
            case .lighten: return .lighten
            case .colorDodge: return .colorDodge
            case .colorBurn: return .colorBurn
            case .softLight: return .softLight
            case .hardLight: return .hardLight
            case .difference: return .difference
            case .exclusion: return .exclusion
            case .add: return .plusLighter
            case .hue: return .hue
            case .saturation: return .saturation
            case .color: return .color
            case .luminosity: return .luminosity
            }
        }
    }
    
    // MARK: Panel (toolbar "Blend")
    
    /// A tile: a warm-to-cool backdrop with a circle mixed in with the mode, so each mode shows what it does.
    struct BlendTile: View {
        let mode: ClipBlendMode
        let selected: Bool
        
        var body: some View {
            VStack(spacing: 4) {
                ZStack {
                    LinearGradient(colors: [Color(red: 0.95, green: 0.55, blue: 0.25), Color(red: 0.2, green: 0.45, blue: 0.9)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                    HStack(spacing: 0) {
                        Color.white.opacity(0.55).frame(width: 18)
                        Color.black.opacity(0.35).frame(width: 18)
                        Spacer(minLength: 0)
                    }
                    Circle()
                        .fill(LinearGradient(colors: [Color(red: 0.95, green: 0.85, blue: 0.25), Color(red: 0.85, green: 0.25, blue: 0.55)],
                                             startPoint: .top, endPoint: .bottom))
                        .frame(width: 34, height: 34)
                        .blendMode(mode.swiftUI)
                }
                .compositingGroup()
                .frame(height: 56)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10)
                    .stroke(selected ? Color.mdPrimary : Color.white.opacity(0.15), lineWidth: selected ? 2.5 : 1))
                
                Text(L(mode.title))
                    .font(.system(size: 10, weight: selected ? .semibold : .regular))
                    .foregroundColor(selected ? .white : .white.opacity(0.7))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
        }
    }
    
    struct BlendPanel: View {
        @ObservedObject var clip: Clip
        let commandManager: CommandManager
        let onChanged: () -> Void
        
        private let columns = Array(repeating: GridItem(.flexible(), spacing: 10), count: 4)
        
        var body: some View {
            VStack(spacing: 12) {
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(ClipBlendMode.allCases, id: \.self) { mode in
                        Button { set(mode) } label: {
                            BlendTile(mode: mode, selected: clip.blendMode == mode)
                        }
                        .buttonStyle(.plain)
                    }
                }
                Text("A blend mode mixes the clip with whatever is drawn below it, on lower tracks. A clip with nothing below it is shown normally. Opacity still applies.")
                    .font(.system(size: 11)).foregroundColor(.white.opacity(0.5))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        
        private func set(_ mode: ClipBlendMode) {
            let old = clip.blendMode
            guard old != mode else { return }
            let target = clip
            commandManager.execute(GenericCommand(
                description: "Blend: \(mode.title)",
                undo: { target.blendMode = old; onChanged() },
                redo: { target.blendMode = mode; onChanged() }
            ))
        }
    }
}

// MARK: - Compositing

extension EditingView.ClipCompositor {
    
    /// `top` over `bottom` with the clip's blend mode. `hasBackdrop` is false while nothing has been drawn yet:
    /// then there is nothing to mix with and the picture goes on as it is.
    static func compose(_ top: CIImage, over bottom: CIImage, mode: EditingView.ClipBlendMode,
                        canvas: CGRect, hasBackdrop: Bool) -> CIImage {
        guard hasBackdrop, let name = mode.filterName,
              let filter = CIFilter(name: name) else { return top.composited(over: bottom) }
        filter.setValue(top, forKey: kCIInputImageKey)
        filter.setValue(bottom, forKey: kCIInputBackgroundImageKey)
        return (filter.outputImage ?? top.composited(over: bottom)).cropped(to: canvas)
    }
}
