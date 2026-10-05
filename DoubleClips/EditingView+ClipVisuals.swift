import SwiftUI

// MARK: - What a clip block shows
//
//   VIDEO / IMAGE  a CapCut-style strip of 16:9 tiles (desktop ClipNode). Tile i shows the source
//                  frame at the time of its LEFT edge, so trimming/zooming just reveals other tiles.
//   AUDIO          the waveform (Android AudioUtils / desktop AudioUtils): navy background, a faint
//                  centre line, symmetric bars whose height is the RMS of the audio under the bar
//                  and whose opacity grows with loudness, over the trimmed window of the file.
//   TEXT / EFFECT  unchanged (plain tinted block).
//
// Only what is on screen (plus a margin) is built: a 10-minute clip at maximum zoom is ~100 000 pt
// wide, but needs about eight tiles or a few hundred bars at any moment.

/// What a block needs to know about the timeline to work out its visible part.
struct ClipMediaContext {
    var projectPath: String
    var scrollOffset: CGFloat       // timeline contentOffset.x
    var viewportWidth: CGFloat
    var centerOffset: CGFloat       // x of time 0 inside the scroll content
    
    static let empty = ClipMediaContext(projectPath: "", scrollOffset: 0, viewportWidth: 0, centerOffset: 0)
}

struct ClipVisualContent: View {
    @ObservedObject var clip: EditingView.Clip
    /// The ghost passes its own (dragged) start time; blocks pass `clip.startTime`.
    let displayStartTime: Float
    let pps: CGFloat
    let blockWidth: CGFloat
    let height: CGFloat
    let media: ClipMediaContext
    
    /// Part of the block (in block-local x) that is on screen, plus a prefetch margin.
    private var visible: ClosedRange<CGFloat> {
        guard media.viewportWidth > 0 else { return 0...min(blockWidth, 600) }
        let left = media.centerOffset + CGFloat(displayStartTime) * pps
        let margin: CGFloat = 160
        let lo = max(0, media.scrollOffset - left - margin)
        let hi = min(blockWidth, media.scrollOffset + media.viewportWidth - left + margin)
        return lo <= hi ? lo...hi : 0...0
    }
    
    var body: some View {
        if !media.projectPath.isEmpty {
            let url = clip.mediaURL(projectPath: media.projectPath)
            switch clip.type {
            case .video, .image:
                ZStack(alignment: .bottomLeading) {
                    ClipThumbnailStrip(url: url, isVideo: clip.type == .video, startTrim: clip.startClipTrim,
                                       pps: pps, blockWidth: blockWidth, height: height, visible: visible)
                    // The video's own audio, as a thin band over the bottom of the tiles. A silent
                    // video has no audio track: the envelope is nil and only the scrim shows.
                    if clip.type == .video && Constants.VIDEO_WAVEFORM_ENABLED {
                        ClipWaveformView(url: url, startTrim: clip.startClipTrim,
                                         pps: pps, blockWidth: blockWidth,
                                         height: Constants.VIDEO_WAVEFORM_BAND_HEIGHT,
                                         visible: visible, isBand: true)
                    }
                }
                .frame(width: blockWidth, height: height, alignment: .bottomLeading)
            case .audio:
                ClipWaveformView(url: url, startTrim: clip.startClipTrim,
                                 pps: pps, blockWidth: blockWidth, height: height, visible: visible)
            default:
                EmptyView()
            }
        }
    }
}

// MARK: - Video / image strip

struct ClipThumbnailStrip: View {
    let url: URL
    let isVideo: Bool
    let startTrim: Float
    let pps: CGFloat
    let blockWidth: CGFloat
    let height: CGFloat
    let visible: ClosedRange<CGFloat>
    
    var body: some View {
        let tileWidth = height * 16.0 / 9.0
        let count = max(1, Int((blockWidth / tileWidth).rounded(.up)))
        let first = max(0, Int((visible.lowerBound / tileWidth).rounded(.down)))
        let last = min(count - 1, Int((visible.upperBound / tileWidth).rounded(.down)))
        
        ZStack(alignment: .topLeading) {
            if first <= last {
                ForEach(first...last, id: \.self) { index in
                    ThumbnailTile(url: url, isVideo: isVideo,
                                  time: Double(startTrim) + Double(CGFloat(index) * tileWidth / max(pps, 1)),
                                  width: tileWidth, height: height)
                        .offset(x: CGFloat(index) * tileWidth)
                }
            }
        }
        .frame(width: blockWidth, height: height, alignment: .topLeading)
        .clipped()
    }
}

