import Foundation
import ImageIO

/// Verify the host downsample dimensions before UIKit allocates decoded pixels.
enum LokalWidgetDisplayArtwork {
  static func validate(_ data: Data) -> Bool {
    guard !data.isEmpty, data.count <= LokalWidgetStore.maximumArtworkBytes,
          let source = CGImageSourceCreateWithData(data as CFData,
            [kCGImageSourceShouldCache: false] as CFDictionary),
          CGImageSourceGetCount(source) == 1,
          CGImageSourceGetStatus(source) == .statusComplete,
          let type = CGImageSourceGetType(source) as String?,
          type == "public.png" || type == "public.jpeg",
          let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
          let width = props[kCGImagePropertyPixelWidth] as? NSNumber,
          let height = props[kCGImagePropertyPixelHeight] as? NSNumber else { return false }
    // The host's canonical downsample is at most 600px on either axis. Check
    // again before UIKit can allocate decoded image surfaces in the extension.
    return width.doubleValue > 0 && height.doubleValue > 0
      && width.doubleValue <= 600 && height.doubleValue <= 600
  }

}
