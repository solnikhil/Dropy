// Turns InputProbe results into the input evidence Dropy ships (Resources/InputEvidence.json).
//
//   EvidenceTool <out.json> <bundle-id> <app-version|-> <report-path> <results.jsonl>[@target] [<bundle-id> ...]
//
// `@pressable` or `@text` names the element class that file's clicks were aimed at (a
// button, or caret placement in text), for records that do not carry "target".
//
// Only records written by a probe that recorded side effects ("sideEffectsRecorded": true)
// are accepted; older records cannot prove that nothing else changed. Setup failures
// (notRun, setup mismatches) are not trials. Any other non-pass outcome counts as a
// failure, so it can never help a route become verified.
import DropyCore
import Foundation

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

let routes: [String: InputRoute] = ["ax": .accessibility, "pidWindow": .windowTargetedEvent, "pid": .processEvent,
                                    "activate": .activateAndPost]
// Probe-only text candidates (axValue, axFocus) have no InputRoute and never become
// shipped evidence; promoting one needs a router implementation and a model change.
let kinds: [String: InputKind] = ["type": .text, "click": .pointerClick, "scroll": .scroll, "shortcut": .keyShortcut]
let focusStates: [String: FocusState] = ["aKey": .targetKey, "bKey": .otherWindowKey, "appInactive": .appInactive]

/// Nil for records that are not trials.
/// `clickTarget` is the element class a results file aimed its clicks at, when its records
/// do not say (`<results.jsonl>@pressable`, `@text`).
func trial(_ record: [String: Any], clickTarget: InputTargetClass? = nil) -> InputTrial? {
    guard record["sideEffectsRecorded"] as? Bool == true,
          let route = (record["route"] as? String).flatMap({ routes[$0] }),
          let kind = (record["action"] as? String).flatMap({ kinds[$0] }),
          let condition = (record["condition"] as? String).flatMap(SourceCondition.init(rawValue:)),
          let focus = (record["focus"] as? String).flatMap({ focusStates[$0] }),
          let raw = record["outcome"] as? String else { return nil }
    let outcome: InputTrial.Outcome
    let error = record["actionError"] as? String ?? ""
    if raw.hasPrefix("notRun") || error.contains("setup") || raw.contains("setup") { return nil }
    if raw == "pass" { outcome = .pass }
    else if raw.hasPrefix("wrongWindow") { outcome = .wrongWindow }
    else if raw.hasPrefix("notApplicable") { outcome = .notApplicable }
    else { outcome = .noEffect } // noEffect, notSent, noState, unsafeModifiers, …
    var effects: Set<InputSideEffect> = []
    if record["keyWindowChanged"] != nil { effects.insert(.sourceKeyWindow) }
    if record["frontmostChanged"] != nil { effects.insert(.frontmostApp) }
    if record["desktopChanged"] != nil { effects.insert(.desktop) }
    if record["pointerMoved"] != nil { effects.insert(.pointer) }
    if let changes = record["focusChanges"] as? [String] {
        if changes.contains("becameKey") { effects.insert(.sourceKeyWindow) }
        if changes.contains("appActive") || changes.contains("appInactive") { effects.insert(.frontmostApp) }
    } else if record["focusChangedDuringTrial"] != nil {
        effects.insert(.unclassifiedFocusChange)
    }
    if route == .activateAndPost { effects.insert(.pointer) }
    let target = (record["target"] as? String).flatMap(InputTargetClass.init(rawValue:))
        ?? (kind == .pointerClick ? clickTarget : nil)
    return InputTrial(route: route, kind: kind, condition: condition, focus: focus, outcome: outcome, sideEffects: effects,
                      target: target)
}

