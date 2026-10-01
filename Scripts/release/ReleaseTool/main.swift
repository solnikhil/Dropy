// Every decision `Scripts/release/package.sh` and `Scripts/release/verify.sh` make comes
// from here, and every rule here lives in `DropyCore/ReleasePolicy` with unit tests. The
// tool reads files and prints; it signs nothing, submits nothing and launches nothing.
//
//   ReleaseTool self-test
//   ReleaseTool plan --mode <dry-run|release> [--version-file PATH] [--tag TAG] [--build N]
//                    [--identity NAME] [--notary-profile NAME] [--dirty 0|1] [--tagged 0|1]
//   ReleaseTool check-info-plist PATH --short VERSION --build BUILD
//   ReleaseTool check-entitlements PATH
//   ReleaseTool ci-plan --certificate 0|1 --identity 0|1 --notary 0|1
//   ReleaseTool rollback --withdraw VERSION@BUILD --to VERSION@BUILD [--notarized] [--checksums]
//
// `plan` prints `key=value` lines for the shell to read and exits non-zero, with the
// reason on standard error, for anything this project refuses to release.
import DropyCore
import Foundation

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func refuse(_ reason: some CustomStringConvertible) -> Never { fail("refused: \(reason)") }

/// `--flag value` pairs and `--flag` switches.
struct Options {
    private var values: [String: String] = [:]
    private var flags: Set<String> = []
    let positional: [String]

    init(_ arguments: [String], switches: Set<String> = []) {
        var positional: [String] = []
        var index = arguments.startIndex
        while index < arguments.endIndex {
            let argument = arguments[index]
            if argument.hasPrefix("--") {
                let name = String(argument.dropFirst(2))
                if switches.contains(name) {
                    flags.insert(name)
                } else {
                    let next = arguments.index(after: index)
                    guard next < arguments.endIndex else { fail("--\(name) needs a value") }
                    values[name] = arguments[next]
                    index = next
                }
            } else {
                positional.append(argument)
            }
            index = arguments.index(after: index)
        }
        self.positional = positional
    }

    /// Absent, blank and `-` all mean "not given": a shell cannot pass an absent value.
    func value(_ name: String) -> String? {
        guard let raw = values[name]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty, raw != "-" else { return nil }
        return raw
    }

    func flag(_ name: String) -> Bool { flags.contains(name) }

    /// `--name 0|1`, defaulting when absent.
    func boolean(_ name: String, default fallback: Bool) -> Bool {
        guard let raw = value(name) else { return fallback }
        switch raw {
        case "1", "true", "yes": return true
        case "0", "false", "no": return false
        default: fail("--\(name) must be 0 or 1, not \"\(raw)\"")
        }
    }

    func required(_ name: String) -> String {
        guard let raw = value(name) else { fail("--\(name) is required") }
        return raw
    }
}

/// A property list's top level as strings, the way this policy compares them.
/// Booleans become `true`/`false`; anything not scalar is reported by its type so an
/// unexpected structure cannot pass as a missing key.
func plistStrings(atPath path: String) -> [String: String] {
    guard let data = FileManager.default.contents(atPath: path) else { fail("\(path) is unreadable") }
    guard let object = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
          let dictionary = object as? [String: Any] else { fail("\(path) is not a property list dictionary") }
    return dictionary.reduce(into: [:]) { result, entry in
        result[entry.key] = describe(entry.value)
    }
}

func describe(_ value: Any) -> String {
    switch value {
    case let text as String: text
    // A plist <true/> and <integer>1</integer> both bridge to NSNumber, and Swift will
    // cast either to Bool; mistaking one for the other would compare the wrong string.
    case let number as NSNumber:
        CFGetTypeID(number) == CFBooleanGetTypeID() ? (number.boolValue ? "true" : "false") : number.stringValue
    case let date as Date: ISO8601DateFormatter().string(from: date)
    case let array as [Any]: "<array of \(array.count)>"
    case is [String: Any]: "<dictionary>"
    default: "<\(type(of: value))>"
    }
}

/// `1.2.3@184`, as the rollback policy is written down in docs/RELEASE.md.
func parseVersionAtBuild(_ raw: String, _ label: String) -> ReleaseVersion {
    let parts = raw.split(separator: "@", omittingEmptySubsequences: false)
    guard parts.count == 2 else { fail("--\(label) must be <version>@<build>, e.g. 1.2.3@184") }
    switch ReleaseVersion.resolve(file: String(parts[0]), tag: nil, build: String(parts[1])) {
    case .success(let version): return version
    case .failure(let problem): fail("--\(label): \(problem)")
    }
}

