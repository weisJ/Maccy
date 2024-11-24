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
  let appImage: AppImage
  let size: CGSize

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
    Image(nsImage: image)
      .resizable()
      .frame(width: size.width, height: size.height)
  }

  var body: some View {
    let nsImage = appImage.nsImage
    if let remoteUrl = appImage.remoteUrl {
      AsyncView {
        try await fetchFaviconUrl(url: remoteUrl)
      } content: { imageUrl in
        CachedAsyncImage(url: imageUrl) { image in
          image
            .resizable()
            .frame(width: size.width, height: size.height)
            .cornerRadius(size.width * 185.4 / 824)
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
