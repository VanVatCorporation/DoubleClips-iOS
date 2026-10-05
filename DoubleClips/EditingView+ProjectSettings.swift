import SwiftUI

// MARK: - Project settings panel
//
// Android: the top-left settingsButton -> VideoPropertiesEditSpecificAreaScreen
// (view_edit_specific_video_properties.xml, "Project Settings"). Sections ported:
//   Video Encoding   resolution, framerate, constant rate factor, bitrate, clip cap
//   Advanced         hardware acceleration, export preset, export tune, stretch media to fit
//   Preview Playback preview fps <-> playback speed, reverse playback, keep playing with chosen clip
//   Thumbnail Preview audio bar width / gap
// Left out on purpose: the last Android section, "Preview" (GPU preview / use proxy). iOS has one
// rendering engine for preview and export, so there is nothing to switch.
//
// Like Android, the encoding fields are applied when the panel closes; the playback and thumbnail
// fields act live while typing / toggling. Fields that only FFmpeg exports use (CRF, preset, tune,
// hardware acceleration, clip cap) are still stored in project.settings so the project keeps them
// when it moves to Android / desktop.

struct ProjectSettingsSheet: View {
    let initial: EditingView.VideoSettings
    @ObservedObject var engine: EditingView.EditingPlayer
    /// Called once when the panel closes with the parsed, clamped values.
    let onCommit: (EditingView.VideoSettings) -> Void
    
    @Environment(\.dismiss) private var dismiss
    
    // Encoding (applied on close)
    @State private var width: String
    @State private var height: String
    @State private var frameRate: String
    @State private var crf: String
    @State private var bitrate: String
    @State private var clipCap: String
    @State private var useHardwareAccel: Bool
    @State private var preset: String
    @State private var tune: String
    @State private var stretch: Bool
    
    // Playback / thumbnails (live)
    @State private var previewFps: String
    @State private var previewSpeedText: String
    @AppStorage(Constants.PREF_KEEP_PLAYING_SELECTION_KEY) private var keepPlayingWithSelection = false
    @AppStorage(Constants.PREF_WAVEFORM_BAR_WIDTH_KEY) private var barWidth = Constants.WAVEFORM_BAR_WIDTH_DEFAULT
    @AppStorage(Constants.PREF_WAVEFORM_BAR_GAP_KEY) private var barGap = Constants.WAVEFORM_BAR_GAP_DEFAULT
    @State private var barWidthText: String
    @State private var barGapText: String
    
    private enum Field: Hashable {
        case width, height, frameRate, crf, bitrate, clipCap, previewFps, previewSpeed, barWidth, barGap
    }
    @FocusState private var focused: Field?
    
    // Android: FFmpegEdit.FFmpegUtilities.presetStringList / tuneStringList (JSON stores lowercase).
    static let presets = ["placebo", "veryslow", "slower", "slow", "medium",
                          "fast", "faster", "veryfast", "superfast", "ultrafast"]
    static let tunes = ["film", "animation", "grain", "stillimage", "fastdecode", "zerolatency"]
    