struct ThumbnailTile: View {
    let url: URL
    let isVideo: Bool
    let time: Double
    let width: CGFloat
    let height: CGFloat
    @State private var image: UIImage?
    
    /// 0.25 s grid: zooming or nudging a trim by a few pixels reuses the cached frame
    /// instead of extracting a new one.
    private var quantizedTime: Double { isVideo ? max(0, (time / 0.25).rounded() * 0.25) : 0 }
    
    var body: some View {
        ZStack {
            Color.black.opacity(0.28)
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()                       // crop, never stretch (portrait clips)
            }
        }
        .frame(width: width, height: height)
        .clipped()
        .task(id: "\(url.lastPathComponent)|\(quantizedTime)") {
            image = await ClipMediaCache.shared.thumbnail(url: url, isVideo: isVideo, time: quantizedTime)
        }
    }
}

// MARK: - Audio waveform

struct ClipWaveformView: View {
    let url: URL
    let startTrim: Float
    let pps: CGFloat
    let blockWidth: CGFloat
    let height: CGFloat
    let visible: ClosedRange<CGFloat>
    /// Video blocks: a short, white-on-scrim strip instead of the full-height navy audio block.
    var isBand: Bool = false
    @State private var envelope: WaveformEnvelope?
    
    // Android: thumbnailAudioBarWidth / thumbnailAudioBarGap. Edited live in the project settings
    // panel ("Thumbnail Preview"); the canvas redraws when they change.
    @AppStorage(Constants.PREF_WAVEFORM_BAR_WIDTH_KEY) private var barWidthSetting = Constants.WAVEFORM_BAR_WIDTH_DEFAULT
    @AppStorage(Constants.PREF_WAVEFORM_BAR_GAP_KEY) private var barGapSetting = Constants.WAVEFORM_BAR_GAP_DEFAULT
    private var barWidth: CGFloat { CGFloat(min(max(barWidthSetting, 1), Constants.WAVEFORM_BAR_MAX)) }
    private var barGap: CGFloat { CGFloat(min(max(barGapSetting, 0), Constants.WAVEFORM_BAR_MAX)) }
    
    var body: some View {
        let loadedEnvelope = self.envelope      // (own name: the .task below assigns the @State `envelope`)
        // The canvas covers only the on-screen slice of the block (not the whole, possibly tens of
        // thousands of points wide, clip) and is shifted into place: a huge Canvas can exceed the
        // GPU texture limit and silently stop drawing.
        let sliceStart = visible.lowerBound
        let sliceWidth = max(1, visible.upperBound - visible.lowerBound)
        
        Canvas { context, size in
            let midY = size.height / 2
            let blue = isBand ? Color.white : Color(red: 0x1E / 255, green: 0x90 / 255, blue: 0xFF / 255)
            
            // Faint centre line (Android: basePaint alpha 60).
            context.fill(Path(CGRect(x: 0, y: midY - 0.5, width: size.width, height: 1)),
                         with: .color(blue.opacity(60.0 / 255)))
            guard let envelope = loadedEnvelope else { return }        // still decoding: just the line
            
            let stride = barWidth + barGap
            let maxHalf = midY - 2
            let firstBar = max(0, Int((sliceStart / stride).rounded(.down)))
            let lastBar = Int(((sliceStart + sliceWidth) / stride).rounded(.up))
            guard firstBar <= lastBar else { return }
            
            for bar in firstBar...lastBar {
                let blockX = CGFloat(bar) * stride            // x inside the whole block
                if blockX >= blockWidth { break }
                // The bar's slice of the file: the clip's trimmed window, in source seconds.
                let t0 = Double(startTrim) + Double(blockX / max(pps, 1))
                let t1 = Double(startTrim) + Double((blockX + stride) / max(pps, 1))
                let amp = CGFloat(envelope.rms(from: t0, to: t1))
                let half = max(2, amp * maxHalf)
                let rect = CGRect(x: blockX - sliceStart, y: midY - half, width: barWidth, height: half * 2)
                // Android: alpha = 10 + 245 * amp — quiet parts fade away, loud ones are solid.
                context.fill(Path(roundedRect: rect, cornerRadius: 1),
                             with: .color(blue.opacity((10 + 245 * Double(amp)) / 255)))
            }
        }
        .frame(width: sliceWidth, height: height)
        .offset(x: sliceStart)
        .frame(width: blockWidth, height: height, alignment: .topLeading)
        .background(isBand ? Color.black.opacity(0.45) : Color(hex: "#0D1B2A"))
        .clipped()
        .task(id: url.lastPathComponent) {
            envelope = await ClipMediaCache.shared.waveform(for: url)
        }
    }
}
