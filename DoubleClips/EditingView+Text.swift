import SwiftUI
import UIKit
import CoreImage

// MARK: - Text style (what a text clip looks like)
//
// Android and desktop only know `textContent` + `fontSize`: the FFmpeg export draws it with
// drawtext (one system font, FFmpeg's default colour, centred on the canvas, no scale / rotation /
// opacity). Everything else here is new, stored in ONE optional JSON object on the clip,
// `"textStyle"`, so an older Android / desktop build simply ignores it and nothing existing breaks.
//
// Colours are CSS-style "#RRGGBB" or "#RRGGBBAA" strings.

extension EditingView {
    
    struct TextStyle: Codable, Hashable {
        /// PostScript name of the font ("" = the system font).
        var fontName: String = ""
        var bold: Bool = false
        var italic: Bool = false
        var colorHex: String = Constants.TEXT_DEFAULT_COLOR_HEX
        /// "left", "center" or "right" (matters for several lines, or a wrap width).
        var alignment: String = "center"
        /// Extra space after each letter / between lines, in points (can be negative).
        var letterSpacing: Float = 0
        var lineSpacing: Float = 0
        /// Outline drawn OUTSIDE the letters, in points (0 = none).
        var outlineWidth: Float = 0
        var outlineColorHex: String = "#000000"
        /// Drop shadow: shown when blur > 0 or the offset isn't zero.
        var shadowBlur: Float = 0
        var shadowOffsetX: Float = 0
        var shadowOffsetY: Float = 0
        var shadowColorHex: String = "#00000099"
        /// A box behind the text (shown when its alpha is above 0).
        var backgroundColorHex: String = "#00000000"
        var backgroundPadding: Float = 0
        var backgroundRadius: Float = 0
        /// Wrap long lines at this fraction of the canvas width (0 = never wrap).
        var wrapWidth: Float = 0
        
        // Per-unit animation (EditingView+TextUnits.swift): the clip's In / Out animation runs on each
        // character / word / line instead of on the whole text, each one starting a little after the last.
        /// "none" (whole text), "character", "word" or "line".
        var unitMode: String = "none"
        /// Share of the animation window spent staggering the units' starts, 0...0.95 (0 = all together).
        var stagger: Float = 0.6
        /// Which unit goes first: "forward", "reverse", "centerOut" or "random" (stable for a given text).
        var order: String = "forward"
        
        var animatesPerUnit: Bool { unitMode == "character" || unitMode == "word" || unitMode == "line" }
        
        init() {}
        
        /// Handy for previews of a single font (`TextStyle(fontName: "Georgia")`).
        init(fontName: String) { self.fontName = fontName }
        
        enum CodingKeys: String, CodingKey {
            case fontName, bold, italic, colorHex, alignment, letterSpacing, lineSpacing
            case outlineWidth, outlineColorHex, shadowBlur, shadowOffsetX, shadowOffsetY, shadowColorHex
            case backgroundColorHex, backgroundPadding, backgroundRadius, wrapWidth
            case unitMode, stagger, order
        }
        
        /// Every field is optional on read, so a style written by another platform (or a later
        /// version with more fields) never makes the whole clip unreadable.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let d = TextStyle()
            fontName = try c.decodeIfPresent(String.self, forKey: .fontName) ?? d.fontName
            bold = try c.decodeIfPresent(Bool.self, forKey: .bold) ?? d.bold
            italic = try c.decodeIfPresent(Bool.self, forKey: .italic) ?? d.italic
            colorHex = try c.decodeIfPresent(String.self, forKey: .colorHex) ?? d.colorHex
            alignment = try c.decodeIfPresent(String.self, forKey: .alignment) ?? d.alignment
            letterSpacing = try c.decodeIfPresent(Float.self, forKey: .letterSpacing) ?? d.letterSpacing
            lineSpacing = try c.decodeIfPresent(Float.self, forKey: .lineSpacing) ?? d.lineSpacing
            outlineWidth = try c.decodeIfPresent(Float.self, forKey: .outlineWidth) ?? d.outlineWidth
            outlineColorHex = try c.decodeIfPresent(String.self, forKey: .outlineColorHex) ?? d.outlineColorHex
            shadowBlur = try c.decodeIfPresent(Float.self, forKey: .shadowBlur) ?? d.shadowBlur
            shadowOffsetX = try c.decodeIfPresent(Float.self, forKey: .shadowOffsetX) ?? d.shadowOffsetX
            shadowOffsetY = try c.decodeIfPresent(Float.self, forKey: .shadowOffsetY) ?? d.shadowOffsetY
            shadowColorHex = try c.decodeIfPresent(String.self, forKey: .shadowColorHex) ?? d.shadowColorHex
            backgroundColorHex = try c.decodeIfPresent(String.self, forKey: .backgroundColorHex) ?? d.backgroundColorHex
            backgroundPadding = try c.decodeIfPresent(Float.self, forKey: .backgroundPadding) ?? d.backgroundPadding
            backgroundRadius = try c.decodeIfPresent(Float.self, forKey: .backgroundRadius) ?? d.backgroundRadius
            wrapWidth = try c.decodeIfPresent(Float.self, forKey: .wrapWidth) ?? d.wrapWidth
            unitMode = try c.decodeIfPresent(String.self, forKey: .unitMode) ?? d.unitMode
            stagger = try c.decodeIfPresent(Float.self, forKey: .stagger) ?? d.stagger
            order = try c.decodeIfPresent(String.self, forKey: .order) ?? d.order
        }
    }
    
    /// Everything the renderer needs to draw one text clip: a plain value, safe to hand to the render thread.
    struct TextSpec: Hashable {
        var text: String
        var fontSize: CGFloat
        var style: TextStyle
        /// Project canvas width, which `wrapWidth` is a fraction of.
        var canvasWidth: CGFloat
    }
}