    init(initial: EditingView.VideoSettings, engine: EditingView.EditingPlayer,
         onCommit: @escaping (EditingView.VideoSettings) -> Void) {
        self.initial = initial
        self.engine = engine
        self.onCommit = onCommit
        _width = State(initialValue: String(initial.videoWidth))
        _height = State(initialValue: String(initial.videoHeight))
        _frameRate = State(initialValue: String(initial.frameRate))
        _crf = State(initialValue: String(initial.crf))
        _bitrate = State(initialValue: String(initial.bitrate))
        _clipCap = State(initialValue: String(initial.clipCap))
        _useHardwareAccel = State(initialValue: initial.useHardwareAccel)
        _preset = State(initialValue: initial.preset.lowercased())
        _tune = State(initialValue: initial.tune.lowercased())
        _stretch = State(initialValue: initial.isStretchToFull)
        let fps = Double(max(initial.frameRate, 1))
        _previewFps = State(initialValue: String(format: "%.1f", engine.previewSpeed * fps))
        _previewSpeedText = State(initialValue: String(format: "%.2f", engine.previewSpeed))
        let stored = UserDefaults.standard
        _barWidthText = State(initialValue: String(stored.object(forKey: Constants.PREF_WAVEFORM_BAR_WIDTH_KEY) as? Int
                                                   ?? Constants.WAVEFORM_BAR_WIDTH_DEFAULT))
        _barGapText = State(initialValue: String(stored.object(forKey: Constants.PREF_WAVEFORM_BAR_GAP_KEY) as? Int
                                                 ?? Constants.WAVEFORM_BAR_GAP_DEFAULT))
    }
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                header
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        encodingSection
                        advancedSection
                        Text("Constant rate factor, hardware acceleration, preset, tune and clip cap are used by FFmpeg exports on Android and desktop. They are saved with the project, but the iOS export always uses the hardware H.264 encoder (resolution, framerate, bitrate and stretch apply here too).")
                            .font(.footnote)
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 4)
                        playbackSection
                        thumbnailSection
                    }
                    .padding(16)
                }
                .scrollDismissesKeyboard(.interactively)
            }
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { focused = nil }
                }
            }
            .toolbar(.hidden, for: .navigationBar)
        }
        // Closing by the X, a swipe down or anything else: the same place Android's onClose runs.
        .onDisappear { commit() }
    }
    
    // MARK: Pieces
    
    private var header: some View {
        ZStack {
            Capsule()
                .fill(Color.secondary.opacity(0.35))
                .frame(width: 36, height: 4)
                .frame(maxHeight: .infinity, alignment: .top)
                .padding(.top, 8)
            HStack {
                Text("Project Settings")
                    .font(.system(size: 17, weight: .bold))
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.secondary)
                        .frame(width: 40, height: 40)
                }
            }
            .padding(.leading, 16)
            .padding(.trailing, 4)
        }
        .frame(height: 56)
    }
    
    private var encodingSection: some View {
        ExportSection(title: "Video Encoding") {
            VStack(spacing: 0) {
                SettingRow(icon: "aspectratio", label: "Resolution") {
                    HStack(spacing: 4) {
                        numberField("1920", text: $width, field: .width)
                        Text("×").foregroundColor(.secondary)
                        numberField("1080", text: $height, field: .height)
                    }
                }
                RowDivider()
                SettingRow(icon: "speedometer", label: "Framerate") {
                    HStack(spacing: 6) {
                        numberField("30", text: $frameRate, field: .frameRate)
                        Text("fps").foregroundColor(.secondary)
                    }
                }
                RowDivider()
                SettingRow(icon: "slider.horizontal.3", label: "Constant rate factor") {
                    numberField("30", text: $crf, field: .crf)
                }
                .disabled(useHardwareAccel)
                .opacity(useHardwareAccel ? 0.38 : 1)
                RowDivider()
                SettingRow(icon: "gauge.with.dots.needle.67percent", label: "Bitrate (Mbps)") {
                    HStack(spacing: 6) {
                        numberField("15", text: $bitrate, field: .bitrate)
                        Text("Mbps").foregroundColor(.secondary)
                    }
                }
                RowDivider()
                SettingRow(icon: "square.stack.3d.up", label: "Clip Cap") {
                    numberField("30", text: $clipCap, field: .clipCap)
                }
            }
        }
    }
    
    private var advancedSection: some View {
        ExportSection(title: "Advanced") {
            VStack(spacing: 0) {
                SettingRow(icon: "cpu", label: "Hardware Acceleration") {
                    Toggle("", isOn: $useHardwareAccel).labelsHidden()
                }
                RowDivider()
                SettingRow(icon: "hare", label: "Export preset") {
                    Picker("", selection: $preset) {
                        ForEach(Self.presetChoices(including: preset), id: \.self) { Text($0.capitalized).tag($0) }
                    }
                    .labelsHidden()
                }
                .disabled(useHardwareAccel)
                .opacity(useHardwareAccel ? 0.38 : 1)
                RowDivider()
                SettingRow(icon: "tuningfork", label: "Export tune") {
                    Picker("", selection: $tune) {
                        ForEach(Self.tuneChoices(including: tune), id: \.self) { Text($0.capitalized).tag($0) }
                    }
                    .labelsHidden()
                }
                .disabled(useHardwareAccel)
                .opacity(useHardwareAccel ? 0.38 : 1)
                RowDivider()
                SettingRow(icon: "arrow.up.left.and.arrow.down.right", label: "Stretch media to fit") {
                    Toggle("", isOn: $stretch).labelsHidden()
                }
            }
        }
    }
    
    private var playbackSection: some View {
        ExportSection(title: "Preview Playback") {
            VStack(spacing: 0) {
                SettingRow(icon: "play.rectangle", label: "Frames Per Second") {
                    HStack(spacing: 6) {
                        numberField("30", text: $previewFps, field: .previewFps, decimal: true)
                        Text("fps").foregroundColor(.secondary)
                    }
                }
                RowDivider()
                SettingRow(icon: "timer", label: "Playback Speed") {
                    HStack(spacing: 6) {
                        numberField("1.00", text: $previewSpeedText, field: .previewSpeed, decimal: true)
                        Text("x").foregroundColor(.secondary)
                    }
                }
                RowDivider()
                SettingRow(icon: "backward.fill", label: "Reverse Playback") {
                    Toggle("", isOn: $engine.playsInReverse).labelsHidden()
                }
                RowDivider()
                SettingRow(icon: "play.square.stack", label: "Keep Playing with Chosen Clip") {
                    Toggle("", isOn: $keepPlayingWithSelection).labelsHidden()
                }
            }
        }
        .onChange(of: previewFps) { text in
            // Android: only while the field has focus, so the cross-update does not ping-pong.
            guard focused == .previewFps, let fps = Self.parse(text), fps > 0 else { return }
            let speed = fps / Double(max(initial.frameRate, 1))
            engine.previewSpeed = min(max(speed, Constants.PREVIEW_SPEED_MIN), Constants.PREVIEW_SPEED_MAX)
            previewSpeedText = String(format: "%.2f", speed)
        }
        .onChange(of: previewSpeedText) { text in
            guard focused == .previewSpeed, let speed = Self.parse(text), speed > 0 else { return }
            engine.previewSpeed = min(max(speed, Constants.PREVIEW_SPEED_MIN), Constants.PREVIEW_SPEED_MAX)
            previewFps = String(format: "%.1f", speed * Double(max(initial.frameRate, 1)))
        }
    }
    
    private var thumbnailSection: some View {
        ExportSection(title: "Thumbnail Preview") {
            VStack(spacing: 0) {
                SettingRow(icon: "waveform", label: "Audio Bar Width") {
                    numberField("2", text: $barWidthText, field: .barWidth)
                }
                RowDivider()
                SettingRow(icon: "arrow.left.and.right", label: "Audio Bar Gap") {
                    numberField("1", text: $barGapText, field: .barGap)
                }
            }
        }
        // Android: width <= 0 becomes 1, gap < 0 becomes 0. Live, so the timeline redraws at once.
        .onChange(of: barWidthText) { text in
            guard let value = Int(text.trimmingCharacters(in: .whitespaces)) else { return }
            barWidth = min(max(value, 1), Constants.WAVEFORM_BAR_MAX)
        }
        .onChange(of: barGapText) { text in
            guard let value = Int(text.trimmingCharacters(in: .whitespaces)) else { return }
            barGap = min(max(value, 0), Constants.WAVEFORM_BAR_MAX)
        }
    }
    
    // MARK: Helpers
    
    private func numberField(_ placeholder: String, text: Binding<String>, field: Field,
                             decimal: Bool = false) -> some View {
        TextField(placeholder, text: text)
            .keyboardType(decimal ? .decimalPad : .numberPad)
            .multilineTextAlignment(.center)
            .focused($focused, equals: field)
            .frame(width: 60)
            .padding(.vertical, 6)
            .background(Color(uiColor: .tertiarySystemFill))
            .cornerRadius(6)
    }
    
    /// A value an older / newer build wrote that is not in the list still shows (and is kept).
    private static func presetChoices(including value: String) -> [String] {
        presets.contains(value) ? presets : presets + [value]
    }
    private static func tuneChoices(including value: String) -> [String] {
        tunes.contains(value) ? tunes : tunes + [value]
    }
    
    private static func parse(_ text: String) -> Double? {
        Double(text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: "."))
    }
    
    /// Android: ParserHelper.TryParse(field, current) — unparsable text keeps the old value.
    private func commit() {
        func parse(_ text: String, _ fallback: Int, _ lo: Int, _ hi: Int) -> Int {
            let value = Int(text.trimmingCharacters(in: .whitespaces)) ?? fallback
            return min(max(value, lo), hi)
        }
        var edited = initial
        edited.videoWidth = parse(width, initial.videoWidth, Constants.EXPORT_MIN_DIMENSION, Constants.EXPORT_MAX_DIMENSION)
        edited.videoHeight = parse(height, initial.videoHeight, Constants.EXPORT_MIN_DIMENSION, Constants.EXPORT_MAX_DIMENSION)
        edited.frameRate = parse(frameRate, initial.frameRate, Constants.EXPORT_MIN_FRAME_RATE, Constants.EXPORT_MAX_FRAME_RATE)
        edited.crf = parse(crf, initial.crf, Constants.PROJECT_CRF_MIN, Constants.PROJECT_CRF_MAX)
        edited.bitrate = parse(bitrate, initial.bitrate, Constants.EXPORT_MIN_BITRATE_MBPS, Constants.EXPORT_MAX_BITRATE_MBPS)
        edited.clipCap = parse(clipCap, initial.clipCap, Constants.PROJECT_CLIP_CAP_MIN, Constants.PROJECT_CLIP_CAP_MAX)
        edited.useHardwareAccel = useHardwareAccel
        edited.preset = preset
        edited.tune = tune
        edited.isStretchToFull = stretch
        onCommit(edited)
    }
}

