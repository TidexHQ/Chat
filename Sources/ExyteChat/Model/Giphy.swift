import Foundation

public struct GiphyMedia: Hashable, Sendable {
    public let id: String

    public init(id: String) {
        self.id = id
    }
}

public enum GiphyContentType: String, CaseIterable, Sendable {
    case gifs
    case stickers
    case recents
    case clips
}

enum GiphySupport {
    // The base ExyteChat target intentionally no longer bundles the Giphy SDK.
    static let isBundled = false
}
