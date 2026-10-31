import Foundation
import AVFoundation
import CoreImage
import CoreVideo
import Metal

// MARK: - Motion: optical flow + motion blur (the desktop's "Motion" tab)
//
//  - Optical flow (CapCut's frame interpolation): the in-between frames of a slowed-down clip are made by finding how things move
//    between two source frames and pulling both along that motion, instead of repeating the nearer frame. `fps` is the rate those
//    frames are made at: the clip's time is snapped to a grid of `fps` frames a second, like ffmpeg's minterpolate=fps=N.
//  - Motion blur: moving things get a streak along the way they move, found from the same flow. Blur and Blend are keyframable
//    sliders (the `motionBlur` / `motionBlend` channels, 0...100), Direction and Speed (how many times the blur is applied) are plain.
//
// Same JSON as the desktop (`opticalFlow`, `motionBlur` on the clip; `valueMotionBlur`, `valueMotionBlend` in the properties), so a
// project moves between the two. The picture is made by the three Metal kernels of MotionFlow.metal (a port of the desktop's shaders).
//
// How the two frames reach the compositor: the composition builder puts the clip's footage on TWO tracks, the second one a frame
// later (see CompositionBuilder), so `request.sourceFrame` hands over frame N and frame N + 1 at the same time and AVFoundation does
// the decoding, seeking, speed ramps and export for us. Both tracks are also shifted a quarter frame ahead (`lookAhead`) so a
// timestamp that rounds a hair early can never deliver the frame before the one the maths expects.

extension EditingView {

    // MARK: Per-clip settings

    struct ClipOpticalFlow: Codable, Equatable {
        static let defaultFPS: Float = 60
        var enabled = true
        var fps: Float = ClipOpticalFlow.defaultFPS

        init() {}

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
            fps = try c.decodeIfPresent(Float.self, forKey: .fps) ?? Self.defaultFPS
        }

        /// The rate to interpolate at (never 0 or NaN, even for a project file with a bad value).
        var effectiveFPS: Float { fps.isNaN || fps.isInfinite || fps <= 0 ? Self.defaultFPS : fps }

        /// "60" / "29.97": the rate as the text box shows it.
        static func format(_ fps: Float) -> String {
            var s = String(format: "%.3f", Double(fps))
            if s.contains(".") {
                while s.hasSuffix("0") { s.removeLast() }
                if s.hasSuffix(".") { s.removeLast() }
            }
            return s
        }
    }

    struct ClipMotionBlur: Codable, Equatable {
        static let scaleMax: Float = 100
        static let defaultBlur: Float = 100
        static let defaultBlend: Float = 0

        enum Direction: Int, CaseIterable {
            case both = 0, forward = 1, backward = 2

            var title: String {
                switch self {
                case .both: return "Both"
                case .forward: return "Forward"
                case .backward: return "Backward"
                }
            }

            /// The desktop stores the name ("BOTH"); any case, BOTH for a name this build doesn't know.
            init(name: String?) {
                switch name?.trimmingCharacters(in: .whitespaces).uppercased() {
                case "FORWARD": self = .forward
                case "BACKWARD": self = .backward
                default: self = .both
                }
            }

            var storedName: String {
                switch self {
                case .both: return "BOTH"
                case .forward: return "FORWARD"
                case .backward: return "BACKWARD"
                }
            }
        }

        var enabled = true
        var direction: String = Direction.both.storedName
        var passes = 1

        init() {}

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
            direction = try c.decodeIfPresent(String.self, forKey: .direction) ?? Direction.both.storedName
            passes = try c.decodeIfPresent(Int.self, forKey: .passes) ?? 1
        }

        var directionValue: Direction {
            get { Direction(name: direction) }
            set { direction = newValue.storedName }
        }

        /// `passes`, never below 1.
        var effectivePasses: Int { max(1, passes) }
    }

    /// What the compositor needs to draw a clip's motion: set by the composition builder, read on the render queue.
    struct MotionLayerInfo {
        /// The second composition track: the same footage one source frame later. Invalid when the clip has none.
        var nextTrackID: CMPersistentTrackID
        var sourceFPS: Double
        /// Source seconds both tracks are shifted ahead (see the header).
        var lookAhead: Double
        var trim: Double
        var timeMap: ClipTimeMap
        /// nil = no optical flow; else the frame rate its frames are made at.
        var flowFPS: Float?
        var blurOn: Bool
        var direction: Int
        var passes: Int
    }
}

