import Foundation

// MARK: - Clip speed: timeline time <-> source time
//
// A clip's `duration` is its length ON THE TIMELINE. The source media between the trims (`originalDuration - startClipTrim -
// endClipTrim`) is played at the clip's speed, which is `valueSpeed` or, when speed has keyframes, a curve over the clip's local
// time (a "velocity" edit: ramps, bullet-time, ...). So
//
//     source offset consumed after `t` timeline seconds  =  integral of speed(u) du, u = 0...t
//     the clip's timeline length                          =  the t at which that integral has used up the source between the trims
//
// `ClipTimeMap` is that integral and its inverse. The composition builder cuts the footage into short pieces of constant speed
// from it, the trim handles / trim fields / split use it to turn timeline seconds into source seconds, and `Clip.refitDuration`
// re-derives the length after a speed or trim edit. Speed 1 everywhere is the identity, so clips without speed edits behave as
// before. A clip that was never refitted (an Android project with a speed set) keeps its stored window and simply runs out of
// source early (fast) or shows only the first part of the source (slow): what the old composition did too.

extension EditingView {
    
    final class ClipTimeMap {
        /// Speed is kept inside this range (the Speed slider goes 0.1...4).
        static let minSpeed = 0.1, maxSpeed = 8.0
        /// Sampling step of the integral for a curve.
        private static let step = 1.0 / 120.0
        
        /// Non-nil = the same speed everywhere (the fast path, exact).
        let constantSpeed: Double?
        private let speedFunction: (Double) -> Double
        /// cumulative[i] = source offset after i * step timeline seconds (curves only; grows on demand).
        private var cumulative: [Double] = [0]
        private let lock = NSLock()      // the table grows on demand and is read from drawing code too
        
        init(constant speed: Double) {
            let s = min(max(speed, Self.minSpeed), Self.maxSpeed)
            constantSpeed = s
            speedFunction = { _ in s }
        }
        
        /// `speedAt`: speed at a clip-local time in seconds.
        init(speedAt: @escaping (Double) -> Double) {
            constantSpeed = nil
            speedFunction = { min(max(speedAt($0), Self.minSpeed), Self.maxSpeed) }
        }
        
        var isIdentity: Bool {
            guard let c = constantSpeed else { return false }
            return abs(c - 1) < 0.001
        }
        
        func speed(atLocal t: Double) -> Double { speedFunction(max(t, 0)) }
        
        private func extend(toIndex index: Int) {
            while cumulative.count <= index {
                let i = cumulative.count - 1
                let a = speedFunction(Double(i) * Self.step), b = speedFunction(Double(i + 1) * Self.step)
                cumulative.append(cumulative[i] + 0.5 * (a + b) * Self.step)
            }
        }
        
        /// Source seconds consumed after `t` timeline seconds (before the trim offset is added).
        func sourceOffset(atLocal t: Double) -> Double {
            let t = max(t, 0)
            if let c = constantSpeed { return t * c }
            lock.lock(); defer { lock.unlock() }
            let position = t / Self.step
            let index = Int(position.rounded(.down))
            extend(toIndex: index + 1)
            let fraction = position - Double(index)
            return cumulative[index] + (cumulative[index + 1] - cumulative[index]) * fraction
        }
        
        /// Timeline seconds after which `offset` source seconds have been consumed (the inverse of `sourceOffset`).
        func localTime(forSourceOffset offset: Double) -> Double {
            if offset <= 0 { return 0 }
            if let c = constantSpeed { return offset / c }
            lock.lock(); defer { lock.unlock() }
            var guardCount = 0
            while cumulative[cumulative.count - 1] < offset && guardCount < 4_000_000 {
                extend(toIndex: cumulative.count)
                guardCount += 1
            }
            var lo = 0, hi = cumulative.count - 1
            while lo + 1 < hi {
                let mid = (lo + hi) / 2
                if cumulative[mid] < offset { lo = mid } else { hi = mid }
            }
            let span = cumulative[hi] - cumulative[lo]
            let fraction = span > 0 ? min(max((offset - cumulative[lo]) / span, 0), 1) : 0
            return (Double(lo) + fraction) * Self.step
        }
        
        /// The first `duration` timeline seconds cut into pieces of (nearly) constant speed:
        /// timeline [a, b] plays source offsets [s0, s1]. One piece for a constant speed.
        struct Piece { let a: Double, b: Double, s0: Double, s1: Double }
        
