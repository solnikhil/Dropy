import Foundation

/// M5 release decisions, as data: which version a build carries, which signing identity
/// and notarization path each mode allows, what the artifacts are called, which
/// entitlements and Info.plist keys a release may contain, and what a rollback
/// re-publishes.
///
/// Everything here is pure. It signs nothing, submits nothing, reads no file and
/// launches no process, so every rule is unit-checked. `Scripts/release/package.sh`
/// and `Scripts/release/verify.sh` own the side effects and take every decision from
/// `Scripts/release/ReleaseTool`, which is a thin shell over this file.
public enum ReleasePolicy {
    /// A real release, or a rehearsal that must not sign with a real identity, must not
    /// submit anything to Apple and must not publish.
    public enum Mode: String, Equatable, Sendable, CaseIterable {
        case dryRun = "dry-run"
        case release
    }
}

// MARK: - Version

/// The version a release build carries in `Info.plist`.
public struct ReleaseVersion: Equatable, Sendable {
    /// Package version, including any prerelease suffix. The bundle uses `release`.
    public let marketing: String
    /// `CFBundleVersion`: a monotonic series of up to three dot-separated integers.
    public let build: String
    /// The `X.Y.Z` part of `marketing`, without any pre-release suffix.
    public let release: String
    /// `rc.1` for `1.2.3-rc.1`; nil for a final release.
    public let prerelease: String?

    public var isPrerelease: Bool { prerelease != nil }

    public init(marketing: String, build: String, release: String, prerelease: String?) {
        self.marketing = marketing
        self.build = build
        self.release = release
        self.prerelease = prerelease
    }
}

public enum ReleaseVersionProblem: Equatable, Sendable, Error, CustomStringConvertible {
    /// Neither a VERSION file nor a tag said what this build is.
    case noSource
    case malformedVersion(String)
    /// A tag must be `v` followed by the version, e.g. `v1.2.3`.
    case malformedTag(String)
    case tagDisagreesWithFile(tag: String, file: String)
    case malformedBuild(String)
    /// A pre-release and the final release that follows it share `X.Y.Z`, so a
    /// pre-release needs its own build number to stay orderable.
    case buildRequiredForPrerelease(String)

    public var description: String {
        switch self {
        case .noSource:
            "no version: write one in the VERSION file or build a v<version> tag"
        case .malformedVersion(let raw):
            "version \"\(raw)\" is not X.Y.Z or X.Y.Z-<pre-release> (no v prefix, no leading zeros)"
        case .malformedTag(let raw):
            "tag \"\(raw)\" is not v<version>, e.g. v1.2.3"
        case .tagDisagreesWithFile(let tag, let file):
            "tag \(tag) and VERSION file \(file) disagree: make them match before releasing"
        case .malformedBuild(let raw):
            "build number \"\(raw)\" is not one to three positive dot-separated integers"
        case .buildRequiredForPrerelease(let marketing):
            "pre-release \(marketing) needs an explicit build number (git commit count in CI)"
        }
    }
}

extension ReleaseVersion {
    /// Resolves the version to stamp into `Info.plist`.
    ///
    /// - Parameters:
    ///   - file: the VERSION file's contents, which holds the number alone (`1.2.3`).
    ///   - tag: the tag being released, which carries the `v` prefix (`v1.2.3`).
    ///   - build: an explicit `CFBundleVersion`; when absent the `X.Y.Z` triple is used,
    ///     which is monotonic for final releases but cannot order a pre-release.
    ///
    /// A tag and a VERSION file must agree: a tag that quietly shipped a different
    /// number than the checked-in file would make the release unreproducible.
    public static func resolve(file: String?, tag: String?,
                              build: String?) -> Result<ReleaseVersion, ReleaseVersionProblem> {
        let fileText = present(file)
        let tagText = present(tag)
        var fromFile: (release: String, prerelease: String?, marketing: String)?
        if let fileText {
            guard let parsed = parse(fileText) else { return .failure(.malformedVersion(fileText)) }
            fromFile = parsed
        }
        var fromTag: (release: String, prerelease: String?, marketing: String)?
        if let tagText {
            guard tagText.hasPrefix("v"), let parsed = parse(String(tagText.dropFirst())) else {
                return .failure(.malformedTag(tagText))
            }
            fromTag = parsed
        }
        let resolved: (release: String, prerelease: String?, marketing: String)
        switch (fromFile, fromTag) {
        case (nil, nil): return .failure(.noSource)
        case (let some?, nil): resolved = some
        case (nil, let some?): resolved = some
        case (let file?, let tag?):
            guard file.marketing == tag.marketing else {
                return .failure(.tagDisagreesWithFile(tag: "v" + tag.marketing, file: file.marketing))
            }
            resolved = file
        }
        let buildText = present(build)
        let bundleVersion: String
        if let buildText {
            guard isValidBuild(buildText) else { return .failure(.malformedBuild(buildText)) }
            bundleVersion = buildText
        } else {
            guard resolved.prerelease == nil else {
                return .failure(.buildRequiredForPrerelease(resolved.marketing))
            }
            bundleVersion = resolved.release
        }
        return .success(ReleaseVersion(marketing: resolved.marketing, build: bundleVersion,
                                       release: resolved.release, prerelease: resolved.prerelease))
    }