// MARK: - Colours

enum HexColor {
    static func ui(_ hex: String, fallback: UIColor = .white) -> UIColor {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6 || s.count == 8, let value = UInt64(s, radix: 16) else { return fallback }
        let r, g, b, a: CGFloat
        if s.count == 8 {
            r = CGFloat((value >> 24) & 0xFF) / 255; g = CGFloat((value >> 16) & 0xFF) / 255
            b = CGFloat((value >> 8) & 0xFF) / 255;  a = CGFloat(value & 0xFF) / 255
        } else {
            r = CGFloat((value >> 16) & 0xFF) / 255; g = CGFloat((value >> 8) & 0xFF) / 255
            b = CGFloat(value & 0xFF) / 255;         a = 1
        }
        return UIColor(red: r, green: g, blue: b, alpha: a)
    }
    
    /// "#RRGGBB", or "#RRGGBBAA" when not fully opaque.
    static func string(_ color: UIColor) -> String {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.getRed(&r, green: &g, blue: &b, alpha: &a)
        func byte(_ v: CGFloat) -> Int { Int((min(max(v, 0), 1) * 255).rounded()) }
        let rgb = String(format: "#%02X%02X%02X", byte(r), byte(g), byte(b))
        return a >= 0.999 ? rgb : rgb + String(format: "%02X", byte(a))
    }
    
    static func alpha(_ hex: String) -> CGFloat {
        var a: CGFloat = 1
        ui(hex).getRed(nil, green: nil, blue: nil, alpha: &a)
        return a
    }
}

// MARK: - Fonts

enum TextFonts {
    struct Entry: Identifiable {
        let name: String        // PostScript name, "" = system
        let title: String
        var id: String { name }
    }
    
    /// A short list of fonts every iPhone has. Missing ones are dropped at runtime.
    static let curated: [Entry] = {
        let all: [Entry] = [
            Entry(name: "", title: "System"),
            Entry(name: "HelveticaNeue", title: "Helvetica Neue"),
            Entry(name: "ArialMT", title: "Arial"),
            Entry(name: "ArialRoundedMTBold", title: "Arial Rounded"),
            Entry(name: "AvenirNext-Regular", title: "Avenir Next"),
            Entry(name: "AvenirNextCondensed-Medium", title: "Avenir Condensed"),
            Entry(name: "Futura-Medium", title: "Futura"),
            Entry(name: "GillSans", title: "Gill Sans"),
            Entry(name: "Optima-Regular", title: "Optima"),
            Entry(name: "Verdana", title: "Verdana"),
            Entry(name: "TrebuchetMS", title: "Trebuchet"),
            Entry(name: "Georgia", title: "Georgia"),
            Entry(name: "TimesNewRomanPSMT", title: "Times New Roman"),
            Entry(name: "Baskerville", title: "Baskerville"),
            Entry(name: "Palatino-Roman", title: "Palatino"),
            Entry(name: "Didot", title: "Didot"),
            Entry(name: "Cochin", title: "Cochin"),
            Entry(name: "Rockwell-Regular", title: "Rockwell"),
            Entry(name: "AmericanTypewriter", title: "American Typewriter"),
            Entry(name: "CourierNewPSMT", title: "Courier New"),
            Entry(name: "Menlo-Regular", title: "Menlo"),
            Entry(name: "Copperplate", title: "Copperplate"),
            Entry(name: "MarkerFelt-Thin", title: "Marker Felt"),
            Entry(name: "Noteworthy-Light", title: "Noteworthy"),
            Entry(name: "Chalkduster", title: "Chalkduster"),
            Entry(name: "BradleyHandITCTT-Bold", title: "Bradley Hand"),
            Entry(name: "SnellRoundhand", title: "Snell Roundhand"),
            Entry(name: "Papyrus", title: "Papyrus"),
            Entry(name: "Zapfino", title: "Zapfino")
        ]
        return all.filter { $0.name.isEmpty || UIFont(name: $0.name, size: 12) != nil }
    }()
    