func resolveVersion(_ options: Options) -> ReleaseVersion {
    var fileText: String?
    if let path = options.value("version-file") {
        if FileManager.default.fileExists(atPath: path) {
            guard let data = FileManager.default.contents(atPath: path),
                  let text = String(data: data, encoding: .utf8) else { fail("\(path) is unreadable") }
            fileText = text
        }
    }
    switch ReleaseVersion.resolve(file: fileText, tag: options.value("tag"), build: options.value("build")) {
    case .success(let version): return version
    case .failure(let problem): refuse(problem)
    }
}

func mode(_ options: Options) -> ReleasePolicy.Mode {
    let raw = options.required("mode")
    guard let mode = ReleasePolicy.Mode(rawValue: raw) else { fail("--mode must be dry-run or release, not \"\(raw)\"") }
    return mode
}

// MARK: - Subcommands

func plan(_ options: Options) -> Never {
    let mode = mode(options)
    let version = resolveVersion(options)
    var lines = ["mode=\(mode.rawValue)", "short=\(version.release)", "bundle=\(version.build)",
                 "release=\(version.release)", "prerelease=\(version.isPrerelease ? 1 : 0)"]
    var notes: [String] = []

    switch ReleasePolicy.source(mode: mode, dirty: options.boolean("dirty", default: false),
                               tagged: options.value("tag") != nil || options.boolean("tagged", default: false)) {
    case .proceed(let allowed): notes += allowed
    case .refuse(let refusal): refuse(refusal)
    }

    switch ReleasePolicy.signing(mode: mode, identity: options.value("identity")) {
    case .adHoc(let ignored):
        lines += ["sign=adhoc", "sign_identity=-"]
        if let ignored { notes.append("DROPY_SIGN_IDENTITY (\(ignored)) is not used by a dry run; it signs ad hoc") }
    case .developerID(let name):
        lines += ["sign=developer-id", "sign_identity=\(name)"]
    case .refuse(let refusal): refuse(refusal)
    }

    switch ReleasePolicy.notarization(mode: mode, keychainProfile: options.value("notary-profile")) {
    case .skip(let reason):
        lines += ["notarize=skip", "notarize_profile=", "notarize_reason=\(reason)"]
    case .submit(let profile):
        lines += ["notarize=submit", "notarize_profile=\(profile)", "notarize_reason="]
    case .refuse(let refusal): refuse(refusal)
    }

    let artifacts = ReleasePolicy.artifacts(for: version)
    lines += ["app=\(artifacts.app)", "zip=\(artifacts.zip)", "dmg=\(artifacts.dmg)",
              "checksums=\(artifacts.checksums)", "volume=\(artifacts.volumeName)",
              // Gatekeeper accepts nothing ad hoc, so only a real release is assessed.
              "assess=\(mode == .release ? 1 : 0)"]
    for (index, note) in notes.enumerated() { lines.append("note\(index + 1)=\(note)") }
    print(lines.joined(separator: "\n"))
    exit(0)
}

func checkInfoPlist(_ options: Options) -> Never {
    guard let path = options.positional.first else { fail("check-info-plist needs an Info.plist path") }
    let expected: ReleaseVersion
    switch ReleaseVersion.resolve(file: options.required("short"), tag: nil, build: options.required("build")) {
    case .success(let version): expected = version
    case .failure(let problem): fail("expected version: \(problem)")
    }
    let problems = ReleasePolicy.infoPlistProblems(plistStrings(atPath: path), expecting: expected)
    guard problems.isEmpty else { fail(problems.map { "Info.plist: \($0)" }.joined(separator: "\n")) }
    print("Info.plist matches the release policy (\(expected.marketing), build \(expected.build))")
    exit(0)
}

func checkEntitlements(_ options: Options) -> Never {
    guard let path = options.positional.first else { fail("check-entitlements needs a plist path") }
    // codesign writes nothing when a build carries no entitlements; that is the ideal.
    let keys: [String]
    guard let data = FileManager.default.contents(atPath: path) else { fail("cannot read entitlements at \(path)") }
    if !data.isEmpty {
        guard let object = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let dictionary = object as? [String: Any] else { fail("\(path) is not an entitlements property list") }
        keys = Array(dictionary.keys)
    } else {
        keys = []
    }
    let problems = ReleasePolicy.entitlementProblems(keys)
    guard problems.isEmpty else { fail(problems.joined(separator: "\n")) }
    print("entitlements accepted (\(keys.count) present, none refused)")
    exit(0)
}

