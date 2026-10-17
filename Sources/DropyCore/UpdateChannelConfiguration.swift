import Foundation

/// A configured HTTPS feed and Ed25519 key are both required. An unconfigured
/// build cannot start an installer or silently fall back to unsigned downloads.
public struct UpdateChannelConfiguration: Equatable, Sendable {
    public let feed: String
    public let publicKey: String
    public init(feed: String, publicKey: String) { self.feed = feed; self.publicKey = publicKey }
    public var feedURL: URL? {
        guard let url = URL(string: feed), url.scheme == "https", let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              url.port == nil || url.port == 443 else { return nil }
        return url
    }
    public var isValid: Bool { feedURL != nil && Data(base64Encoded: publicKey)?.count == 32 }
}
