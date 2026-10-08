import AppKit
import DropyCore

/// `Dropy animation <command>`: animation tools for the terminal and for AI coding
/// agents, run from the app's own binary before any app starts up. The running Dropy
/// is reached through distributed notifications (`AnimationRemote`).
@MainActor
enum AnimationCommand {
    static let usage = """
        Usage: \(AnimationLibrary.command) <command>

          check <file or name>                 Read an animation and list every problem, its timings and cost.
          render <file or name> [--out <png>]  Draw each motion as a filmstrip with its curves.
          play <file or name> [--slow <n>]     Play it on the notch of the running Dropy.
          new <name> [--from <style, example or file>]
                                               Write a new animation into the animations folder.
          use <name>                           Make it the active animation (rapid, balanced, smooth are built in).
          list                                 The built-in styles, the examples and your animations.
          code <file or name>                  Print a one-line share code.
          import <code> [--name <name>]        Save the animation in a share code.
          docs                                 Print the format guide.

        Animations live in \(AnimationLibrary().shownFolder).
        """

    /// Runs the command in `arguments` (after "animation") and returns the exit status.
    static func run(_ arguments: [String]) -> Int32 {
        guard let command = arguments.first else { return fail(usage, status: 2) }
        let rest = Array(arguments.dropFirst())
        let library = AnimationLibrary()
        library.prepareFolder()
        library.scan(notify: false)
        switch command {
        case "check": return check(rest, library)
        case "render": return render(rest, library)
        case "play": return play(rest, library)
        case "new": return new(rest, library)
        case "use": return use(rest, library)
        case "list": return list(library)
        case "code": return code(rest, library)
        case "import": return importCode(rest, library)
        case "docs":
            let generic = rest.contains("--generic")
            print(generic ? AnimationGuide.readme(marker: AnimationGuide.repositoryMarker)
                          : AnimationGuide.readme(folder: library.shownFolder, command: AnimationLibrary.command), terminator: "")
            return 0
        case "help", "--help", "-h":
            print(usage)
            return 0
        default:
            return fail("Unknown command “\(command)”.\n\n\(usage)", status: 2)
        }
    }

    // MARK: Commands

    private static func check(_ arguments: [String], _ library: AnimationLibrary) -> Int32 {
        guard let target = arguments.first else { return fail("Which animation? \(AnimationLibrary.command) check <file or name>", status: 2) }
        guard let found = resolve(target, library) else { return notFound(target, library) }
        let result = found.result
        let errors = result.errors.count
        let warnings = result.warnings.count
        let verdict = errors > 0 ? "cannot be used (\(count(errors, "error")))"
            : warnings > 0 ? "valid, with \(count(warnings, "warning"))" : "valid"
        print("\(found.label): \(verdict)")
        for issue in result.issues {
            print("  \(issue.severity.rawValue.padding(toLength: 8, withPad: " ", startingAt: 0))\(issue.path.isEmpty ? "" : issue.path + ": ")\(issue.message)")
        }
        if let animation = result.animation { print(summary(of: animation)) }
        return errors > 0 ? 1 : 0
    }

    private static func render(_ arguments: [String], _ library: AnimationLibrary) -> Int32 {
        guard let target = arguments.first(where: { !$0.hasPrefix("--") }) else {
            return fail("Which animation? \(AnimationLibrary.command) render <file or name> [--out <png>]", status: 2)
        }
        guard let found = resolve(target, library) else { return notFound(target, library) }
        guard let animation = found.result.animation else {
            return fail("\(found.label) has errors; run `\(AnimationLibrary.command) check \(target)` first.")
        }
        let out = option("--out", in: arguments).map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("dropy-\(AnimationLibrary.slug(animation.name)).png")
        guard let png = AnimationFilmstrip.png(for: animation) else { return fail("Could not draw the animation.") }
        do {
            try png.write(to: out, options: .atomic)
        } catch {
            return fail("Could not write \(out.path): \(error.localizedDescription)")
        }
        print(out.path)
        return 0
    }

    private static func play(_ arguments: [String], _ library: AnimationLibrary) -> Int32 {
        guard let target = arguments.first(where: { !$0.hasPrefix("--") }) else {
            return fail("Which animation? \(AnimationLibrary.command) play <file or name> [--slow <n>]", status: 2)
        }
        guard let found = resolve(target, library) else { return notFound(target, library) }
        guard let animation = found.result.animation else {
            return fail("\(found.label) has errors; run `\(AnimationLibrary.command) check \(target)` first.")
        }
        let slow = option("--slow", in: arguments).flatMap(Double.init) ?? 1
        guard AnimationRemote.dropyIsRunning else { return fail("Dropy isn't running. Open it, then try again.") }
        let reply = AnimationRemote.send(.play, payload: AnimationFile.shareCode(for: animation), slow: slow)
        guard let reply else { return fail("Dropy didn't answer. Is it this copy of Dropy that's running?") }
        print(reply)
        return 0
    }

