import Compression
import CoreGraphics
import Foundation

/// Something wrong with, or adjusted in, an animation file. `path` names the value,
/// e.g. `open.height.keyframes[2].value`.
public struct AnimationIssue: Equatable, Sendable, CustomStringConvertible {
    public enum Severity: String, Sendable {
        /// The file cannot be used until it is fixed.
        case error
        /// The file works, with this value changed or ignored.
        case warning
    }

    public var severity: Severity
    public var path: String
    public var message: String

    public init(_ severity: Severity, _ path: String, _ message: String) {
        self.severity = severity
        self.path = path
        self.message = message
    }

    public var description: String {
        path.isEmpty ? "\(severity.rawValue): \(message)" : "\(severity.rawValue) \(path): \(message)"
    }
}

/// An animation read from a file: the animation when it can be used, and every issue.
public struct AnimationReadResult: Equatable, Sendable {
    public var animation: DropyAnimation?
    public var issues: [AnimationIssue]

    public init(animation: DropyAnimation?, issues: [AnimationIssue]) {
        self.animation = animation
        self.issues = issues
    }

    public var errors: [AnimationIssue] { issues.filter { $0.severity == .error } }
    public var warnings: [AnimationIssue] { issues.filter { $0.severity == .warning } }
}

/// Dropy's animation files: JSON (comments and trailing commas allowed) that describes
/// a `DropyAnimation`. The reader is forgiving, since people and AI agents write these
/// by hand: anything left out comes from the style named in `basedOn`, values outside
/// `AnimationLimits` are brought inside with a warning, and every problem names the
/// exact value it is about. The format is documented in `AnimationGuide`.
public enum AnimationFile {
    /// The key that marks a file as a Dropy animation; its value is the format version.
    public static let formatKey = "dropyAnimation"
    public static let version = 1
    public static let shareCodePrefix = "dropy-animation:"

    /// Files, and share codes once unpacked, may be at most this big. A complete
    /// animation is about 1.5 KB; the limit keeps a hostile or runaway file (or a share
    /// code that unpacks to gigabytes) from using up memory or time.
    public static let maximumSize = 128 * 1024
    /// The longest share code read; real ones are under 1,000 characters.
    public static let maximumShareCodeLength = 16 * 1024
    /// Problems listed per file, at most.
    public static let maximumIssues = 40
    /// Text fields keep at most this many characters.
    public static let maximumNameLength = 80
    public static let maximumSummaryLength = 400

    // MARK: Reading

    /// Reads an animation; `fallbackName` names it when the file does not.
    public static func read(_ data: Data, fallbackName: String = "Untitled") -> AnimationReadResult {
        let reader = Reader()
        guard data.count <= maximumSize else {
            reader.error("", "The file is \(data.count / 1024) KB; an animation file may be at most \(maximumSize / 1024) KB.")
            return AnimationReadResult(animation: nil, issues: reader.issues)
        }
        let json: Any
        do {
            json = try JSONSerialization.jsonObject(with: data, options: [.json5Allowed])
        } catch {
            let detail = (error as NSError).userInfo[NSDebugDescriptionErrorKey] as? String ?? error.localizedDescription
            reader.error("", "This is not valid JSON: \(detail)")
            return AnimationReadResult(animation: nil, issues: reader.issues)
        }
        let animation = reader.animation(json, fallbackName: fallbackName)
        return AnimationReadResult(animation: reader.hasErrors ? nil : animation, issues: reader.issues)
    }

