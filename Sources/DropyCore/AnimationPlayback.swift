/// Scalar validation shared by command-line, notification and UI playback.
public enum AnimationPlayback {
    public static func slowdown(_ value: Double) -> Double? {
        guard value.isFinite else { return nil }
        return min(max(value, 1), 20)
    }
}