extension EditingView.Clip {
    var hasOpticalFlow: Bool { opticalFlow?.enabled == true }
    var hasMotionBlur: Bool { motionBlur?.enabled == true }
}

extension EditingView.VideoProperties.ValueType {
    /// The motion blur sliders: like `strength`, held only by a keyframe that lists them.
    var isMotion: Bool { self == .motionBlur || self == .motionBlend }
}

// MARK: - The plain arithmetic (no GPU)

enum MotionMath {

    /// The finest flow level is about this many pixels on its long side.
    static let maxLevels = 4, minSide = 24
    static let snapAlpha = 0.02
    /// A quarter of a frame (see the header of EditingView+Motion.swift).
    static let lookAheadFrames = 0.25

    enum Mode { case first, second, mix }

    /// The start of the grid frame that `elapsed` (seconds since the clip's first frame, after its speed) falls in, for frames made
    /// `fps` times a second. Before the clip starts nothing is snapped.
    static func snapToGrid(_ elapsed: Double, fps: Double) -> Double {
        if elapsed <= 0 || !(fps > 0) || fps.isInfinite { return elapsed }
        return (elapsed * fps + 1e-6).rounded(.down) / fps
    }

    static func mode(for alpha: Double) -> Mode {
        if alpha < snapAlpha { return .first }
        if alpha > 1.0 - snapAlpha { return .second }
        return .mix
    }

    /// {finest mip level, number of levels}: the finest is the mip whose long side is nearest above `flowSide`; fewer levels for a
    /// small picture so the coarsest keeps at least `minSide` pixels on its short side.
    static func plan(width: Int, height: Int, flowSide: Int) -> (finest: Int, levels: Int) {
        let longSide = max(width, height), shortSide = min(width, height)
        var finest = 0
        while (longSide >> finest) > flowSide { finest += 1 }
        var levels = maxLevels
        while levels > 1 && (shortSide >> (finest + levels - 1)) < minSide { levels -= 1 }
        return (finest, levels)
    }

    static func mipSize(_ size: Int, _ lod: Int) -> Int { max(1, size >> lod) }

    /// Two frames are different shots when BOTH their 32 x 18 mosaics and their brightness histograms differ a lot: a pan over a
    /// contrasty picture moves the mosaic but keeps the histogram, a fade moves the histogram a little but not the mosaic.
    static func isSceneCut(_ a: CVPixelBuffer, _ b: CVPixelBuffer) -> Bool {
        let width = CVPixelBufferGetWidth(a), height = CVPixelBufferGetHeight(a)
        let cols = 32, rows = 18, sub = 4, bins = 16
        guard width >= cols, height >= rows, CVPixelBufferGetWidth(b) == width, CVPixelBufferGetHeight(b) == height else { return false }
        CVPixelBufferLockBaseAddress(a, .readOnly); CVPixelBufferLockBaseAddress(b, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(a, .readOnly); CVPixelBufferUnlockBaseAddress(b, .readOnly) }
        guard let baseA = CVPixelBufferGetBaseAddress(a), let baseB = CVPixelBufferGetBaseAddress(b) else { return false }
        let strideA = CVPixelBufferGetBytesPerRow(a), strideB = CVPixelBufferGetBytesPerRow(b)
        let pa = baseA.assumingMemoryBound(to: UInt8.self), pb = baseB.assumingMemoryBound(to: UInt8.self)
        // BGRA: b, g, r, a
        func luma(_ p: UnsafePointer<UInt8>, _ at: Int) -> Double {
            (0.299 * Double(p[at + 2]) + 0.587 * Double(p[at + 1]) + 0.114 * Double(p[at])) / 255.0
        }
        var total = 0.0
        var ha = [Int](repeating: 0, count: bins), hb = [Int](repeating: 0, count: bins)
        for cy in 0..<rows {
            for cx in 0..<cols {
                var sa = 0.0, sb = 0.0
                for sy in 0..<sub {
                    for sx in 0..<sub {
                        let x = min(width - 1, Int((Double(cx) + (Double(sx) + 0.5) / Double(sub)) * Double(width) / Double(cols)))
                        let y = min(height - 1, Int((Double(cy) + (Double(sy) + 0.5) / Double(sub)) * Double(height) / Double(rows)))
                        let la = luma(pa, y * strideA + x * 4), lb = luma(pb, y * strideB + x * 4)
                        sa += la; sb += lb
                        ha[min(bins - 1, Int(la * Double(bins)))] += 1
                        hb[min(bins - 1, Int(lb * Double(bins)))] += 1
                    }
                }
                total += abs(sa - sb) / Double(sub * sub)
            }
        }
        if total / Double(cols * rows) <= 0.15 { return false }
        let n = Double(cols * rows * sub * sub)
        var histogram = 0.0
        for i in 0..<bins { histogram += abs(Double(ha[i] - hb[i])) / n }
        return histogram / 2 > 0.35
    }
}