    /// Reads a code made by `shareCode(for:)`.
    public static func read(shareCode: String) -> AnimationReadResult {
        guard shareCode.utf8.count <= maximumShareCodeLength else {
            return AnimationReadResult(animation: nil, issues: [
                AnimationIssue(.error, "", "This is too long to be a share code."),
            ])
        }
        let trimmed = shareCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix(shareCodePrefix) else {
            return AnimationReadResult(animation: nil, issues: [
                AnimationIssue(.error, "", "A share code starts with “\(shareCodePrefix)”."),
            ])
        }
        var base64 = String(trimmed.dropFirst(shareCodePrefix.count))
            .replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            .filter { !$0.isWhitespace }
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        guard let packed = Data(base64Encoded: base64) else {
            return AnimationReadResult(animation: nil, issues: [
                AnimationIssue(.error, "", "This share code is incomplete or damaged; copy all of it."),
            ])
        }
        switch inflate(packed, limit: maximumSize) {
        case .success(let json): return read(json)
        case .failure(.tooLarge):
            return AnimationReadResult(animation: nil, issues: [
                AnimationIssue(.error, "", "This share code unpacks to more than \(maximumSize / 1024) KB, far more than any animation; it was not read."),
            ])
        case .failure(.damaged):
            return AnimationReadResult(animation: nil, issues: [
                AnimationIssue(.error, "", "This share code is incomplete or damaged; copy all of it."),
            ])
        }
    }

    enum InflateFailure: Error { case damaged, tooLarge }

    /// Unpacks raw DEFLATE (what `NSData.compressed(using: .zlib)` writes), stopping as
    /// soon as the output would pass `limit`. `NSData.decompressed` has no limit, so a
    /// tiny code could unpack to gigabytes.
    static func inflate(_ data: Data, limit: Int) -> Result<Data, InflateFailure> {
        guard !data.isEmpty else { return .failure(.damaged) }
        let stream = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        defer { stream.deallocate() }
        guard compression_stream_init(stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else {
            return .failure(.damaged)
        }
        defer { compression_stream_destroy(stream) }
        let chunk = 16 * 1024
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: chunk)
        defer { buffer.deallocate() }
        return data.withUnsafeBytes { (source: UnsafeRawBufferPointer) -> Result<Data, InflateFailure> in
            guard let base = source.bindMemory(to: UInt8.self).baseAddress else { return .failure(.damaged) }
            stream.pointee.src_ptr = base
            stream.pointee.src_size = source.count
            var output = Data()
            while true {
                stream.pointee.dst_ptr = buffer
                stream.pointee.dst_size = chunk
                let status = compression_stream_process(stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                let produced = chunk - stream.pointee.dst_size
                if output.count + produced > limit { return .failure(.tooLarge) }
                output.append(buffer, count: produced)
                switch status {
                case COMPRESSION_STATUS_END: return .success(output)
                case COMPRESSION_STATUS_OK:
                    // No progress with input left means the data ends early.
                    if produced == 0, stream.pointee.src_size == 0 { return .failure(.damaged) }
                default: return .failure(.damaged)
                }
            }
        }
    }

    // MARK: Writing

    /// The animation as a tidy, complete file.
    public static func data(for animation: DropyAnimation) -> Data {
        Data((JSONText.render(document(for: animation), indent: 0) + "\n").utf8)
    }

    /// A single line that carries the whole animation, for pasting into a message.
    public static func shareCode(for animation: DropyAnimation) -> String {
        let compact = Data(JSONText.render(document(for: animation), indent: nil).utf8)
        let packed = (try? (compact as NSData).compressed(using: .zlib) as Data) ?? compact
        let base64 = packed.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return shareCodePrefix + base64
    }

    static func document(for animation: DropyAnimation) -> JSONText {
        var fields: [(String, JSONText)] = [
            (formatKey, .number(Double(version))),
            ("name", .string(animation.name)),
        ]
        if !animation.summary.isEmpty { fields.append(("description", .string(animation.summary))) }
        if !animation.author.isEmpty { fields.append(("author", .string(animation.author))) }
        for part in DropyAnimation.Part.allCases {
            let motion = animation[part]
            fields.append((part.rawValue, .object([("width", curve(motion.width)), ("height", curve(motion.height))])))
        }
        let content = animation.content
        fields.append(("content", .object([
            ("revealDelay", .number(content.revealDelay)),
            ("revealDuration", .number(content.revealDuration)),
            ("revealCurve", timing(content.revealCurve)),
            ("hideDuration", .number(content.hideDuration)),
            ("hideCurve", timing(content.hideCurve)),
            ("relayoutDuration", .number(content.relayoutDuration)),
            ("cascade", .number(content.staggerSpan)),
            ("drift", .number(Double(content.staggerDrift))),
            ("startScale", .number(Double(content.restScale))),
            ("blur", .number(Double(content.blurRadius))),
        ])))
        return .object(fields)
    }

    private static func curve(_ curve: MotionCurve) -> JSONText {
        switch curve {
        case .spring(let spring, let delay):
            var fields: [(String, JSONText)] = [("spring", .inlineObject([
                ("response", .number(spring.response)), ("damping", .number(spring.dampingRatio)),
            ]))]
            if delay > 0 { fields.append(("delay", .number(delay))) }
            return .object(fields)
        case .keyframes(let keys):
            return .object([("keyframes", .array(keys.enumerated().map { index, key in
                var fields: [(String, JSONText)] = [("time", .number(key.time)), ("value", .number(key.value))]
                if index > 0 { fields.append(("ease", ease(key.ease))) }
                return .inlineObject(fields)
            }))])
        }
    }

    private static func ease(_ ease: MotionEase) -> JSONText {
        if let name = ease.name { return .string(name) }
        if case .curve(let curve) = ease { return timing(curve) }
        return .string("smooth")
    }

    private static func timing(_ curve: TimingCurve) -> JSONText {
        if let name = TimingCurve.named.first(where: { $0.curve == curve })?.name { return .string(name) }
        return .inlineArray(curve.controlPoints.map { .number($0) })
    }
}

// MARK: Reader

private final class Reader {
    var issues: [AnimationIssue] = []
    private(set) var hasErrors = false
    private var dropped = 0

