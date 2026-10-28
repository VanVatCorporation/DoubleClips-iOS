import SwiftUI

/// The popup shown while a Storage download runs: file name, a progress bar, "12 MB / 70 MB" and Cancel.
/// It is an overlay on the whole app, not a sheet: it can't be swiped away, nothing behind it can be touched,
/// and the only way out is Cancel (or the download finishing).
struct DownloadPopup: View {
    @ObservedObject var model: StorageModel
    
    var body: some View {
        if let download = model.downloadProgress {
            ZStack {
                Color.black.opacity(0.45)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture { }                      // swallow taps: the screen behind is locked
                
                VStack(spacing: 14) {
                    Text("Downloading")
                        .font(.headline)
                    Text(download.name)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    
                    if let fraction = download.fraction {
                        ProgressView(value: fraction)
                            .progressViewStyle(.linear)
                    } else {
                        ProgressView()
                            .progressViewStyle(.linear)    // size unknown: indeterminate
                    }
                    
                    HStack {
                        Text(sizeText(download))
                            .font(.footnote.monospacedDigit())
                            .foregroundColor(.secondary)
                        Spacer()
                        if let fraction = download.fraction {
                            Text("\(Int((fraction * 100).rounded()))%")
                                .font(.footnote.monospacedDigit())
                                .foregroundColor(.secondary)
                        }
                    }
                    
                    Button(role: .cancel) { model.cancelDownload() } label: {
                        Text("Cancel").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
                .padding(20)
                .frame(maxWidth: 320)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                .padding(24)
            }
            .transition(.opacity)
            .accessibilityAddTraits(.isModal)
        }
    }
    
    /// "12 MB / 70 MB", or just what has arrived when the total isn't known.
    private func sizeText(_ download: StorageModel.DownloadProgress) -> String {
        let loaded = StorageModel.bytes(download.loaded)
        guard download.total > 0 else { return loaded }
        return "\(loaded) / \(StorageModel.bytes(download.total))"
    }
}
