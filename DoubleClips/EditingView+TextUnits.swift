import SwiftUI
import UIKit
import CoreImage

// MARK: - Per-character / word / line text
//
// A text clip whose style has `unitMode` "character", "word" or "line" animates its In / Out
// animation per unit instead of as one block: every unit is its own small bitmap, placed from the
// block's layout, and the compositor (ClipCompositor.renderTextUnits) gives each one the clip's
// animation with its own start delay.
//
//   - Units: characters are grapheme clusters (letter + accents stay together), words are runs of
//     non-whitespace, lines are the layout's lines (wrapping included). Whitespace is never a unit.
//   - Each unit is drawn with TextKit from the SAME layout as the whole block (same font, kerning,
//     wrapping and alignment), only that unit's glyphs, with the same outline / shadow passes, so at
//     rest the units sit exactly where the whole block draws them.
//   - The background box is not per unit: it is one still layer under the units.
//   - Order "random" is a fixed shuffle seeded from the text, so a clip always shuffles the same way.
//   - More than `Constants.TEXT_UNIT_MAX_COUNT` units: not split (the whole text animates as one).

enum TextUnitRenderer {
    
    struct Unit {
        /// The unit's own padded bitmap, in the block bitmap's coordinates (top-left origin, y down).
        let rect: CGRect
        let image: CIImage
    }
    
    struct Result {
        /// The size of the whole text bitmap (what the plain renderer would produce).
        let blockSize: CGSize
        let units: [Unit]
        /// The background box alone, block-sized (nil when the style has none).
        let box: CIImage?
    }
    
    private final class Box { let value: Result?; init(_ v: Result?) { value = v } }
    private static let cache: NSCache<NSString, Box> = {
        let c = NSCache<NSString, Box>()
        c.countLimit = 24
        return c
    }()
    
    static func render(_ spec: EditingView.TextSpec) -> Result? {
        guard spec.style.animatesPerUnit else { return nil }
        let key = String(describing: spec) as NSString
        if let hit = cache.object(forKey: key) { return hit.value }
        let made = draw(spec)
        cache.setObject(Box(made), forKey: key)
        return made
    }
    
    // MARK: Drawing
    
    /// One TextKit stack over the block's text with a pass's attributes.
    private struct Stack {
        let storage: NSTextStorage
        let layout: NSLayoutManager
        let container: NSTextContainer
        
        init(_ m: TextRenderer.Metrics, extra: [NSAttributedString.Key: Any]) {
            storage = NSTextStorage(string: m.spec.text, attributes: m.attributes(extra))
            layout = NSLayoutManager()
            // Same width the block was drawn into, no inset: line breaks and alignment match.
            container = NSTextContainer(size: CGSize(width: m.textW, height: .greatestFiniteMagnitude))
            container.lineFragmentPadding = 0
            layout.addTextContainer(container)
            storage.addLayoutManager(layout)
            layout.ensureLayout(for: container)
        }
    }
    
    private static func draw(_ spec: EditingView.TextSpec) -> Result? {
        guard let m = TextRenderer.metrics(spec) else { return nil }
        let text = spec.text as NSString
        
        let fill = Stack(m, extra: m.fillExtra)
        let ranges = unitRanges(text: text, mode: spec.style.unitMode, layout: fill.layout, container: fill.container)
        guard !ranges.isEmpty, ranges.count <= Constants.TEXT_UNIT_MAX_COUNT else { return nil }
        let outline: Stack? = m.outline > 0 ? Stack(m, extra: m.outlineExtra) : nil
        
        // Room around a unit's glyphs: outline + shadow + a little for slanted letters.
        let padY = ceil(2 + m.outline + m.shadowReach)
        let padX = padY + ceil(spec.fontSize * Constants.TEXT_UNIT_OVERHANG_FACTOR)
        
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        
        var units: [Unit] = []
        for range in ranges {
            let glyphs = fill.layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            let bounds = fill.layout.boundingRect(forGlyphRange: glyphs, in: fill.container)
            guard bounds.width > 0, bounds.height > 0 else { continue }
            // In the text container's coordinates, then outward to whole pixels.
            let local = CGRect(x: bounds.minX - padX, y: bounds.minY - padY,
                               width: bounds.width + padX * 2, height: bounds.height + padY * 2).integral
            let image = UIGraphicsImageRenderer(size: local.size, format: format).image { _ in
                let origin = CGPoint(x: -local.minX, y: -local.minY)
                if let outline {
                    let g = outline.layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
                    outline.layout.drawGlyphs(forGlyphRange: g, at: origin)
                }
                fill.layout.drawGlyphs(forGlyphRange: glyphs, at: origin)
            }
            guard let cg = image.cgImage else { continue }
            units.append(Unit(rect: local.offsetBy(dx: m.textRect.minX, dy: m.textRect.minY),
                              image: CIImage(cgImage: cg)))
        }
        guard !units.isEmpty else { return nil }
        
        var boxImage: CIImage?
        if m.boxOn {
            let rendered = UIGraphicsImageRenderer(size: m.size, format: format).image { _ in m.drawBox() }
            if let cg = rendered.cgImage { boxImage = CIImage(cgImage: cg) }
        }
        return Result(blockSize: m.size, units: units, box: boxImage)
    }
    