    func error(_ path: String, _ message: String) {
        hasErrors = true
        add(AnimationIssue(.error, path, message))
    }

    func warning(_ path: String, _ message: String) { add(AnimationIssue(.warning, path, message)) }

    /// Keeps the list short however broken the file: past the limit, one line says how
    /// many more there were.
    private func add(_ issue: AnimationIssue) {
        let limit = AnimationFile.maximumIssues
        if issues.count < limit - 1 {
            issues.append(issue)
            return
        }
        dropped += 1
        let summary = AnimationIssue(hasErrors ? .error : .warning, "", "…and \(dropped) more problem\(dropped == 1 ? "" : "s") not listed.")
        if issues.count == limit { issues[limit - 1] = summary } else { issues.append(summary) }
    }

    func animation(_ json: Any, fallbackName: String) -> DropyAnimation? {
        guard let root = json as? [String: Any] else {
            error("", "An animation file is a JSON object: { \"\(AnimationFile.formatKey)\": 1, … }.")
            return nil
        }
        expect(keys: root, ["$schema", AnimationFile.formatKey, "name", "description", "author", "basedOn",
                            "open", "resize", "close", "content"], at: "")
        switch number(root[AnimationFile.formatKey]) {
        case nil:
            error(AnimationFile.formatKey, root[AnimationFile.formatKey] == nil
                  ? "Missing. Put \"\(AnimationFile.formatKey)\": 1 at the top: it marks the file as a Dropy animation."
                  : "Must be the number 1.")
        case let version? where version > Double(AnimationFile.version):
            error(AnimationFile.formatKey, "This file is for a newer Dropy (format \(version)); this one reads format \(AnimationFile.version).")
        case let version? where version != Double(AnimationFile.version):
            error(AnimationFile.formatKey, "Must be \(AnimationFile.version).")
        default: break
        }
        var base = MotionStyle.balanced.animation
        if let name = root["basedOn"] {
            let all = MotionStyle.allCases.map { ($0.rawValue, $0.animation) } + DropyAnimation.gallery.map { ($0.id, $0.animation) }
            if let name = name as? String, let found = all.first(where: { $0.0 == name.lowercased() }) {
                base = found.1
            } else {
                warning("basedOn", "Unknown style\(suggestion(for: name as? String, among: all.map(\.0))); starting from balanced. Use one of: \(all.map(\.0).joined(separator: ", ")).")
            }
        }
        var animation = base
        animation.name = text(root, "name", limit: AnimationFile.maximumNameLength)
            ?? AnimationText.clean(fallbackName, limit: AnimationFile.maximumNameLength)
        animation.summary = text(root, "description", limit: AnimationFile.maximumSummaryLength) ?? ""
        animation.author = text(root, "author", limit: AnimationFile.maximumNameLength) ?? ""
        for part in DropyAnimation.Part.allCases {
            guard let value = root[part.rawValue] else { continue }
            if let motion = motion(value, base: base[part], at: part.rawValue) {
                animation[part] = fitted(motion, part: part)
            }
        }
        if let value = root["content"] { animation.content = content(value, base: base.content) }
        let close = animation.close.width.extent.upperBound > 1.001 || animation.close.height.extent.upperBound > 1.001
        if close {
            warning("close", "Closing never bounces: Dropy plays it forward-only, so the outline cannot spring back out of the notch. The overshoot here is not shown.")
        }
        for part in [DropyAnimation.Part.open, .resize] {
            let extent = animation[part].extent
            if extent.upperBound > 1.5 || extent.lowerBound < -0.6 {
                warning(part.rawValue, "Travels \(Int(((extent.upperBound - 1) * 100).rounded())) % past its size at most; past 50 % the overlay tends to look broken.")
            }
        }
        return animation
    }

