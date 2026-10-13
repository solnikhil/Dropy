import Foundation

/// Semantic release ordering, independent of display labels and build metadata.
/// Supports macOS's two-part short versions, normalizing their patch to zero.
public struct ReleaseVersion: Comparable, Sendable, CustomStringConvertible {
    public let major: Int
    public let minor: Int
    public let patch: Int
    public let prerelease: [String]

    public init?(_ text: String) {
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.utf8.count <= 128 else { return nil }
        if value.hasPrefix("v") { value.removeFirst() }
        let metadata = value.split(separator: "+", omittingEmptySubsequences: false)
        guard metadata.count <= 2 else { return nil }
        if metadata.count == 2, !Self.identifiers(String(metadata[1]), numericLeadingZeros: true) { return nil }
        let parts = metadata[0].split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        let numbers = parts[0].split(separator: ".", omittingEmptySubsequences: false)
        guard (2...3).contains(numbers.count) else { return nil }
        let parsed = numbers.compactMap { part -> Int? in
            guard Self.digits(String(part)), part.count == 1 || part.first != "0" else { return nil }
            return Int(part)
        }
        guard parsed.count == numbers.count else { return nil }
        var preview: [String] = []
        if parts.count == 2 {
            guard Self.identifiers(String(parts[1]), numericLeadingZeros: false) else { return nil }
            preview = parts[1].split(separator: ".").map(String.init)
        }
        major = parsed[0]; minor = parsed[1]; patch = parsed.count == 3 ? parsed[2] : 0
        prerelease = preview
    }

    public var description: String {
        "\(major).\(minor).\(patch)" + (prerelease.isEmpty ? "" : "-" + prerelease.joined(separator: "."))
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        if lhs.patch != rhs.patch { return lhs.patch < rhs.patch }
        if lhs.prerelease.isEmpty || rhs.prerelease.isEmpty {
            return !lhs.prerelease.isEmpty && rhs.prerelease.isEmpty
        }
        for (left, right) in zip(lhs.prerelease, rhs.prerelease) where left != right {
            let ln = digits(left), rn = digits(right)
            if ln != rn { return ln }
            if ln && left.count != right.count { return left.count < right.count }
            return left < right
        }
        return lhs.prerelease.count < rhs.prerelease.count
    }

    private static func digits(_ text: String) -> Bool {
        !text.isEmpty && text.utf8.allSatisfy { (48...57).contains($0) }
    }

    private static func identifiers(_ text: String, numericLeadingZeros: Bool) -> Bool {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        return parts.allSatisfy { part in
            !part.isEmpty && part.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 }
                && (numericLeadingZeros || !digits(String(part)) || part.count == 1 || part.first != "0")
        }
    }
}