let args = Array(CommandLine.arguments.dropFirst())
if args == ["self-test"] {
    func record(_ extra: [String: Any]) -> [String: Any] {
        ["route": "pidWindow", "action": "click", "condition": "parked", "focus": "bKey", "outcome": "pass",
         "sideEffectsRecorded": true].merging(extra) { $1 }
    }
    precondition(trial(record(["sideEffectsRecorded": false])) == nil, "old records are not evidence")
    precondition(trial(record(["outcome": "notRun(setupFocusMismatch)"])) == nil, "setup failures are not trials")
    precondition(trial(record(["outcome": "wrongWindow(delivered)"]))?.outcome == .wrongWindow)
    precondition(trial(record(["outcome": "notSent(axError(-25200))"]))?.outcome == .noEffect)
    precondition(trial(record(["outcome": "unsafeModifiers"]))?.outcome == .noEffect)
    precondition(trial(record(["outcome": "partialEffect(noInputEvent)"]))?.outcome == .noEffect, "a partial edit is not a pass")
    precondition(trial(record(["route": "axValue", "action": "type"])) == nil, "candidate routes are not evidence")
    precondition(trial(record([:]), clickTarget: .pressable)?.target == .pressable, "a file's click target applies to clicks")
    precondition(trial(record(["action": "scroll"]), clickTarget: .pressable)?.target == nil, "only clicks carry a target")
    precondition(trial(record(["target": "text"]), clickTarget: .pressable)?.target == .text, "a record's own target wins")
    precondition(trial(record(["focusChanges": ["becameKey"]]))?.sideEffects == [.sourceKeyWindow])
    precondition(trial(record(["focusChanges": ["appActive", "becameKey"]]))?.sideEffects == [.sourceKeyWindow, .frontmostApp])
    precondition(trial(record(["focusChangedDuringTrial": true]))?.sideEffects == [.unclassifiedFocusChange])
    precondition(trial(record(["desktopChanged": "1→4", "route": "activate"]))?.sideEffects == [.desktop, .pointer])
    precondition(trial(record(["pointerMoved": "10,10→20,20"]))?.sideEffects == [.pointer], "a moved pointer is a side effect")
    precondition(trial(record(["outcome": "unsafeSessionState", "buttonsLeftHeld": ["left"]]))?.outcome == .noEffect)
    precondition(trial(record(["focus": "appInactive", "route": "ax", "action": "type"])) ==
                 InputTrial(route: .accessibility, kind: .text, condition: .parked, focus: .appInactive, outcome: .pass,
                            sideEffects: []))
    print("EvidenceTool mapping checks passed")
    exit(0)
}
if args.count == 2, args[0] == "policy" {
    // The shipped M3 policy, as docs/COMPATIBILITY.md states it. Fails if regenerated
    // evidence would silently enable a workflow the contract says is refused.
    guard let data = FileManager.default.contents(atPath: args[1]),
          let evidence = try? JSONDecoder().decode(InputEvidence.self, from: data) else { fail("\(args[1]) unreadable") }
    let major = evidence.macOSMajor
    var problems: [String] = []
    // The version each app was tested at; the contract is per app version.
    func version(_ bundle: String) -> String? { evidence.sources.first { $0.bundleIdentifier == bundle }?.appVersion }
    func expect(_ bundle: String, _ condition: SourceCondition, kinds: Set<InputKind>, clickTargets: Set<InputTargetClass>) {
        let caps = evidence.capabilities(for: bundle, appVersion: version(bundle), macOSMajor: major)
        let got = caps.verifiedKinds(in: condition, policy: .preview)
        if got != kinds { problems.append("\(bundle) \(condition.rawValue): kinds \(got.map(\.rawValue).sorted()) != \(kinds.map(\.rawValue).sorted())") }
        let targets = caps.verifiedTargets(.pointerClick, in: condition, policy: .preview)
        if targets != clickTargets { problems.append("\(bundle) \(condition.rawValue): click targets \(targets.map(\.rawValue).sorted()) != \(clickTargets.map(\.rawValue).sorted())") }
    }
    let all = Set(InputTargetClass.allCases)
    // Never enabled anywhere: keyboard shortcuts, drag, IME, context menus.
    for source in evidence.sources {
        for condition in SourceCondition.allCases {
            let kinds = evidence.capabilities(for: source.bundleIdentifier, appVersion: source.appVersion, macOSMajor: major)
                .verifiedKinds(in: condition, policy: .preview)
            let forbidden = kinds.intersection([.keyShortcut, .drag, .imeComposition, .contextMenu])
            if !forbidden.isEmpty { problems.append("\(source.bundleIdentifier) \(condition.rawValue): refused kinds enabled \(forbidden)") }
            // A hidden app is refused for every app (the contract's "cannot be safely targeted").
            if condition == .hidden, !kinds.isEmpty { problems.append("\(source.bundleIdentifier) hidden: \(kinds.map(\.rawValue).sorted()) enabled") }
            // Typing only where an app reports a real caret for a non-key window (AppKit).
            if kinds.contains(.text), !["com.apple.TextEdit", "org.dropy.inputfixture"].contains(source.bundleIdentifier) {
                problems.append("\(source.bundleIdentifier) \(condition.rawValue): typing enabled")
            }
        }
    }
    for condition in [SourceCondition.visible, .parked] {
        expect("com.apple.TextEdit", condition, kinds: [.pointerClick, .scroll, .text], clickTargets: [.text])
        expect("com.apple.Safari", condition, kinds: [.pointerClick, .scroll], clickTargets: [.pressable])
        expect("org.dropy.electronfixture", condition, kinds: [.pointerClick, .scroll], clickTargets: [.pressable])
    }
    expect("com.apple.Safari", .covered, kinds: [.pointerClick], clickTargets: [.pressable])
    expect("com.apple.Safari", .minimized, kinds: [.pointerClick], clickTargets: [.pressable])
    expect("com.apple.Safari", .otherSpace, kinds: [], clickTargets: [])
    expect("org.dropy.electronfixture", .otherSpace, kinds: [.pointerClick], clickTargets: [.pressable])
    for condition in SourceCondition.allCases {
        expect("com.microsoft.VSCode", condition, kinds: [], clickTargets: [])
        expect("com.apple.QuickTimePlayerX", condition, kinds: [], clickTargets: [])
        expect("org.dropy.inputfixture", .hidden, kinds: [], clickTargets: [])
    }
    expect("org.dropy.inputfixture", .visible, kinds: [.pointerClick, .scroll, .text], clickTargets: all)
    // Every source must name the app version it was tested at, or it grants nothing.
    for source in evidence.sources where (source.appVersion ?? "").isEmpty {
        problems.append("\(source.bundleIdentifier) (\(source.report)): no app version recorded")
    }
    // One app version must never be granted by another version's evidence.
    for source in evidence.sources {
        let other = (source.appVersion ?? "") + ".untested"
        if !evidence.capabilities(for: source.bundleIdentifier, appVersion: other, macOSMajor: major)
            .verifiedKinds(in: .visible, policy: .preview).isEmpty {
            problems.append("\(source.bundleIdentifier): an untested version inherits capabilities")
        }
    }
    if !evidence.requiresManualAccessibility(for: "org.dropy.electronfixture", appVersion: version("org.dropy.electronfixture"),
                                             macOSMajor: major) {
        problems.append("Electron evidence must require AXManualAccessibility")
    }
    guard problems.isEmpty else { fail("Shipped input policy differs from the M3 contract:\n" + problems.joined(separator: "\n")) }
    print("Shipped input policy matches the M3 contract")
    exit(0)
}
if args.count == 2, args[0] == "validate" {
    guard let data = FileManager.default.contents(atPath: args[1]),
          let evidence = try? JSONDecoder().decode(InputEvidence.self, from: data),
          evidence.format == InputEvidence.currentFormat else { fail("\(args[1]) is not valid input evidence") }
    print("Input evidence valid: \(evidence.sources.map { "\($0.bundleIdentifier)=\($0.trials.count)" }.joined(separator: " "))")
    exit(0)
}
guard args.count >= 5, (args.count - 1) % 4 == 0 else {
    fail("usage: EvidenceTool <out.json> <bundle-id> <app-version|-> <report> <results.jsonl> ...")
}
var sources: [InputEvidence.Source] = []
var skipped = 0
for index in stride(from: 1, to: args.count, by: 4) {
    let spec = args[index + 3].split(separator: "@", maxSplits: 1).map(String.init)
    let path = spec[0]
    var clickTarget: InputTargetClass?
    if spec.count == 2 {
        guard let parsed = InputTargetClass(rawValue: spec[1]) else { fail("unknown click target \(spec[1])") }
        clickTarget = parsed
    }
    guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { fail("cannot read \(path)") }
    let records = text.split(separator: "\n").compactMap {
        try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
    }
    let trials = records.compactMap { trial($0, clickTarget: clickTarget) }
    skipped += records.count - trials.count
    guard !trials.isEmpty else { fail("\(path): no trials with recorded side effects") }
    // Trials that ran with AXManualAccessibility on are only valid when Dropy does the same.
    let manual = records.contains { $0["axManualAccessibility"] as? Bool == true }
    sources.append(.init(bundleIdentifier: args[index], appVersion: args[index + 1] == "-" ? nil : args[index + 1],
                         report: args[index + 2], trials: trials, requiresManualAccessibility: manual ? true : nil))
}
let version = ProcessInfo.processInfo.operatingSystemVersion
let macOS = "\(version.majorVersion).\(version.minorVersion)"
let evidence = InputEvidence(macOS: macOS, macOSMajor: version.majorVersion, sources: sources)
let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
try encoder.encode(evidence).write(to: URL(fileURLWithPath: args[0]))
for source in sources {
    let capabilities = InputCapabilities(trials: source.trials)
    for condition in SourceCondition.allCases {
        let support = InputPlanner.support(in: condition, capabilities: capabilities, policy: .preview)
        if case .interactive(let kinds) = support {
            print(source.bundleIdentifier, condition.rawValue, kinds.map(\.rawValue).sorted().joined(separator: ","))
        }
    }
}
print("wrote \(args[0]): \(sources.map { "\($0.bundleIdentifier)=\($0.trials.count)" }.joined(separator: " ")) skipped=\(skipped)")
