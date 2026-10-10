import SwiftUI

extension EditingView {
    
    enum OverlayType: String, Identifiable {
        var id: String { rawValue }
        case videoProperties
        case textEdit
        case effectEdit
        case projectFiles
        case transition
    }
    
    // MARK: - Overlays Container
    
    struct SpecificEditOverlay: View {
        let type: OverlayType
        let clip: EditingView.Clip?
        let commandManager: CommandManager
        let projectPath: String
        let playhead: Float
        let frameRate: Int
        let onChanged: () -> Void
        let onClose: () -> Void
        
        var body: some View {
            VStack(spacing: 0) {
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
                
                ScrollView {
                    VStack {
                        if let clip = clip {
                            switch type {
                            case .videoProperties:
                                ClipPropertiesEditor(clip: clip, commandManager: commandManager,
                                                     playhead: playhead, frameRate: frameRate, onChanged: onChanged)
                            case .textEdit:
                                TextClipEditor(clip: clip, commandManager: commandManager, projectPath: projectPath, onChanged: onChanged)
                            case .effectEdit:
                                EffectClipEditor(clip: clip, commandManager: commandManager, onChanged: onChanged)
                            case .projectFiles, .transition:
                                EmptyView()     // have their own panels (ProjectFilesPanel / TransitionPanel)
                            }
                        } else {
                            Text("No clip selected").foregroundColor(.white)
                        }
                    }
                    .padding()
                }
                .background(Color(hex: "#111111"))
                .scrollDismissesKeyboard(.interactively)
            }
            .frame(height: 300) // matches editingZone height
            .transition(.move(edge: .bottom))
            .animation(.easeInOut, value: type)
        }
        
        private func title(for type: OverlayType) -> String {
            switch type {
            case .videoProperties: return "Clip Properties"
            case .textEdit: return "Edit Text"
            case .effectEdit: return "Effect"
            case .projectFiles: return "Project Files"
            case .transition: return "Transition"
            }
        }
    }
}
