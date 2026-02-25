import SwiftUI

extension EditingView {
    
    enum OverlayType: String, Identifiable {
        var id: String { rawValue }
        case videoProperties
        case textEdit
    }
    
    // MARK: - Overlays Container
    
    struct SpecificEditOverlay: View {
        let type: OverlayType
        let clip: EditingView.Clip?
        let onClose: () -> Void
        
        var body: some View {
            VStack(spacing: 0) {
                // Top Action Bar
                HStack {
                    Text(title(for: type))
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(.white)
                    Spacer()
                    Button(action: onClose) {
                        Image(systemName: "checkmark")
                            .foregroundColor(Color.mdPrimary)
                            .font(.system(size: 18, weight: .bold))
                    }
                }
                .padding()
                .background(Color(hex: "#1A1A1A"))
                
                // Content
                ScrollView {
                    VStack {
                        switch type {
                        case .videoProperties:
                            if let clip = clip {
                                VideoPropertiesEditor(clip: clip)
                            } else {
                                Text("No clip selected").foregroundColor(.white)
                            }
                        case .textEdit:
                            Text("Text Editor placeholder").foregroundColor(.white)
                        }
                    }
                    .padding()
                }
                .background(Color(hex: "#111111"))
            }
            .frame(height: 300) // matches editingZone height
            .transition(.move(edge: .bottom))
            .animation(.easeInOut, value: type)
        }
        
        private func title(for type: OverlayType) -> String {
            switch type {
            case .videoProperties: return "Video Properties"
            case .textEdit: return "Edit Text"
            }
        }
    }
    
    // MARK: - Video Properties Editor
    
    struct VideoPropertiesEditor: View {
        @ObservedObject var clip: EditingView.Clip
        
        var body: some View {
            VStack(spacing: 20) {
                PropertySlider(label: "Opacity", value: $clip.videoProperties.valueOpacity, range: 0...1)
                PropertySlider(label: "Speed", value: $clip.videoProperties.valueSpeed, range: 0.1...4.0)
                PropertySlider(label: "Scale X", value: $clip.videoProperties.valueScaleX, range: 0...5)
                PropertySlider(label: "Scale Y", value: $clip.videoProperties.valueScaleY, range: 0...5)
                PropertySlider(label: "Rotation", value: $clip.videoProperties.valueRot, range: -360...360)
            }
        }
    }
    
    struct PropertySlider: View {
        let label: String
        @Binding var value: Float
        let range: ClosedRange<Float>
        
        var body: some View {
            HStack {
                Text(label)
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.8))
                    .frame(width: 80, alignment: .leading)
                
                Slider(value: Binding(
                    get: { Double(value) },
                    set: { value = Float($0) }
                ), in: Double(range.lowerBound)...Double(range.upperBound))
                .accentColor(Color.mdPrimary)
                
                Text(String(format: "%.2f", value))
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(.white)
                    .frame(width: 40, alignment: .trailing)
            }
        }
    }
}