    /// Every installed family (its first face), for the "More fonts" list.
    static func allFamilies() -> [Entry] {
        UIFont.familyNames.sorted().compactMap { family in
            guard let first = UIFont.fontNames(forFamilyName: family).first else { return nil }
            return Entry(name: first, title: family)
        }
    }
    
    static func title(for name: String) -> String {
        if name.isEmpty { return "System" }
        if let hit = curated.first(where: { $0.name == name }) { return hit.title }
        return UIFont(name: name, size: 12)?.familyName ?? name
    }
    
    static func font(_ style: EditingView.TextStyle, size: CGFloat) -> UIFont {
        let size = max(size, 1)
        var base: UIFont = style.fontName.isEmpty ? .systemFont(ofSize: size)
            : (UIFont(name: style.fontName, size: size) ?? .systemFont(ofSize: size))
        var traits = base.fontDescriptor.symbolicTraits
        if style.bold { traits.insert(.traitBold) }
        if style.italic { traits.insert(.traitItalic) }
        if traits != base.fontDescriptor.symbolicTraits,
           let descriptor = base.fontDescriptor.withSymbolicTraits(traits) {
            base = UIFont(descriptor: descriptor, size: size)
        }
        return base
    }
}

// MARK: - Renderer

/// Draws a text clip into a transparent bitmap, centred in its own padding (so the bitmap's
/// centre is the text's centre). The compositor then places it like any other layer.
enum TextRenderer {
    
    struct Rendered {
        let image: CIImage
        /// Bitmap size in canvas pixels (text + padding for outline / shadow / box).
        let size: CGSize
    }
    
    private final class Box { let value: Rendered?; init(_ v: Rendered?) { value = v } }
    private static let cache: NSCache<NSString, Box> = {
        let c = NSCache<NSString, Box>()
        c.countLimit = 64
        return c
    }()
    
    static func render(_ spec: EditingView.TextSpec) -> Rendered? {
        let key = String(describing: spec) as NSString
        if let hit = cache.object(forKey: key) { return hit.value }
        let made = draw(spec)
        cache.setObject(Box(made), forKey: key)
        return made
    }
    
    /// What the gizmo / hit test uses: the bitmap size, or a small box for empty text.
    static func size(_ spec: EditingView.TextSpec) -> CGSize {
        if let rendered = render(spec) { return rendered.size }
        let h = max(spec.fontSize, 8) * 1.4
        return CGSize(width: h * 2, height: h)
    }
    
    /// Everything about a text block's layout that doesn't depend on which pass draws it. The per-unit
    /// renderer (EditingView+TextUnits.swift) reads the same numbers, so a unit lands exactly where the
    /// whole block would put it.
    struct Metrics {
        let spec: EditingView.TextSpec
        let font: UIFont
        let paragraph: NSParagraphStyle
        let options: NSStringDrawingOptions
        /// The text itself, without padding.
        let textW: CGFloat
        let textH: CGFloat
        let outline: CGFloat
        let shadowOn: Bool
        let shadowReach: CGFloat
        let boxOn: Bool
        let boxPad: CGFloat
        /// Padding around the text for outline / shadow / box.
        let pad: CGFloat
        /// Bitmap size (text + padding) and where the text sits in it.
        let size: CGSize
        let textRect: CGRect
        
        func attributes(_ extra: [NSAttributedString.Key: Any]) -> [NSAttributedString.Key: Any] {
            var a: [NSAttributedString.Key: Any] = [.font: font, .paragraphStyle: paragraph]
            if spec.style.letterSpacing != 0 { a[.kern] = CGFloat(spec.style.letterSpacing) }
            for (k, v) in extra { a[k] = v }
            return a
        }
        
        func shadow() -> NSShadow {
            let style = spec.style
            let s = NSShadow()
            s.shadowBlurRadius = CGFloat(max(0, style.shadowBlur))
            s.shadowOffset = CGSize(width: CGFloat(style.shadowOffsetX), height: CGFloat(style.shadowOffsetY))
            s.shadowColor = HexColor.ui(style.shadowColorHex, fallback: UIColor.black.withAlphaComponent(0.6))
            return s
        }
        