// MARK: - project.settings edits

extension EditingView.VideoSettings {
    
    /// True when none of the fields the Project Settings panel edits differ (preset / tune compare
    /// case-insensitively: iOS used to write them upper-case, Android writes lower-case).
    func sameProjectFields(as other: EditingView.VideoSettings) -> Bool {
        videoWidth == other.videoWidth && videoHeight == other.videoHeight
            && frameRate == other.frameRate && crf == other.crf && bitrate == other.bitrate
            && clipCap == other.clipCap && useHardwareAccel == other.useHardwareAccel
            && preset.lowercased() == other.preset.lowercased()
            && tune.lowercased() == other.tune.lowercased()
            && isStretchToFull == other.isStretchToFull
    }
    
    /// Writes only the fields the panel owns into project.settings, keeping every other key in the
    /// file as is (renderEngine, legacyPreview, useProxyPreview, anything a newer build added).
    func persistProjectEdits(projectPath: String) {
        let path = IOHelper.combinePath(projectPath, Constants.DEFAULT_VIDEO_SETTINGS_FILENAME)
        var dict: [String: Any] = [:]
        if let data = FileManager.default.contents(atPath: path),
           let existing = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            dict = existing
        } else if let data = try? JSONEncoder().encode(self),
                  let encoded = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            dict = encoded      // no (readable) file yet: start from the full settings
        }
        dict["videoWidth"] = videoWidth
        dict["videoHeight"] = videoHeight
        dict["frameRate"] = frameRate
        dict["crf"] = crf
        dict["bitrate"] = bitrate
        dict["clipCap"] = clipCap
        dict["useHardwareAccel"] = useHardwareAccel
        dict["preset"] = preset.lowercased()
        dict["tune"] = tune.lowercased()
        dict["isStretchToFull"] = isStretchToFull
        guard let out = try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys]) else { return }
        do {
            try out.write(to: URL(fileURLWithPath: path), options: .atomic)
        } catch {
            print("[Settings] Could not save project.settings: \(error)")
        }
    }
}