    /// Plays a motion faster when it would take longer than its part allows.
    private func fitted(_ motion: NotchMorph.Motion, part: DropyAnimation.Part) -> NotchMorph.Motion {
        let longest = AnimationLimits.longest(part)
        let duration = motion.duration
        guard duration > longest + 0.001 else { return motion }
        warning(part.rawValue, "Plays for \(seconds(duration)); the most a \(part.rawValue) may take is \(seconds(longest)), so it is sped up to fit.")
        let factor = longest / duration
        var fitted = motion
        fitted.width = motion.width.stretched(by: factor)
        fitted.height = motion.height.stretched(by: factor)
        // A spring's settling time does not scale exactly with its response.
        if fitted.duration > longest + 0.001 {
            let again = longest / fitted.duration
            fitted.width = fitted.width.stretched(by: again)
            fitted.height = fitted.height.stretched(by: again)
        }
        return fitted
    }

    private func motion(_ value: Any, base: NotchMorph.Motion, at path: String) -> NotchMorph.Motion? {
        guard let object = value as? [String: Any] else {
            error(path, "Must be an object with \"width\" and \"height\" curves (or one curve for both).")
            return nil
        }
        // One curve for both parts: { "spring": … } or { "keyframes": … } directly.
        if object["spring"] != nil || object["keyframes"] != nil {
            guard let curve = curve(object, at: path) else { return nil }
            return NotchMorph.Motion(width: curve, height: curve)
        }
        expect(keys: object, ["width", "height"], at: path)
        var motion = base
        if let width = object["width"] {
            guard let curve = curve(width, at: "\(path).width") else { return nil }
            motion.width = curve
        }
        if let height = object["height"] {
            guard let curve = curve(height, at: "\(path).height") else { return nil }
            motion.height = curve
        }
        return motion
    }

    private func curve(_ value: Any, at path: String) -> MotionCurve? {
        guard let object = value as? [String: Any] else {
            error(path, "Must be an object: { \"spring\": { \"response\": 0.35, \"damping\": 0.8 } } or { \"keyframes\": [ … ] }.")
            return nil
        }
        expect(keys: object, ["spring", "keyframes", "delay"], at: path)
        let delay = object["delay"].map { _ in clamped(object, "delay", at: path, AnimationLimits.delay, unit: " s") ?? 0 } ?? 0
        switch (object["spring"], object["keyframes"]) {
        case (.some, .some):
            error(path, "Has both \"spring\" and \"keyframes\"; use one.")
            return nil
        case (let spring?, nil):
            guard let spring = self.spring(spring, at: "\(path).spring") else { return nil }
            return .spring(spring, delay: delay)
        case (nil, let keys?):
            guard var keys = keyframes(keys, at: "\(path).keyframes") else { return nil }
            if delay > 0 { keys = keys.map { MotionKeyframe(time: $0.time + delay, value: $0.value, ease: $0.ease) } }
            return .keyframes(keys)
        case (nil, nil):
            error(path, "Needs \"spring\" or \"keyframes\".")
            return nil
        }
    }