        /// Outline pass: a stroke-only pass (positive stroke width = stroke without fill), centred on the
        /// glyph edge, so it is twice as wide as asked and the fill pass covers the inner half.
        var outlineExtra: [NSAttributedString.Key: Any] {
            let style = spec.style
            var extra: [NSAttributedString.Key: Any] = [
                .strokeColor: HexColor.ui(style.outlineColorHex, fallback: .black),
                .strokeWidth: (outline * 2 / max(spec.fontSize, 1)) * 100,
                .foregroundColor: HexColor.ui(style.outlineColorHex, fallback: .black)
            ]
            if shadowOn { extra[.shadow] = shadow() }
            return extra
        }
        
        /// Fill pass; it carries the shadow when there is no outline pass.
        var fillExtra: [NSAttributedString.Key: Any] {
            var fill: [NSAttributedString.Key: Any] = [.foregroundColor: HexColor.ui(spec.style.colorHex, fallback: .white)]
            if shadowOn && outline == 0 { fill[.shadow] = shadow() }
            return fill
        }
        
        /// The background box, into the current graphics context.
        func drawBox() {
            let style = spec.style
            let box = textRect.insetBy(dx: -boxPad, dy: -boxPad)
            let radius = min(CGFloat(max(0, style.backgroundRadius)), min(box.width, box.height) / 2)
            HexColor.ui(style.backgroundColorHex, fallback: .clear).setFill()
            UIBezierPath(roundedRect: box, cornerRadius: radius).fill()
        }
    }
    
    static func metrics(_ spec: EditingView.TextSpec) -> Metrics? {
        guard !spec.text.isEmpty else { return nil }
        let style = spec.style
        let font = TextFonts.font(style, size: spec.fontSize)
        
        let paragraph = NSMutableParagraphStyle()
        switch style.alignment {
        case "left": paragraph.alignment = .left
        case "right": paragraph.alignment = .right
        default: paragraph.alignment = .center
        }
        paragraph.lineSpacing = CGFloat(style.lineSpacing)
        paragraph.lineBreakMode = .byWordWrapping
        
        var base: [NSAttributedString.Key: Any] = [.font: font, .paragraphStyle: paragraph]
        if style.letterSpacing != 0 { base[.kern] = CGFloat(style.letterSpacing) }
        
        let maxWidth: CGFloat = style.wrapWidth > 0.01
            ? max(20, CGFloat(style.wrapWidth) * spec.canvasWidth) : .greatestFiniteMagnitude
        let options: NSStringDrawingOptions = [.usesLineFragmentOrigin, .usesFontLeading]
        let measured = (spec.text as NSString).boundingRect(
            with: CGSize(width: maxWidth, height: .greatestFiniteMagnitude),
            options: options, attributes: base, context: nil)
        let textW = ceil(measured.width), textH = ceil(measured.height)
        guard textW > 0, textH > 0 else { return nil }
        
        let outline = CGFloat(max(0, style.outlineWidth))
        let shadowOn = style.shadowBlur > 0 || style.shadowOffsetX != 0 || style.shadowOffsetY != 0
        let shadowReach = shadowOn
            ? CGFloat(style.shadowBlur) + max(abs(CGFloat(style.shadowOffsetX)), abs(CGFloat(style.shadowOffsetY))) : 0
        let boxOn = HexColor.alpha(style.backgroundColorHex) > 0.001
        let boxPad = boxOn ? CGFloat(max(0, style.backgroundPadding)) : 0
        let pad = ceil(2 + outline + shadowReach + boxPad)
        
        return Metrics(spec: spec, font: font, paragraph: paragraph, options: options,
                       textW: textW, textH: textH, outline: outline, shadowOn: shadowOn,
                       shadowReach: shadowReach, boxOn: boxOn, boxPad: boxPad, pad: pad,
                       size: CGSize(width: textW + pad * 2, height: textH + pad * 2),
                       textRect: CGRect(x: pad, y: pad, width: textW, height: textH))
    }
    
    private static func draw(_ spec: EditingView.TextSpec ) -> Rendered? {
        guard let m = metrics(spec) else { return nil }
        
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let rendered = UIGraphicsImageRenderer(size: m.size, format: format).image { _ in
            if m.boxOn { m.drawBox() }
            if m.outline > 0 {
                (spec.text as NSString).draw(with: m.textRect, options: m.options,
                                             attributes: m.attributes(m.outlineExtra), context: nil)
            }
            (spec.text as NSString).draw(with: m.textRect, options: m.options,
                                         attributes: m.attributes(m.fillExtra), context: nil)
        }
        guard let cg = rendered.cgImage else { return nil }
        return Rendered(image: CIImage(cgImage: cg), size: m.size)
    }
}