    /// Trimmed text, or nil when absent, blank, or the `-` the release tool passes for
    /// "not given" (a shell cannot pass an absent argument apart from an empty one).
    private static func present(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty, trimmed != "-" else { return nil }
        return trimmed
    }

    /// `X.Y.Z` with an optional `-<pre-release>` suffix. Exactly three release
    /// components: `1.2` and `1.2.3.4` are refused rather than guessed at.
    private static func parse(_ raw: String) -> (release: String, prerelease: String?, marketing: String)? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-") })
        else { return nil }
        let releaseText: String
        var prerelease: String?
        if let dash = trimmed.firstIndex(of: "-") {
            releaseText = String(trimmed[trimmed.startIndex..<dash])
            let suffix = String(trimmed[trimmed.index(after: dash)...])
            guard isValidPrerelease(suffix) else { return nil }
            prerelease = suffix
        } else {
            releaseText = trimmed
        }
        let components = releaseText.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count == 3, components.allSatisfy({ isPlainNumber(String($0)) }) else { return nil }
        return (releaseText, prerelease, trimmed)
    }

    /// Dot-separated identifiers: digits (no leading zeros) or ASCII alphanumerics.
    private static func isValidPrerelease(_ raw: String) -> Bool {
        let parts = raw.split(separator: ".", omittingEmptySubsequences: false)
        guard !parts.isEmpty else { return false }
        return parts.allSatisfy { part in
            let text = String(part)
            guard !text.isEmpty, text.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else { return false }
            return text.allSatisfy(\.isNumber) ? isPlainNumber(text) : true
        }
    }

    /// A non-negative integer of at most five digits with no leading zeros.
    private static func isPlainNumber(_ text: String) -> Bool {
        guard !text.isEmpty, text.count <= 5, text.allSatisfy(\.isNumber), text.allSatisfy(\.isASCII) else { return false }
        return text == "0" || !text.hasPrefix("0")
    }

    /// One to three dot-separated integers, not all zero: what `CFBundleVersion` allows.
    public static func isValidBuild(_ raw: String) -> Bool {
        let parts = raw.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count), parts.allSatisfy({ isPlainNumber(String($0)) }) else { return false }
        return parts.contains { $0 != "0" }
    }

    /// Compares `CFBundleVersion` strings the way an update feed must order them.
    public static func compareBuilds(_ lhs: String, _ rhs: String) -> ComparisonResult {
        func padded(_ raw: String) -> [Int] {
            var numbers = raw.split(separator: ".").map { Int($0) ?? 0 }
            while numbers.count < 3 { numbers.append(0) }
            return numbers
        }
        let (left, right) = (padded(lhs), padded(rhs))
        for (a, b) in zip(left, right) where a != b { return a < b ? .orderedAscending : .orderedDescending }
        return .orderedSame
    }

    /// Release order: the `X.Y.Z` triple, then a pre-release before the final release it
    /// leads to (`1.2.0-rc.1` < `1.2.0`), by the usual identifier rules.
    public static func compare(_ lhs: ReleaseVersion, _ rhs: ReleaseVersion) -> ComparisonResult {
        let triple = compareBuilds(lhs.release, rhs.release)
        if triple != .orderedSame { return triple }
        switch (lhs.prerelease, rhs.prerelease) {
        case (nil, nil): return .orderedSame
        case (nil, _?): return .orderedDescending
        case (_?, nil): return .orderedAscending
        case (let left?, let right?): return comparePrereleases(left, right)
        }
    }

    private static func comparePrereleases(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let left = lhs.split(separator: "."), right = rhs.split(separator: ".")
        for (a, b) in zip(left, right) {
            if a == b { continue }
            switch (Int(a), Int(b)) {
            case (let x?, let y?): return x < y ? .orderedAscending : .orderedDescending
            case (_?, nil): return .orderedAscending // a number sorts before an identifier
            case (nil, _?): return .orderedDescending
            case (nil, nil): return a < b ? .orderedAscending : .orderedDescending
            }
        }
        if left.count == right.count { return .orderedSame }
        return left.count < right.count ? .orderedAscending : .orderedDescending
    }
}