    private static func new(_ arguments: [String], _ library: AnimationLibrary) -> Int32 {
        let words = arguments.prefix { !$0.hasPrefix("--") }
        guard !words.isEmpty else {
            return fail("Name it: \(AnimationLibrary.command) new <name> [--from <style, example or file>]", status: 2)
        }
        let name = words.joined(separator: " ")
        var animation = MotionStyle.balanced.animation
        if let from = option("--from", in: arguments) {
            guard let found = resolve(from, library) else { return notFound(from, library) }
            guard let base = found.result.animation else { return fail("\(found.label) has errors; pick another to start from.") }
            animation = base
        }
        let id = AnimationLibrary.slug(name)
        guard library.entry(id) == nil else {
            return fail("\(id).json already exists in \(library.folder.path). Pick another name, or edit that file.")
        }
        animation.name = name.contains(" ") || name != name.lowercased() ? name : AnimationLibrary.title(for: id)
        animation.summary = ""
        animation.author = ""
        do {
            print(try library.save(animation, as: id).path)
            return 0
        } catch {
            return fail("Could not write the file: \(error.localizedDescription)")
        }
    }

    private static func use(_ arguments: [String], _ library: AnimationLibrary) -> Int32 {
        guard let target = arguments.first else { return fail("Which animation? \(AnimationLibrary.command) use <name>", status: 2) }
        let id = URL(fileURLWithPath: target).deletingPathExtension().lastPathComponent
        let builtIn = MotionStyle(rawValue: id.lowercased())
        if builtIn == nil {
            guard let entry = library.entry(id) else {
                return fail("There is no \(id).json in \(library.folder.path).\(DropyAnimation.gallery.contains { $0.id == id } ? " Add the example first: \(AnimationLibrary.command) new \(id) --from \(id)" : "")")
            }
            guard entry.animation != nil else { return fail("\(id).json has errors; run `\(AnimationLibrary.command) check \(id)` first.") }
        }
        if AnimationRemote.dropyIsRunning {
            guard let reply = AnimationRemote.send(.use, payload: builtIn?.rawValue ?? id) else {
                return fail("Dropy didn't answer. Is it this copy of Dropy that's running?")
            }
            print(reply)
        } else {
            // Not running: change the saved preferences directly.
            let store = PreferenceStore()
            store.update {
                if let builtIn {
                    $0.motionStyle = builtIn
                    $0.customAnimation = nil
                } else {
                    $0.customAnimation = id
                }
            }
            print("Dropy will use \(builtIn?.title ?? library.entry(id)?.name ?? id) when it starts.")
        }
        return 0
    }

    private static func list(_ library: AnimationLibrary) -> Int32 {
        print("Built in:")
        for style in MotionStyle.allCases { print("  \(style.rawValue.padding(toLength: 16, withPad: " ", startingAt: 0))\(style.summary)") }
        print("\nExamples (start from one with --from <name>):")
        for (id, animation) in DropyAnimation.gallery { print("  \(id.padding(toLength: 16, withPad: " ", startingAt: 0))\(animation.summary)") }
        print("\nYours, in \((library.folder.path as NSString).abbreviatingWithTildeInPath):")
        if library.entries.isEmpty { print("  None yet. \(AnimationLibrary.command) new <name> makes one.") }
        for entry in library.entries {
            let state = entry.result.errors.isEmpty
                ? (entry.result.warnings.isEmpty ? "ok" : count(entry.result.warnings.count, "warning")) : "has errors"
            print("  \(entry.id.padding(toLength: 16, withPad: " ", startingAt: 0))\(entry.name) (\(state))")
        }
        return 0
    }

    private static func code(_ arguments: [String], _ library: AnimationLibrary) -> Int32 {
        guard let target = arguments.first else { return fail("Which animation? \(AnimationLibrary.command) code <file or name>", status: 2) }
        guard let found = resolve(target, library) else { return notFound(target, library) }
        guard let animation = found.result.animation else { return fail("\(found.label) has errors; fix them first.") }
        print(AnimationFile.shareCode(for: animation))
        return 0
    }

    private static func importCode(_ arguments: [String], _ library: AnimationLibrary) -> Int32 {
        guard let code = arguments.first(where: { $0.hasPrefix(AnimationFile.shareCodePrefix) }) else {
            return fail("Paste the code: \(AnimationLibrary.command) import \(AnimationFile.shareCodePrefix)… [--name <name>]", status: 2)
        }
        let result = AnimationFile.read(shareCode: code)
        guard var animation = result.animation else {
            return fail(result.errors.map(\.message).joined(separator: "\n"))
        }
        if let name = option("--name", in: arguments) { animation.name = name }
        let id = library.freeID(for: animation.name)
        do {
            print(try library.save(animation, as: id).path)
            return 0
        } catch {
            return fail("Could not write the file: \(error.localizedDescription)")
        }
    }

