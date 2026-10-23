import SwiftUI
import UIKit

// MARK: - File-Level Cache (Outside generic type)
private enum StorageThumbnailCache {
    static let shared: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 300
        return cache
    }()
}

/// A rounded thumbnail for an image in the Storage list: memory cache, then the disk cache, then one download (the server
/// has no thumbnail endpoint, so it spends a little of the daily download allowance, once). While it loads, or when it
/// fails (e.g. today's allowance is used up), the type icon stays.
struct StorageThumbnail<Placeholder: View>: View {
    let node: DriveNode
    var size: CGFloat = 40
    @ViewBuilder var placeholder: () -> Placeholder

    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                placeholder()
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .task(id: node.id) {
            if let hit = StorageThumbnailCache.shared.object(forKey: node.id as NSString) {
                image = hit
                return
            }
            guard let data = try? await DoubleClipsDrive.client.thumbnailData(for: node),
                  let img = UIImage(data: data) else { return }
            StorageThumbnailCache.shared.setObject(img, forKey: node.id as NSString)
            image = img
        }
    }
}
