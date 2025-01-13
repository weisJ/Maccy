import CachedAsyncImage
import FaviconFinder
import SwiftUI

private class FaviconCache {
  static let shared = FaviconCache()

  fileprivate var cache: [String: FaviconURL] = [:]
}

enum FaviconError: Error {
  case noUrlHost
}

struct AppImageView: View {
  private static let cornerRadiusRatio = 185.4 / 824
  let appImage: AppImage
  let size: CGSize
  var padding: CGFloat {
    return size.width * 0.1
  }
  var sizeWithoutPadding: CGSize {
    let imgWidth = size.width - 2 * padding
    let imgHeight = size.height - 2 * padding
    return CGSize(width: imgWidth, height: imgHeight)
  }
  @Environment(\.redactionReasons) private var redactionReasons: RedactionReasons

  private func fetchFaviconUrl(url: URL) async throws -> URL {
    guard let cacheKey = url.plainHost else { throw FaviconError.noUrlHost }

    if let faviconUrl = FaviconCache.shared.cache[cacheKey] {
      return faviconUrl.source
    }

    let faviconUrl = try await FaviconFinder(
      url: url,
      configuration: .init(
        preferredSource: .html,
        preferences: [
          .html: FaviconFormatType.appleTouchIcon.rawValue,
          .ico: "favicon.ico",
          .webApplicationManifestFile: FaviconFormatType.launcherIcon4x
            .rawValue,
        ]
      )
    )
    .fetchFaviconURLs()
    .largest()

    FaviconCache.shared.cache[cacheKey] = faviconUrl

    return faviconUrl.source
  }

  @ViewBuilder func appImage(image: NSImage) -> some View {
    let isRedacted = !redactionReasons.isEmpty
    let imageSize = isRedacted ? sizeWithoutPadding : size
    let padding = isRedacted ? padding : 0
    Image(nsImage: image)
      .resizable()
      .frame(width: imageSize.width, height: imageSize.height)
      .cornerRadius(imageSize.width * Self.cornerRadiusRatio)
      .padding(padding)
  }

  var body: some View {
    let nsImage = appImage.nsImage
    if let remoteUrl = appImage.remoteUrl {
      AsyncView {
        try await fetchFaviconUrl(url: remoteUrl)
      } content: { imageUrl in
        CachedAsyncImage(url: imageUrl) { image in
          let imageSize = sizeWithoutPadding
          image
            .resizable()
            .background(redactionReasons.isEmpty ? .white : .clear)
            .frame(width: imageSize.width, height: imageSize.height)
            .cornerRadius(imageSize.width * Self.cornerRadiusRatio)
            .padding(padding)
        } placeholder: {
          appImage(image: nsImage)
        }
      } placeholder: {
        appImage(image: nsImage)
      }
    } else {
      appImage(image: nsImage)
    }
  }
}