func ciPlan(_ options: Options) -> Never {
    switch ReleasePolicy.ciPlan(certificatePresent: options.boolean("certificate", default: false),
                                identityPresent: options.boolean("identity", default: false),
                                notaryCredentialsPresent: options.boolean("notary", default: false)) {
    case .dryRun(let reason):
        print("plan=dry-run\nreason=\(reason)")
    case .signAndNotarize:
        print("plan=release\nreason=")
    case .refuse(let reason):
        fail("refused: \(reason)")
    }
    exit(0)
}

func rollback(_ options: Options) -> Never {
    let withdrawn = parseVersionAtBuild(options.required("withdraw"), "withdraw")
    let target = parseVersionAtBuild(options.required("to"), "to")
    switch ReleasePolicy.rollback(withdraw: withdrawn, to: target, targetWasNotarized: options.flag("notarized"),
                                  targetChecksumsRecorded: options.flag("checksums")) {
    case .success(let plan):
        let artifacts = ReleasePolicy.artifacts(for: plan.republish)
        print("""
              withdraw=\(plan.withdrawn.marketing)@\(plan.withdrawn.build)
              republish_short=\(plan.republish.marketing)
              republish_bundle=\(plan.republish.build)
              zip=\(artifacts.zip)
              dmg=\(artifacts.dmg)
              """)
        exit(0)
    case .failure(let refusal): refuse(refusal)
    }
}

// MARK: - Self-test

/// Checks this tool's own reading and formatting. The rules themselves are checked in
/// Tests/DropyCoreTests/ReleasePolicyTests.swift.
func selfTest() -> Never {
    let options = Options(["--mode", "dry-run", "--identity", "-", "--dirty", "1", "--notarized", "extra"],
                          switches: ["notarized"])
    precondition(options.value("mode") == "dry-run")
    precondition(options.value("identity") == nil, "\"-\" means not given")
    precondition(options.boolean("dirty", default: false))
    precondition(options.boolean("tagged", default: false) == false, "an absent boolean keeps its default")
    precondition(options.flag("notarized"))
    precondition(options.flag("checksums") == false)
    precondition(options.positional == ["extra"])

    precondition(describe("text") == "text")
    precondition(describe(true) == "true")
    precondition(describe(false) == "false")
    precondition(describe(15) == "15")
    precondition(describe(1) == "1", "the integer 1 is not the boolean true")
    precondition(describe(["a"]) == "<array of 1>", "a structure is not read as a missing key")

    let work = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ReleaseToolSelfTest-\(getpid())")
    try? FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: work) }
    let plist = work.appendingPathComponent("Info.plist")
    let contents: [String: Any] = ["CFBundleIdentifier": "org.dropy.app", "LSUIElement": true,
                                   "LSMinimumSystemVersion": "15.0", "Count": 3]
    let data = try! PropertyListSerialization.data(fromPropertyList: contents, format: .xml, options: 0)
    try! data.write(to: plist)
    let read = plistStrings(atPath: plist.path)
    precondition(read["CFBundleIdentifier"] == "org.dropy.app")
    precondition(read["LSUIElement"] == "true", "a boolean is compared as true/false")
    precondition(read["Count"] == "3")
    precondition(read["Missing"] == nil)

    let version = parseVersionAtBuild("1.2.3@184", "to")
    precondition(version.marketing == "1.2.3" && version.build == "184")
    print("ReleaseTool checks passed")
    exit(0)
}

// MARK: - Entry

let arguments = Array(CommandLine.arguments.dropFirst())
guard let command = arguments.first else {
    fail("usage: ReleaseTool <self-test|plan|check-info-plist|check-entitlements|ci-plan|rollback> …")
}
let rest = Array(arguments.dropFirst())
switch command {
case "self-test": selfTest()
case "plan": plan(Options(rest))
case "check-info-plist": checkInfoPlist(Options(rest))
case "check-entitlements": checkEntitlements(Options(rest))
case "ci-plan": ciPlan(Options(rest))
case "rollback": rollback(Options(rest, switches: ["notarized", "checksums"]))
default: fail("unknown command \"\(command)\"")
}