// MARK: - The GPU side

/// Makes the picture between two decoded frames (optical flow) and smears it along the motion (motion blur) with Metal. Used from the
/// compositor's render queue only. When the GPU can't build the kernels (`init` returns nil) or a pass fails, clips draw the plain frame.
final class MotionFlowEngine {

    /// The finest flow level is about this many pixels on its long side (the desktop uses 320 for its preview, 480 for an export).
    static var flowSide = 320
    static let maxBlurPasses = 24
    private static let maxBlurTaps = 48
    /// Per pyramid level: radius, step, block half size, stride (tuned on the desktop against ground truth).
    private static let coarse = (radius: 8, step: Float(1), win: 4, stride: 2)
    private static let mid = (radius: 2, step: Float(1), win: 3, stride: 2)
    private static let fine = (radius: 2, step: Float(1), win: 3, stride: 2)
    private static let sub = (radius: 1, step: Float(0.5), win: 1, stride: 1)
    private static let bias: Float = 0.002
    private static let costLo: Float = 0.4, costHi: Float = 1.0, jumpLo: Float = 3.0, jumpHi: Float = 8.0

    struct Blur {
        var length: Float, blend: Float
        var direction: Int, passes: Int
    }

    /// What the caller draws: frame A as it is, frame B as it is, or the picture made here.
    enum Outcome {
        case first, second
        case picture(CIImage)
    }

    // Must match the structs in MotionFlow.metal.
    private struct SearchParams { var lod: Int32, hasPrev: Int32, radius: Int32, win: Int32, stride: Int32; var alpha: Float, step: Float, bias: Float }
    private struct ComposeParams { var alpha: Float, costLo: Float, costHi: Float, incLo: Float, incHi: Float }
    private struct StreakParams { var length: Float; var direction: Int32; var blend: Float, costLo: Float, costHi: Float; var maxTaps: Int32 }

    /// What one clip layer keeps: the two frames, the pyramid and where the result goes.
    private final class State {
        let width: Int, height: Int, finest: Int, levels: Int
        let texA: MTLTexture, texB: MTLTexture
        let flow: [MTLTexture]            // per level, index 0 = the finest
        let sub: MTLTexture               // the finest level's half pixel pass
        let outBuffer: CVPixelBuffer
        let outTexture: MTLTexture
        var base: MTLTexture?, ping: MTLTexture?, pong: MTLTexture?
        var uploadedPair = Int.min
        var cutPair = Int.min
        var cut = false