    private func spring(_ value: Any, at path: String) -> MorphSpring? {
        guard let object = value as? [String: Any] else {
            error(path, "Must be an object: { \"response\": 0.35, \"damping\": 0.8 }.")
            return nil
        }
        expect(keys: object, ["response", "damping", "dampingFraction", "bounce"], at: path)
        guard object["response"] != nil else {
            error("\(path).response", "Missing: seconds for one swing of the spring (\(range(AnimationLimits.response))). Smaller is faster.")
            return nil
        }
        guard let response = clamped(object, "response", at: path, AnimationLimits.response, unit: " s") else { return nil }
        var damping = 1.0
        if object["damping"] != nil || object["dampingFraction"] != nil {
            let key = object["damping"] != nil ? "damping" : "dampingFraction"
            guard let value = clamped(object, key, at: path, AnimationLimits.damping, unit: "",
                                      why: "below 0.36 the bounce would reach past the screen edge") else { return nil }
            damping = value
        } else if object["bounce"] != nil {
            let bounceRange = (1 - AnimationLimits.damping.upperBound)...(1 - AnimationLimits.damping.lowerBound)
            guard let bounce = clamped(object, "bounce", at: path, bounceRange, unit: "") else { return nil }
            damping = 1 - bounce
        }
        return MorphSpring(response: response, dampingRatio: damping)
    }

    private func keyframes(_ value: Any, at path: String) -> [MotionKeyframe]? {
        guard let array = value as? [Any] else {
            error(path, "Must be a list: [ { \"time\": 0, \"value\": 0 }, { \"time\": 0.3, \"value\": 1, \"ease\": \"easeOut\" } ].")
            return nil
        }
        guard AnimationLimits.keyCount.contains(array.count) else {
            error(path, "Has \(array.count) keyframes; use \(AnimationLimits.keyCount.lowerBound) to \(AnimationLimits.keyCount.upperBound).")
            return nil
        }
        var keys: [MotionKeyframe] = []
        for (index, item) in array.enumerated() {
            let itemPath = "\(path)[\(index)]"
            var time: Double?
            var value: Double?
            var ease = MotionEase.smooth
            if let object = item as? [String: Any] {
                expect(keys: object, ["time", "value", "ease"], at: itemPath)
                if object["time"] == nil { error("\(itemPath).time", "Missing: seconds from the start of the motion.") }
                if object["value"] == nil { error("\(itemPath).value", "Missing: progress, 0 where the motion starts and 1 where it ends.") }
                if object["time"] != nil { time = clamped(object, "time", at: itemPath, AnimationLimits.keyTime, unit: " s") }
                if object["value"] != nil {
                    value = clamped(object, "value", at: itemPath, AnimationLimits.keyValue, unit: "",
                                    why: "the outline would leave the screen edge or fold up")
                }
                if let raw = object["ease"] { ease = self.ease(raw, at: "\(itemPath).ease") }
            } else if let list = item as? [Any], (2...3).contains(list.count) {
                // Short form: [time, value] or [time, value, ease].
                let fields = ["time": list[0], "value": list[1]]
                time = clamped(fields, "time", at: itemPath, AnimationLimits.keyTime, unit: " s")
                value = clamped(fields, "value", at: itemPath, AnimationLimits.keyValue, unit: "")
                if list.count == 3 { ease = self.ease(list[2], at: "\(itemPath)[2]") }
            } else {
                error(itemPath, "Must be { \"time\": …, \"value\": …, \"ease\": … } or [time, value].")
            }
            if let time, let value { keys.append(MotionKeyframe(time: time, value: value, ease: ease)) }
        }
        guard !hasErrors || keys.count == array.count else { return nil }
        if zip(keys, keys.dropFirst()).contains(where: { $0.time > $1.time }) {
            keys.sort { $0.time < $1.time }
            warning(path, "Keyframes were out of order in time; they are played sorted.")
        }
        for index in keys.indices.dropFirst() where keys[index].time <= keys[index - 1].time {
            keys[index].time = keys[index - 1].time + 0.001
            warning("\(path)[\(index)].time", "Two keyframes at the same moment; this one is moved 1 ms later.")
        }
        if keys[0].value != 0 {
            warning("\(path)[0].value", "The first keyframe is where the motion starts, so its value is 0 (it was \(show(keys[0].value))). A later first time is fine: it waits until then.")
            keys[0].value = 0
        }
        if keys[keys.count - 1].value != 1 {
            warning("\(path)[\(keys.count - 1)].value", "The last keyframe is where the motion ends, so its value is 1 (it was \(show(keys[keys.count - 1].value))).")
            keys[keys.count - 1].value = 1
        }
        return keys
    }

