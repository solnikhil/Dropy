import Foundation

/// Parse options before interpreting targets so option values cannot become file names.
/// The same grammar is used by every animation command, independent of option order.
public struct AnimationCommandArguments: Equatable, Sendable {
    public let positionals: [String]
    public let options: [String: String]

    public enum Failure: Error, LocalizedError {
        case invalid(String)
        public var errorDescription: String? {
            switch self { case .invalid(let message): message }
        }
    }

    public init(command: String, arguments: [String]) throws {
        let valued: Set<String>
        let flags: Set<String>
        switch command {
        case "render": valued = ["--out"]; flags = []
        case "play", "watch": valued = ["--slow"]; flags = []
        case "new": valued = ["--from"]; flags = []
        case "import": valued = ["--name"]; flags = []
        case "docs": valued = []; flags = ["--generic"]
        default: valued = []; flags = []
        }
        var positionals: [String] = []
        var options: [String: String] = [:]
        var index = 0
        var endOfOptions = false
        while index < arguments.count {
            let argument = arguments[index]
            if !endOfOptions && argument == "--" {
                endOfOptions = true
            } else if !endOfOptions && argument.hasPrefix("--") {
                guard valued.contains(argument) || flags.contains(argument) else {
                    throw Failure.invalid("Unknown option \(argument) for \(command).")
                }
                guard options[argument] == nil else {
                    throw Failure.invalid("Option \(argument) may only be supplied once.")
                }
                if valued.contains(argument) {
                    guard index + 1 < arguments.count, !arguments[index + 1].hasPrefix("--") else {
                        throw Failure.invalid("\(argument) requires a value.")
                    }
                    index += 1
                    options[argument] = arguments[index]
                } else {
                    options[argument] = ""
                }
            } else {
                positionals.append(argument)
            }
            index += 1
        }
        let noTarget = ["list", "docs", "help", "--help", "-h"].contains(command)
        if (noTarget && !positionals.isEmpty) || (command != "new" && positionals.count > 1) {
            throw Failure.invalid("Unexpected extra arguments for \(command).")
        }
        self.positionals = positionals
        self.options = options
    }
}