    // MARK: Helpers

    private struct Found {
        let label: String
        let result: AnimationReadResult
    }

    /// A file path, a name in the animations folder, a built-in style or an example.
    private static func resolve(_ target: String, _ library: AnimationLibrary) -> Found? {
        let expanded = (target as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: expanded)
        if FileManager.default.fileExists(atPath: url.path) {
            return Found(label: AnimationText.clean(url.lastPathComponent, limit: 100), result: AnimationLibrary.read(url))
        }
        let id = url.deletingPathExtension().lastPathComponent
        if let entry = library.entry(id) { return Found(label: entry.url.lastPathComponent, result: entry.result) }
        if let style = MotionStyle(rawValue: id.lowercased()) {
            return Found(label: style.title, result: AnimationReadResult(animation: style.animation, issues: []))
        }
        if let example = DropyAnimation.gallery.first(where: { $0.id == id.lowercased() }) {
            return Found(label: example.animation.name, result: AnimationReadResult(animation: example.animation, issues: []))
        }
        return nil
    }

    private static func notFound(_ target: String, _ library: AnimationLibrary) -> Int32 {
        fail("No animation called “\(target)”: not a file, nor a name in \((library.folder.path as NSString).abbreviatingWithTildeInPath), a built-in style or an example. See `\(AnimationLibrary.command) list`.")
    }

    static func summary(of animation: DropyAnimation) -> String {
        var lines: [String] = []
        for part in DropyAnimation.Part.allCases {
            let motion = animation[part]
            let extent = motion.extent
            var notes: [String] = []
            if extent.upperBound > 1.002 { notes.append("overshoots \(Int(((extent.upperBound - 1) * 100).rounded())) %") }
            if extent.lowerBound < -0.002 { notes.append("pulls back \(Int((-extent.lowerBound * 100).rounded())) %") }
            if part == .close { notes.append("forward-only") }
            let duration = String(format: "%.2f s", motion.duration)
            lines.append("  \(part.title.padding(toLength: 8, withPad: " ", startingAt: 0))\(duration)\(notes.isEmpty ? "" : "  (\(notes.joined(separator: ", ")))")")
        }
        let content = animation.content
        lines.append(String(format: "  Content  appears %.2f s in, takes %.2f s, leaves in %.2f s", content.revealDelay,
                            content.revealDuration, content.hideDuration))
        let cost = animation.cost
        lines.append("  Cost     \(cost.level.title): \(cost.reason)")
        return lines.joined(separator: "\n")
    }

    private static func option(_ name: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }

    private static func count(_ number: Int, _ noun: String) -> String { "\(number) \(noun)\(number == 1 ? "" : "s")" }

    private static func fail(_ message: String, status: Int32 = 1) -> Int32 {
        FileHandle.standardError.write(Data((message + "\n").utf8))
        return status
    }
}

/// The running Dropy and the command line talk through distributed notifications: a
/// request carries an id, and the app answers on the reply name with the same id.
enum AnimationRemote {
    enum Request: String {
        case play = "org.dropy.animation.play"
        case use = "org.dropy.animation.use"
    }

    static let reply = Notification.Name("org.dropy.animation.reply")

    @MainActor
    static var dropyIsRunning: Bool {
        NSRunningApplication.runningApplications(withBundleIdentifier: "org.dropy.app")
            .contains { $0.processIdentifier != getpid() && !$0.isTerminated }
    }

    /// Sends a request and waits up to three seconds for the answer.
    @MainActor
    static func send(_ request: Request, payload: String, slow: Double = 1) -> String? {
        final class Answer: @unchecked Sendable { var text: String? }
        let id = UUID().uuidString
        let center = DistributedNotificationCenter.default()
        let answer = Answer()
        let observer = center.addObserver(forName: reply, object: id, queue: .main) { note in
            answer.text = note.userInfo?["message"] as? String ?? "Done."
        }
        center.postNotificationName(Notification.Name(request.rawValue), object: id,
                                    userInfo: ["payload": payload, "slow": slow], deliverImmediately: true)
        let deadline = Date().addingTimeInterval(3)
        while answer.text == nil, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        center.removeObserver(observer)
        return answer.text
    }

    /// Answers a request (in the app).
    static func answer(_ id: String, _ message: String) {
        DistributedNotificationCenter.default().postNotificationName(reply, object: id, userInfo: ["message": message],
                                                                     deliverImmediately: true)
    }
}