    private func ease(_ value: Any, at path: String) -> MotionEase {
        if let name = value as? String {
            if let ease = MotionEase(name: name) { return ease }
            warning(path, "Unknown ease “\(AnimationText.clean(name, limit: 40))”\(suggestion(for: name, among: MotionEase.names)); using smooth. Use one of: \(MotionEase.names.joined(separator: ", ")), or [x1, y1, x2, y2].")
            return .smooth
        }
        if let curve = timingCurve(value, at: path) { return .curve(curve) }
        return .smooth
    }

    private func timingCurve(_ value: Any, at path: String) -> TimingCurve? {
        if let name = value as? String {
            if let curve = TimingCurve.named.first(where: { $0.name == name })?.curve { return curve }
            if name == "linear" { return .linear }
            warning(path, "Unknown curve “\(AnimationText.clean(name, limit: 40))”\(suggestion(for: name, among: TimingCurve.named.map(\.name))); using the default.")
            return nil
        }
        guard let list = value as? [Any], list.count == 4 else {
            warning(path, "A curve is a name (\(TimingCurve.named.map(\.name).joined(separator: ", "))) or four numbers [x1, y1, x2, y2]; using the default.")
            return nil
        }
        var points: [Double] = []
        for (index, item) in list.enumerated() {
            guard let number = number(item) else {
                warning("\(path)[\(index)]", "Must be a number; using the default curve.")
                return nil
            }
            let limits: ClosedRange<Double> = index % 2 == 0 ? 0.0...1.0 : AnimationLimits.curveY
            if !limits.contains(number) {
                warning("\(path)[\(index)]", "\(show(number)) is outside \(range(limits)); using \(show(min(max(number, limits.lowerBound), limits.upperBound))).")
            }
            points.append(min(max(number, limits.lowerBound), limits.upperBound))
        }
        return TimingCurve(points[0], points[1], points[2], points[3])
    }

    private func content(_ value: Any, base: ContentMotion) -> ContentMotion {
        guard let object = value as? [String: Any] else {
            error("content", "Must be an object of timings, e.g. { \"revealDelay\": 0.05, \"revealDuration\": 0.26 }.")
            return base
        }
        let keys = ["revealDelay", "revealDuration", "revealCurve", "hideDuration", "hideCurve", "relayoutDuration",
                    "cascade", "drift", "startScale", "blur"]
        expect(keys: object, keys, at: "content")
        var content = base
        func read(_ key: String, _ limits: ClosedRange<Double>, unit: String) -> Double? {
            object[key] == nil ? nil : clamped(object, key, at: "content", limits, unit: unit)
        }
        if let value = read("revealDelay", AnimationLimits.revealDelay, unit: " s") { content.revealDelay = value }
        if let value = read("revealDuration", AnimationLimits.revealDuration, unit: " s") { content.revealDuration = value }
        if let value = read("hideDuration", AnimationLimits.hideDuration, unit: " s") { content.hideDuration = value }
        if let value = read("relayoutDuration", AnimationLimits.relayoutDuration, unit: " s") { content.relayoutDuration = value }
        if let value = read("cascade", AnimationLimits.cascade, unit: " s") { content.staggerSpan = value }
        if let value = read("drift", AnimationLimits.drift, unit: " pt") { content.staggerDrift = CGFloat(value) }
        if let value = read("startScale", AnimationLimits.startScale, unit: "") { content.restScale = CGFloat(value) }
        if let value = read("blur", AnimationLimits.blur, unit: " pt") { content.blurRadius = CGFloat(value) }
        if let raw = object["revealCurve"], let curve = timingCurve(raw, at: "content.revealCurve") { content.revealCurve = curve }
        if let raw = object["hideCurve"], let curve = timingCurve(raw, at: "content.hideCurve") { content.hideCurve = curve }
        return content
    }