        func pieces(duration: Double, maxPieceSeconds: Double = 0.1) -> [Piece] {
            guard duration > 0 else { return [] }
            if let c = constantSpeed { return [Piece(a: 0, b: duration, s0: 0, s1: duration * c)] }
            let count = max(1, Int((duration / maxPieceSeconds).rounded(.up)))
            var out: [Piece] = []
            out.reserveCapacity(count)
            var previous = 0.0
            for i in 1...count {
                let b = i == count ? duration : duration * Double(i) / Double(count)
                out.append(Piece(a: previous, b: b, s0: sourceOffset(atLocal: previous), s1: sourceOffset(atLocal: b)))
                previous = b
            }
            return out
        }
    }
}

extension EditingView.Clip {
    
    var hasSource: Bool { type == .video || type == .audio }
    
    /// The clip's speed over its local time (a curve when speed has keyframes). Built from the clip as it is now.
    var timeMap: EditingView.ClipTimeMap {
        let keys = keyframes, properties = videoProperties, start = startTime
        guard keys.isAnimated(.speed) else {
            return EditingView.ClipTimeMap(constant: Double(properties.valueSpeed))
        }
        return EditingView.ClipTimeMap(speedAt: { t in
            Double(keys.value(for: .speed, base: properties, clipStartTime: start, at: start + Float(t)))
        })
    }
    
    /// Timeline -> source time for DRAWING (timeline thumbnails and waveform): nil at speed 1, a cached map otherwise (a speed curve is
    /// rebuilt only when the clip's speed or its speed keyframes change, not on every redraw).
    var visualTimeMap: EditingView.ClipTimeMap? {
        guard keyframes.isAnimated(.speed) else {
            let v = videoProperties.valueSpeed
            return abs(v - 1) < 0.001 ? nil : EditingView.ClipTimeMap(constant: Double(v))
        }
        let signature = "\(startTime)|\(videoProperties.valueSpeed)|" + keyframes.keyframes
            .filter { $0.animates(.speed) }
            .map { "\($0.time),\($0.value.valueSpeed),\($0.easing)" }
            .joined(separator: ";")
        let key = id.uuidString as NSString
        if let entry = SpeedMapCache.store.object(forKey: key), entry.signature == signature { return entry.map }
        let map = timeMap
        SpeedMapCache.store.setObject(SpeedMapCache.Entry(signature: signature, map: map), forKey: key)
        return map
    }
    
    /// Source seconds per timeline second, averaged over the clip (what the timeline thumbnails / waveform stretch by). Cheap.
    var averageSpeed: Float {
        guard keyframes.isAnimated(.speed), duration > 0 else { return max(videoProperties.valueSpeed, 0.01) }
        let samples = 48
        var sum: Float = 0
        for i in 0...samples {
            let t = duration * Float(i) / Float(samples)
            let v = keyframes.value(for: .speed, base: videoProperties, clipStartTime: startTime, at: startTime + t)
            sum += (i == 0 || i == samples ? 0.5 : 1) * v
        }
        return max(sum / Float(samples), 0.01)
    }
    
    /// The timeline length that plays the source between the trims at the clip's speed.
    func fittedDuration() -> Float {
        guard hasSource, originalDuration > 0 else { return duration }
        let sourceLength = max(0, originalDuration - startClipTrim - endClipTrim)
        return Float(timeMap.localTime(forSourceOffset: Double(sourceLength)))
    }
    
    /// Re-derive `duration` after a speed or trim edit. A clip without a known source length keeps its duration.
    func refitDuration() {
        guard hasSource, originalDuration > 0 else { return }
        duration = max(fittedDuration(), 0.01)
    }
    
    /// What `duration` becomes when a trim changes (the old derivation at speed 1, the fitted length otherwise).
    func durationForTrims() -> Float {
        guard hasSource, originalDuration > 0 else { return originalDuration - endClipTrim - startClipTrim }
        return max(fittedDuration(), 0)
    }
}

private enum SpeedMapCache {
    final class Entry {
        let signature: String
        let map: EditingView.ClipTimeMap
        init(signature: String, map: EditingView.ClipTimeMap) { self.signature = signature; self.map = map }
    }
    static let store: NSCache<NSString, Entry> = {
        let cache = NSCache<NSString, Entry>()
        cache.countLimit = 64
        return cache
    }()
}