// MARK: - Signing

/// What a `DROPY_SIGN_IDENTITY` value is, judged from its name. A certificate named by
/// SHA-1 hash cannot be judged, so it is not recognised: naming the identity in full is
/// what makes the refusals below enforceable.
public enum SigningIdentityClass: Equatable, Sendable {
    case absent
    /// `-`: a signature with no identity, valid only for local builds.
    case adHoc
    /// `Developer ID Application`: the only kind that may sign a released Dropy.
    case developerIDApplication
    /// `Apple Development` or `Mac Developer`: a debugging identity. Never released.
    case appleDevelopment
    /// A certificate that cannot sign a directly distributed app: `Developer ID
    /// Installer`, `Apple Distribution`, `3rd Party Mac Developer`.
    case wrongCertificateType
    /// A hash, an empty-looking name, or anything else unjudgeable.
    case unrecognized
}

public enum SigningDecision: Equatable, Sendable {
    /// Sign with no identity. `ignoring` names a real identity the environment offered
    /// that a rehearsal deliberately did not use.
    case adHoc(ignoring: String?)
    case developerID(String)
    case refuse(SigningRefusal)
}

public enum SigningRefusal: Equatable, Sendable, CustomStringConvertible {
    /// Refused in every mode, including a rehearsal: an `Apple Development` build is
    /// signed for debugging (it carries `get-task-allow`), cannot be notarized, and
    /// must never be the thing a person installs.
    case appleDevelopmentIdentity(String)
    case wrongCertificateType(String)
    case unnamedIdentity(String)
    case missingIdentity
    case adHocRelease

    public var description: String {
        switch self {
        case .appleDevelopmentIdentity(let name):
            "DROPY_SIGN_IDENTITY names a development identity (\(name)); a release is signed only with a Developer ID Application certificate"
        case .wrongCertificateType(let name):
            "DROPY_SIGN_IDENTITY names a certificate that cannot sign a directly distributed app (\(name)); use Developer ID Application"
        case .unnamedIdentity(let name):
            "DROPY_SIGN_IDENTITY \"\(name)\" is not a recognisable certificate name; name it in full (a hash cannot be checked against this policy)"
        case .missingIdentity:
            "a release needs DROPY_SIGN_IDENTITY set to a Developer ID Application certificate, or --dry-run"
        case .adHocRelease:
            "an ad-hoc signature (-) cannot be released: Gatekeeper and notarization both refuse it"
        }
    }
}

extension ReleasePolicy {
    public static func classify(identity raw: String?) -> SigningIdentityClass {
        guard let raw else { return .absent }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return .absent }
        if trimmed == "-" { return .adHoc }
        // A value that would be passed to codesign must be a single clean line.
        if trimmed.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) { return .unrecognized }
        if trimmed.hasPrefix("Apple Development") || trimmed.hasPrefix("Mac Developer") { return .appleDevelopment }
        if trimmed.hasPrefix("Developer ID Application") { return .developerIDApplication }
        if trimmed.hasPrefix("Developer ID Installer") || trimmed.hasPrefix("Apple Distribution")
            || trimmed.hasPrefix("3rd Party Mac Developer") { return .wrongCertificateType }
        return .unrecognized
    }

    /// The signing rule for each mode. A rehearsal always signs ad hoc, so it can never
    /// consume a real identity by accident; a development identity is still refused
    /// outright, because a rehearsal exists to catch exactly that misconfiguration
    /// before the real run.
    public static func signing(mode: Mode, identity raw: String?) -> SigningDecision {
        let name = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        switch classify(identity: raw) {
        case .appleDevelopment: return .refuse(.appleDevelopmentIdentity(name))
        case .wrongCertificateType: return .refuse(.wrongCertificateType(name))
        case .unrecognized: return .refuse(.unnamedIdentity(name))
        case .absent: return mode == .dryRun ? .adHoc(ignoring: nil) : .refuse(.missingIdentity)
        case .adHoc: return mode == .dryRun ? .adHoc(ignoring: nil) : .refuse(.adHocRelease)
        case .developerIDApplication: return mode == .dryRun ? .adHoc(ignoring: name) : .developerID(name)
        }
    }
}