        init(width: Int, height: Int, finest: Int, levels: Int, texA: MTLTexture, texB: MTLTexture, flow: [MTLTexture],
             sub: MTLTexture, outBuffer: CVPixelBuffer, outTexture: MTLTexture) {
            self.width = width; self.height = height; self.finest = finest; self.levels = levels
            self.texA = texA; self.texB = texB; self.flow = flow; self.sub = sub
            self.outBuffer = outBuffer; self.outTexture = outTexture
        }
    }

    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let searchPipeline: MTLComputePipelineState
    private let composePipeline: MTLComputePipelineState
    private let streakPipeline: MTLComputePipelineState
    private var textureCache: CVMetalTextureCache?
    private var states: [UUID: State] = [:]
    private var order: [UUID] = []          // least recently used first
    private let maxStates = 4
    private var broken = false

    init?() {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue(),
              let library = device.makeDefaultLibrary(),
              let search = library.makeFunction(name: "flowSearch"),
              let compose = library.makeFunction(name: "flowCompose"),
              let streak = library.makeFunction(name: "motionStreak"),
              let searchPipeline = try? device.makeComputePipelineState(function: search),
              let composePipeline = try? device.makeComputePipelineState(function: compose),
              let streakPipeline = try? device.makeComputePipelineState(function: streak) else { return nil }
        self.device = device
        self.queue = queue
        self.searchPipeline = searchPipeline
        self.composePipeline = composePipeline
        self.streakPipeline = streakPipeline
        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &textureCache)
        if textureCache == nil { return nil }
    }

    /// The picture `alpha` of the way from frame `a` (0) to frame `b` (1). `pairIndex` says which two frames these are (the same
    /// index = the same pair, so nothing is uploaded again). With `interpolate` false the picture is frame `a` and only the motion
    /// between the two is used (a clip with motion blur but no optical flow). `blur` (or nil) then smears the picture.
    func render(clipID: UUID, pairIndex: Int, a: CVPixelBuffer, b: CVPixelBuffer, alpha: Double,
                interpolate: Bool, blur: Blur?) -> Outcome {
        var mode: MotionMath.Mode = interpolate ? MotionMath.mode(for: alpha) : .first
        func plain() -> Outcome { mode == .second ? .second : .first }
        if broken { return interpolate && alpha >= 0.5 ? .second : .first }

        let width = CVPixelBufferGetWidth(a), height = CVPixelBufferGetHeight(a)
        guard width > 0, height > 0, CVPixelBufferGetWidth(b) == width, CVPixelBufferGetHeight(b) == height,
              let state = state(for: clipID, width: width, height: height) else { return plain() }

        if state.cutPair != pairIndex {
            state.cutPair = pairIndex
            state.cut = MotionMath.isSceneCut(a, b)
        }
        var blur = blur
        // A scene cut has no in-between picture and no motion to smear: the nearer frame is held.
        if state.cut {
            blur = nil
            if mode == .mix { mode = alpha < 0.5 ? .first : .second }
        }
        if blur == nil && mode != .mix { return plain() }

        guard let commandBuffer = queue.makeCommandBuffer(),
              let textureA = texture(from: a), let textureB = texture(from: b) else { return plain() }

        if state.uploadedPair != pairIndex {
            guard let blit = commandBuffer.makeBlitCommandEncoder() else { return plain() }
            for (source, target) in [(textureA.texture, state.texA), (textureB.texture, state.texB)] {
                blit.copy(from: source, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                          sourceSize: MTLSize(width: width, height: height, depth: 1),
                          to: target, destinationSlice: 0, destinationLevel: 0, destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
                blit.generateMipmaps(for: target)       // the pyramid samples the frames at coarser sizes
            }
            blit.endEncoding()
            state.uploadedPair = pairIndex
        }

        guard let encoder = commandBuffer.makeComputeCommandEncoder() else { return plain() }
        // the motion is looked for at the moment of the picture: A for the first frame, B for the second, between for a mix
        let searchAlpha: Float = mode == .first ? 0 : mode == .second ? 1 : Float(alpha)
        runPyramid(encoder, state, alpha: searchAlpha)
        if let blur {
            var base = state.texA
            if mode == .mix {
                let target = ensure(&state.base, width, height)
                compose(encoder, state, alpha: Float(alpha), target: target)
                base = target
            } else if mode == .second {
                base = state.texB
            }
            smear(encoder, state, base: base, blur: blur)
        } else {
            compose(encoder, state, alpha: Float(alpha), target: state.outTexture)
        }
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        withExtendedLifetime((textureA, textureB)) {}
        if commandBuffer.status == .error {
            broken = true       // a GPU that can't do it: every clip draws its nearer frame from now on
            return plain()
        }
        return .picture(CIImage(cvPixelBuffer: state.outBuffer))
    }

    // MARK: The passes

    private func runPyramid(_ encoder: MTLComputeCommandEncoder, _ s: State, alpha: Float) {
        encoder.setComputePipelineState(searchPipeline)
        var previous: MTLTexture?
        for k in stride(from: s.levels - 1, through: 0, by: -1) {
            let p = k == s.levels - 1 ? Self.coarse : (k == 0 ? Self.fine : Self.mid)
            searchPass(encoder, s, level: k, previous: previous, radius: p.radius, step: p.step, win: p.win, stride: p.stride,
                       alpha: alpha, target: s.flow[k])
            previous = s.flow[k]
        }
        // half pixel refinement of the finest level (written to its own texture, never read and written at once)
        let r = Self.sub
        searchPass(encoder, s, level: 0, previous: previous, radius: r.radius, step: r.step, win: r.win, stride: r.stride,
                   alpha: alpha, target: s.sub)
    }

    private func searchPass(_ encoder: MTLComputeCommandEncoder, _ s: State, level k: Int, previous: MTLTexture?,
                            radius: Int, step: Float, win: Int, stride: Int, alpha: Float, target: MTLTexture) {
        var params = SearchParams(lod: Int32(s.finest + k), hasPrev: previous == nil ? 0 : 1, radius: Int32(radius), win: Int32(win),
                                  stride: Int32(stride), alpha: alpha, step: step, bias: Self.bias)
        encoder.setTexture(s.texA, index: 0)
        encoder.setTexture(s.texB, index: 1)
        encoder.setTexture(previous ?? s.texA, index: 2)        // never read when hasPrev is 0
        encoder.setTexture(target, index: 3)
        encoder.setBytes(&params, length: MemoryLayout<SearchParams>.stride, index: 0)
        dispatch(encoder, searchPipeline, width: target.width, height: target.height)
    }

    private func compose(_ encoder: MTLComputeCommandEncoder, _ s: State, alpha: Float, target: MTLTexture) {
        var params = ComposeParams(alpha: alpha, costLo: Self.costLo, costHi: Self.costHi, incLo: Self.jumpLo, incHi: Self.jumpHi)
        encoder.setComputePipelineState(composePipeline)
        encoder.setTexture(s.texA, index: 0)
        encoder.setTexture(s.texB, index: 1)
        encoder.setTexture(s.sub, index: 2)
        encoder.setTexture(target, index: 3)
        encoder.setBytes(&params, length: MemoryLayout<ComposeParams>.stride, index: 0)
        dispatch(encoder, composePipeline, width: s.width, height: s.height)
    }

    /// `base` (the sharp picture) smeared `blur.passes` times along the motion, each pass reading the one before; the last one mixes
    /// the sharp picture back in by Blend and writes the result.
    private func smear(_ encoder: MTLComputeCommandEncoder, _ s: State, base: MTLTexture, blur: Blur) {
        let ping = ensure(&s.ping, s.width, s.height), pong = ensure(&s.pong, s.width, s.height)
        let passes = max(1, min(Self.maxBlurPasses, blur.passes))
        encoder.setComputePipelineState(streakPipeline)
        var source = base
        for i in 0..<passes {
            let last = i == passes - 1
            let target = last ? s.outTexture : (i % 2 == 0 ? ping : pong)
            var params = StreakParams(length: blur.length, direction: Int32(blur.direction), blend: last ? blur.blend : 0,
                                      costLo: Self.costLo, costHi: Self.costHi, maxTaps: Int32(Self.maxBlurTaps))
            encoder.setTexture(source, index: 0)
            encoder.setTexture(base, index: 1)
            encoder.setTexture(s.sub, index: 2)
            encoder.setTexture(target, index: 3)
            encoder.setBytes(&params, length: MemoryLayout<StreakParams>.stride, index: 0)
            dispatch(encoder, streakPipeline, width: s.width, height: s.height)
            source = target
        }
    }

    private func dispatch(_ encoder: MTLComputeCommandEncoder, _ pipeline: MTLComputePipelineState, width: Int, height: Int) {
        let w = pipeline.threadExecutionWidth
        let h = max(1, pipeline.maxTotalThreadsPerThreadgroup / w)
        encoder.dispatchThreads(MTLSize(width: width, height: height, depth: 1),
                                threadsPerThreadgroup: MTLSize(width: w, height: min(h, 8), depth: 1))
    }

    // MARK: Textures

    private func texture(from buffer: CVPixelBuffer) -> (texture: MTLTexture, holder: CVMetalTexture)? {
        guard let cache = textureCache else { return nil }
        var holder: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, cache, buffer, nil, .bgra8Unorm,
                                                               CVPixelBufferGetWidth(buffer), CVPixelBufferGetHeight(buffer), 0, &holder)
        guard status == kCVReturnSuccess, let holder, let texture = CVMetalTextureGetTexture(holder) else { return nil }
        return (texture, holder)
    }

    private func ensure(_ slot: inout MTLTexture?, _ width: Int, _ height: Int) -> MTLTexture {
        if let existing = slot { return existing }
        let made = Self.plainTexture(device, width, height)!
        slot = made
        return made
    }

    private static func plainTexture(_ device: MTLDevice, _ width: Int, _ height: Int) -> MTLTexture? {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        d.usage = [.shaderRead, .shaderWrite]
        d.storageMode = .private
        return device.makeTexture(descriptor: d)
    }

    private func state(for clipID: UUID, width: Int, height: Int) -> State? {
        if let existing = states[clipID], existing.width == width, existing.height == height {
            order.removeAll { $0 == clipID }
            order.append(clipID)
            return existing
        }
        guard let made = makeState(width: width, height: height) else { return nil }
        states[clipID] = made
        order.removeAll { $0 == clipID }
        order.append(clipID)
        while order.count > maxStates { states[order.removeFirst()] = nil }
        return made
    }

    private func makeState(width: Int, height: Int) -> State? {
        let plan = MotionMath.plan(width: width, height: height, flowSide: Self.flowSide)

        let frame = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: true)
        frame.usage = [.shaderRead, .renderTarget]
        frame.storageMode = .private
        guard let texA = device.makeTexture(descriptor: frame), let texB = device.makeTexture(descriptor: frame) else { return nil }

        func flowTexture(_ lod: Int) -> MTLTexture? {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float,
                                                             width: MotionMath.mipSize(width, lod), height: MotionMath.mipSize(height, lod),
                                                             mipmapped: false)
            d.usage = [.shaderRead, .shaderWrite]
            d.storageMode = .private
            return device.makeTexture(descriptor: d)
        }
        var flow: [MTLTexture] = []
        for k in 0..<plan.levels {
            guard let t = flowTexture(plan.finest + k) else { return nil }
            flow.append(t)
        }
        guard let sub = flowTexture(plan.finest) else { return nil }

        // The result goes into a pixel buffer, so the rest of the Core Image pipeline takes it like any decoded frame.
        let attributes: [String: Any] = [kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
                                         kCVPixelBufferMetalCompatibilityKey as String: true]
        var buffer: CVPixelBuffer?
        guard CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, attributes as CFDictionary, &buffer) == kCVReturnSuccess,
              let outBuffer = buffer, let surface = CVPixelBufferGetIOSurface(outBuffer)?.takeUnretainedValue() else { return nil }
        let out = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        out.usage = [.shaderRead, .shaderWrite]
        guard let outTexture = device.makeTexture(descriptor: out, iosurface: surface, plane: 0) else { return nil }

        return State(width: width, height: height, finest: plan.finest, levels: plan.levels, texA: texA, texB: texB,
                     flow: flow, sub: sub, outBuffer: outBuffer, outTexture: outTexture)
    }
}