    // MARK: Values

    /// Text from the file, on one line, without control characters (which could restyle
    /// a terminal) and shortened to `limit`: animations come from other people, and their
    /// names end up in lists, menus and command output.
    private func text(_ object: [String: Any], _ key: String, limit: Int) -> String? {
        guard let value = object[key] else { return nil }
        guard let string = value as? String else {
            warning(key, "Must be text; ignored.")
            return nil
        }
        let whole = AnimationText.clean(string, limit: .max)
        if whole.count > limit { warning(key, "Shortened to \(limit) characters.") }
        let cleaned = AnimationText.clean(whole, limit: limit)
        return cleaned.isEmpty ? nil : cleaned
    }

    func number(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let double = number.doubleValue
        return double.isFinite ? double : nil
    }

    /// A number within `limits`; one outside is brought inside with a warning, and a
    /// value that is not a number is an error.
    private func clamped(_ object: [String: Any], _ key: String, at path: String, _ limits: ClosedRange<Double>,
                         unit: String, why: String? = nil) -> Double? {
        let full = path.isEmpty ? key : "\(path).\(key)"
        guard let value = number(object[key]) else {
            error(full, "Must be a number (\(range(limits))\(unit)).")
            return nil
        }
        guard !limits.contains(value) else { return value }
        let inside = min(max(value, limits.lowerBound), limits.upperBound)
        warning(full, "\(show(value))\(unit) is outside \(range(limits))\(unit)\(why.map { ": \($0)" } ?? ""); using \(show(inside))\(unit).")
        return inside
    }

    private func expect(keys object: [String: Any], _ known: [String], at path: String) {
        for key in object.keys.sorted() where !known.contains(key) {
            let shown = AnimationText.clean(key, limit: 40)
            let full = path.isEmpty ? shown : "\(path).\(shown)"
            warning(full, "Unknown key, ignored\(suggestion(for: key, among: known)).")
        }
    }

    private func suggestion(for word: String?, among options: [String]) -> String {
        // Long strings are not typos of short keys, and comparing them costs time.
        guard let word = word?.lowercased(), !word.isEmpty, word.count <= 40 else { return "" }
        let best = options.map { ($0, distance(word, $0.lowercased())) }.min { $0.1 < $1.1 }
        guard let best, best.1 <= max(2, word.count / 3) else { return "" }
        return " (did you mean “\(best.0)”?)"
    }

    /// Levenshtein distance.
    private func distance(_ a: String, _ b: String) -> Int {
        let a = Array(a)
        let b = Array(b)
        guard !a.isEmpty else { return b.count }
        guard !b.isEmpty else { return a.count }
        var previous = Array(0...b.count)
        for i in 1...a.count {
            var current = [i] + Array(repeating: 0, count: b.count)
            for j in 1...b.count {
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            previous = current
        }
        return previous[b.count]
    }

    private func show(_ value: Double) -> String { JSONText.format(value) }
    private func range(_ limits: ClosedRange<Double>) -> String { "\(show(limits.lowerBound))–\(show(limits.upperBound))" }
    private func seconds(_ value: Double) -> String { "\(show((value * 100).rounded() / 100)) s" }
}

// MARK: Text

/// Cleaning text that comes from animation files, file names and paths before it is
/// shown, printed or written into a guide that AI agents read.
public enum AnimationText {
    /// One line, no control characters (escape sequences could restyle a terminal or
    /// hide text), trimmed, and at most `limit` characters.
    public static func clean(_ text: String, limit: Int) -> String {
        var result = ""
        var lastWasSpace = false
        for scalar in text.unicodeScalars {
            let isControl = scalar.properties.generalCategory == .control || scalar.properties.generalCategory == .format
                || scalar == "\u{2028}" || scalar == "\u{2029}"
            if isControl || CharacterSet.whitespacesAndNewlines.contains(scalar) {
                if !lastWasSpace, !result.isEmpty { result.append(" ") }
                lastWasSpace = true
                continue
            }
            result.unicodeScalars.append(scalar)
            lastWasSpace = false
        }
        result = result.trimmingCharacters(in: .whitespaces)
        return result.count > limit ? String(result.prefix(limit - 1)) + "…" : result
    }