// MARK: - Notarization

public enum NotarizationDecision: Equatable, Sendable {
    /// Skipped, with the reason to print. A rehearsal never submits anything to Apple.
    case skip(reason: String)
    /// `xcrun notarytool submit --keychain-profile <profile> --wait`, then staple.
    case submit(profile: String)
    case refuse(NotarizationRefusal)
}

public enum NotarizationRefusal: Equatable, Sendable, CustomStringConvertible {
    case missingProfile
    case malformedProfile(String)

    public var description: String {
        switch self {
        case .missingProfile:
            "a release must be notarized: set DROPY_NOTARY_PROFILE to a notarytool keychain profile, or --dry-run"
        case .malformedProfile(let name):
            "DROPY_NOTARY_PROFILE \"\(name)\" is not a single-line profile name"
        }
    }
}

extension ReleasePolicy {
    public static func notarization(mode: Mode, keychainProfile raw: String?) -> NotarizationDecision {
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if mode == .dryRun {
            return .skip(reason: trimmed.isEmpty ? "dry run"
                                 : "dry run (DROPY_NOTARY_PROFILE set; nothing is submitted to Apple)")
        }
        if trimmed.isEmpty { return .refuse(.missingProfile) }
        guard let raw, raw.unicodeScalars.allSatisfy({ $0.properties.generalCategory != .control }) else {
            return .refuse(.malformedProfile(trimmed))
        }
        return .submit(profile: trimmed)
    }
}

// MARK: - Source state

public enum SourceStateDecision: Equatable, Sendable {
    /// Proceed; `notes` are rehearsal-only allowances worth printing.
    case proceed(notes: [String])
    case refuse(SourceRefusal)
}

public enum SourceRefusal: Equatable, Sendable, CustomStringConvertible {
    case uncommittedChanges
    case untaggedRelease

    public var description: String {
        switch self {
        case .uncommittedChanges:
            "the working tree has uncommitted changes: a release must be reproducible from a commit"
        case .untaggedRelease:
            "a release must build a v<version> tag so the artifacts can be traced back"
        }
    }
}

extension ReleasePolicy {
    /// A real release comes from a clean, tagged commit. A rehearsal may run from a
    /// dirty, untagged tree — that is what it is for — and says so.
    public static func source(mode: Mode, dirty: Bool, tagged: Bool) -> SourceStateDecision {
        if mode == .release {
            if dirty { return .refuse(.uncommittedChanges) }
            if !tagged { return .refuse(.untaggedRelease) }
            return .proceed(notes: [])
        }
        var notes: [String] = []
        if dirty { notes.append("working tree is dirty (allowed in a dry run, refused in a release)") }
        if !tagged { notes.append("HEAD carries no v<version> tag (allowed in a dry run, refused in a release)") }
        return .proceed(notes: notes)
    }
}

// MARK: - Artifacts

public struct ReleaseArtifacts: Equatable, Sendable {
    public let app: String
    /// `Dropy-1.2.3.zip`: no `v` prefix and no spaces, so a download URL needs no escaping.
    public let zip: String
    public let dmg: String
    /// One manifest `shasum -a 256 -c` can check.
    public let checksums: String
    /// The mounted volume's name; HFS+ allows 27 characters.
    public let volumeName: String

    public var all: [String] { [zip, dmg, checksums] }
}

extension ReleasePolicy {
    public static let productName = "Dropy"
    public static let bundleIdentifier = "org.dropy.app"