    // MARK: Splitting
    
    /// Character ranges (UTF-16) of the units, in reading order. Whitespace is never a unit.
    private static func unitRanges(text: NSString, mode: String, layout: NSLayoutManager,
                                   container: NSTextContainer) -> [NSRange] {
        let whole = NSRange(location: 0, length: text.length)
        func isBlank(_ range: NSRange) -> Bool {
            text.substring(with: range).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        var ranges: [NSRange] = []
        switch mode {
        case "character":
            text.enumerateSubstrings(in: whole, options: .byComposedCharacterSequences) { _, range, _, _ in
                if !isBlank(range) { ranges.append(range) }
            }
        case "word":
            var cursor = 0
            while cursor < text.length {
                let rest = NSRange(location: cursor, length: text.length - cursor)
                let start = text.rangeOfCharacter(from: CharacterSet.whitespacesAndNewlines.inverted, options: [], range: rest)
                guard start.location != NSNotFound else { break }
                let after = NSRange(location: start.location, length: text.length - start.location)
                let gap = text.rangeOfCharacter(from: .whitespacesAndNewlines, options: [], range: after)
                let end = gap.location == NSNotFound ? text.length : gap.location
                ranges.append(NSRange(location: start.location, length: end - start.location))
                cursor = end
            }
        case "line":
            layout.enumerateLineFragments(forGlyphRange: NSRange(location: 0, length: layout.numberOfGlyphs)) {
                _, _, _, glyphRange, _ in
                let chars = layout.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
                if !isBlank(chars) { ranges.append(chars) }
            }
        default:
            break
        }
        return ranges
    }
    
    // MARK: Order
    
    /// rank[i] = when unit i starts (0 = first). Deterministic for a given text.
    static func ranks(count n: Int, order: String, seedText: String) -> [Int] {
        guard n > 1 else { return Array(0..<max(n, 0)) }
        switch order {
        case "reverse":
            return (0..<n).map { n - 1 - $0 }
        case "centerOut":
            let mid = Double(n - 1) / 2
            let sorted = (0..<n).sorted { a, b in
                let da = abs(Double(a) - mid), db = abs(Double(b) - mid)
                return da != db ? da < db : a < b
            }
            var rank = [Int](repeating: 0, count: n)
            for (r, index) in sorted.enumerated() { rank[index] = r }
            return rank
        case "random":
            // FNV-1a of the text -> SplitMix64 -> Fisher-Yates. (Swift's hashValue and shuffle() are not
            // stable between launches / versions, so the shuffle is spelled out.)
            var hash: UInt64 = 0xcbf29ce484222325
            for byte in seedText.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100000001b3 }
            var state = hash &* 31 &+ UInt64(n)
            func next() -> UInt64 {
                state = state &+ 0x9E3779B97F4A7C15
                var z = state
                z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
                z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
                return z ^ (z >> 31)
            }
            var shuffled = Array(0..<n)
            var i = n - 1
            while i > 0 {
                let j = Int(next() % UInt64(i + 1))
                shuffled.swapAt(i, j)
                i -= 1
            }
            var rank = [Int](repeating: 0, count: n)
            for (r, index) in shuffled.enumerated() { rank[index] = r }
            return rank
        default:
            return Array(0..<n)
        }
    }
}