    /// Whether a path can be written into the guide that AI agents read and run
    /// commands from: inside a Markdown code span, and single-quoted (`shellQuoted`) in a
    /// command. Nothing that could end the span or start a new line.
    public static func canEmbed(path: String) -> Bool {
        !path.isEmpty && !path.unicodeScalars.contains { scalar in
            scalar.properties.generalCategory == .control || scalar.properties.generalCategory == .format
                || scalar == "`" || scalar == "\u{2028}" || scalar == "\u{2029}"
        }
    }

    /// `text` as a single shell word, inside single quotes, which nothing expands.
    public static func shellQuoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

// MARK: JSON text

/// A small JSON writer that keeps keys in the order given, so files read top to
/// bottom the way the format is explained, and puts each keyframe on one line.
indirect enum JSONText {
    case object([(String, JSONText)])
    case inlineObject([(String, JSONText)])
    case array([JSONText])
    case inlineArray([JSONText])
    case string(String)
    case number(Double)

    /// Pretty with `indent` (nil: one compact line).
    static func render(_ value: JSONText, indent: Int?) -> String {
        let pad = indent.map { String(repeating: "  ", count: $0 + 1) } ?? ""
        let close = indent.map { String(repeating: "  ", count: $0) } ?? ""
        let next = indent.map { $0 + 1 }
        switch value {
        case .string(let string): return quote(string)
        case .number(let number): return format(number)
        case .inlineObject(let fields):
            return "{ " + fields.map { "\(quote($0.0)): \(render($0.1, indent: nil))" }.joined(separator: ", ") + " }"
        case .inlineArray(let items):
            return "[" + items.map { render($0, indent: nil) }.joined(separator: ", ") + "]"
        case .object(let fields):
            guard indent != nil else {
                return "{" + fields.map { "\(quote($0.0)):\(render($0.1, indent: nil))" }.joined(separator: ",") + "}"
            }
            return "{\n" + fields.map { "\(pad)\(quote($0.0)): \(render($0.1, indent: next))" }
                .joined(separator: ",\n") + "\n\(close)}"
        case .array(let items):
            guard indent != nil else { return "[" + items.map { render($0, indent: nil) }.joined(separator: ",") + "]" }
            return "[\n" + items.map { "\(pad)\(render($0, indent: next))" }.joined(separator: ",\n") + "\n\(close)]"
        }
    }

    /// Up to four decimals, without trailing zeros: 0.34, 1, -0.06.
    static func format(_ number: Double) -> String {
        let rounded = (number * 10_000).rounded() / 10_000
        if rounded == rounded.rounded(), abs(rounded) < 1e15 { return String(Int(rounded)) }
        var text = String(format: "%.4f", rounded)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text == "-0" ? "0" : text
    }

    private static func quote(_ string: String) -> String {
        var result = "\""
        for scalar in string.unicodeScalars {
            switch scalar {
            case "\"": result += "\\\""
            case "\\": result += "\\\\"
            case "\n": result += "\\n"
            case "\t": result += "\\t"
            case "\r": result += "\\r"
            default:
                if scalar.value < 0x20 { result += String(format: "\\u%04x", scalar.value) } else { result.unicodeScalars.append(scalar) }
            }
        }
        return result + "\""
    }
}