    public static func artifacts(for version: ReleaseVersion) -> ReleaseArtifacts {
        let stem = "\(productName)-\(version.marketing)"
        // HFS+ allows 27 characters, so a long pre-release name falls back to the
        // release triple rather than being cut mid-identifier.
        var volume = "\(productName) \(version.marketing)"
        if volume.count > 27 { volume = "\(productName) \(version.release)" }
        if volume.count > 27 { volume = productName }
        return ReleaseArtifacts(app: "\(productName).app", zip: "\(stem).zip", dmg: "\(stem).dmg",
                                checksums: "SHA256SUMS", volumeName: volume)
    }
}

// MARK: - Continuous integration

public enum CIReleaseDecision: Equatable, Sendable {
    /// No release credentials: rehearse the package and publish nothing.
    case dryRun(reason: String)
    case signAndNotarize
    /// Half-configured credentials are a mistake, not a reason to downgrade silently.
    case refuse(String)
}

extension ReleasePolicy {
    /// What a tag build may do with the secrets it can see. A fork or a clean checkout
    /// has none, and must still finish green by rehearsing.
    public static func ciPlan(certificatePresent: Bool, identityPresent: Bool,
                              notaryCredentialsPresent: Bool) -> CIReleaseDecision {
        let present = [certificatePresent, identityPresent, notaryCredentialsPresent]
        if present.allSatisfy({ !$0 }) {
            return .dryRun(reason: "no release secrets are configured; packaging was rehearsed and nothing was published")
        }
        if present.allSatisfy({ $0 }) { return .signAndNotarize }
        let missing = [certificatePresent ? nil : "DROPY_SIGN_CERT_P12_BASE64",
                       identityPresent ? nil : "DROPY_SIGN_IDENTITY",
                       notaryCredentialsPresent ? nil : "DROPY_NOTARY_* credentials"].compactMap { $0 }
        return .refuse("release secrets are partly configured; missing: \(missing.joined(separator: ", "))")
    }
}

// MARK: - Rollback

public struct RollbackPlan: Equatable, Sendable {
    /// The withdrawn release.
    public let withdrawn: ReleaseVersion
    /// What to publish instead: the trusted marketing version, with a build number
    /// above the withdrawn one so every update feed and macOS itself treat it as newer.
    public let republish: ReleaseVersion
}

public enum RollbackRefusal: Error, Equatable, Sendable, CustomStringConvertible {
    case targetNotOlder
    case targetNotNotarized
    case targetChecksumsMissing
    case buildNumberExhausted

    public var description: String {
        switch self {
        case .targetNotOlder:
            "the rollback target must be older than the release being withdrawn"
        case .targetNotNotarized:
            "the rollback target was never notarized, so it cannot be re-published"
        case .buildNumberExhausted:
            "no higher valid build number remains; choose a new build-number scheme before rollback"
        case .targetChecksumsMissing:
            "the rollback target has no recorded SHA-256 checksums, so the bits cannot be shown to be the ones that were tested"
        }
    }
}

extension ReleasePolicy {
    /// Re-publishing an older build is the rollback, and it needs a *higher* build
    /// number than the release it replaces: `CFBundleVersion` is what orders builds, so
    /// shipping the old number again would leave installs on the withdrawn version.
    public static func rollback(withdraw withdrawn: ReleaseVersion, to target: ReleaseVersion,
                                targetWasNotarized: Bool,
                                targetChecksumsRecorded: Bool) -> Result<RollbackPlan, RollbackRefusal> {
        guard ReleaseVersion.compare(target, withdrawn) == .orderedAscending else { return .failure(.targetNotOlder) }
        guard targetWasNotarized else { return .failure(.targetNotNotarized) }
        guard targetChecksumsRecorded else { return .failure(.targetChecksumsMissing) }
        let highest = ReleaseVersion.compareBuilds(withdrawn.build, target.build) == .orderedAscending
            ? target.build : withdrawn.build
        guard let next = bumped(highest) else { return .failure(.buildNumberExhausted) }
        let republish = ReleaseVersion(marketing: target.marketing, build: next,
                                       release: target.release, prerelease: target.prerelease)
        return .success(RollbackPlan(withdrawn: withdrawn, republish: republish))
    }

    /// Carry within the same component count so every result remains a valid build.
    static func bumped(_ build: String) -> String? {
        var parts = build.split(separator: ".").compactMap { Int($0) }
        guard !parts.isEmpty else { return nil }
        for index in parts.indices.reversed() {
            if parts[index] < 99999 {
                parts[index] += 1
                return parts.map(String.init).joined(separator: ".")
            }
            parts[index] = 0
        }
        return nil
    }
}

// MARK: - Bundle contents policy

extension ReleasePolicy {
    /// Entitlements a Dropy release must never carry, with the reason, checked against
    /// what is actually embedded in the signature. Dropy needs none of these: it
    /// captures with ScreenCaptureKit and (for M3 routes) Accessibility, both of which
    /// are TCC permissions a person grants, not entitlements.
    public static let refusedEntitlements: [String: String] = [
        "com.apple.security.get-task-allow":
            "lets any process attach to Dropy and read captured pixels; added by development signing",
        "com.apple.security.cs.debugger":
            "lets Dropy attach to other processes",
        "com.apple.security.cs.disable-library-validation":
            "lets unsigned code load into a process that can see other apps' windows",
        "com.apple.security.cs.allow-unsigned-executable-memory":
            "defeats the hardened runtime's code-integrity guarantee",
        "com.apple.security.cs.allow-jit":
            "Dropy compiles nothing at runtime",
        "com.apple.security.cs.allow-dyld-environment-variables":
            "lets the environment inject libraries into Dropy",
        "com.apple.security.cs.disable-executable-page-protection":
            "removes page protection from a process holding captured content",
        "com.apple.security.automation.apple-events":
            "Dropy drives no other app through Apple events",
        "com.apple.security.network.client":
            "Dropy makes no outbound connections; captured content must stay on the device",
        "com.apple.security.network.server":
            "Dropy listens on no port",
        "com.apple.security.device.camera": "Dropy uses no camera",
        "com.apple.security.device.audio-input": "Dropy uses no microphone",
        "com.apple.security.personal-information.location": "Dropy uses no location",
        "com.apple.security.personal-information.addressbook": "Dropy reads no contacts",
        "com.apple.security.personal-information.calendars": "Dropy reads no calendars",
        "com.apple.security.personal-information.photos-library": "Dropy reads no photos",
    ]

    /// Problems with the entitlement keys embedded in a signed build.
    public static func entitlementProblems(_ keys: [String]) -> [String] {
        keys.sorted().compactMap { key in
            guard let why = refusedEntitlements[key] else { return nil }
            return "refused entitlement \(key): \(why)"
        }
    }

    /// The only `*UsageDescription`/`*Description` purpose string a Dropy release
    /// declares. A new one means a new kind of personal data, which is a privacy
    /// review, not a packaging detail.
    public static let allowedPurposeStringKeys: Set<String> = ["NSScreenCaptureDescription"]

    /// Info.plist requirements for a release build: the identity of the app, the
    /// menu-bar-only presentation it depends on, the floor macOS version, and the
    /// version stamped by this run.
    public static func infoPlistProblems(_ values: [String: String], expecting version: ReleaseVersion) -> [String] {
        var problems: [String] = []
        func expect(_ key: String, _ wanted: String) {
            let found = values[key]
            if found != wanted { problems.append("\(key) is \(found.map { "\"\($0)\"" } ?? "missing"), expected \"\(wanted)\"") }
        }
        expect("CFBundleIdentifier", bundleIdentifier)
        expect("CFBundleName", productName)
        expect("CFBundleExecutable", productName)
        expect("CFBundlePackageType", "APPL")
        expect("LSUIElement", "true")
        expect("CFBundleShortVersionString", version.release)
        expect("CFBundleVersion", version.build)
        if let minimum = values["LSMinimumSystemVersion"] {
            if ReleaseVersion.compareBuilds(minimum, "15.0") == .orderedAscending {
                problems.append("LSMinimumSystemVersion \(minimum) is below the supported floor 15.0")
            }
        } else {
            problems.append("LSMinimumSystemVersion is missing")
        }
        if values["NSScreenCaptureDescription"]?.isEmpty ?? true {
            problems.append("NSScreenCaptureDescription is missing: a person must be told what is captured")
        }
        for key in values.keys.sorted()
        where (key.hasSuffix("UsageDescription") || key.hasSuffix("Description")) && !allowedPurposeStringKeys.contains(key) {
            problems.append("unreviewed purpose string \(key): a new kind of personal data needs a privacy review")
        }
        return problems
    }
}
