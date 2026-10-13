import Foundation

enum OnboardingStep: Int, CaseIterable, Identifiable {
    case welcome, permissions, shortcut, tryIt
    var id: Int { rawValue }
    var title: String {
        switch self {
        case .welcome: "Welcome"
        case .permissions: "Access"
        case .shortcut: "Shortcut"
        case .tryIt: "Try it"
        }
    }
}

/// Kept apart from app preferences: resetting settings does not restart setup.
/// Closing preserves the current step; an explicit finish or skip completes setup.
final class OnboardingProgress {
    private let defaults: UserDefaults
    private let completionKey = "org.dropy.onboarding.completed.v1"
    private let stepKey = "org.dropy.onboarding.step.v1"

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    var isComplete: Bool { defaults.bool(forKey: completionKey) }
    var step: OnboardingStep {
        OnboardingStep(rawValue: defaults.integer(forKey: stepKey)) ?? .welcome
    }
    func save(_ step: OnboardingStep) { defaults.set(step.rawValue, forKey: stepKey) }
    func complete() { defaults.set(true, forKey: completionKey) }

    static func shouldPresent(isComplete: Bool, arguments: [String], isCheck: Bool) -> Bool {
        if isCheck { return false }
        if arguments.contains("--onboarding") { return true }
        return !isComplete && !arguments.contains("--settings") && !arguments.contains("--studio")
    }
}
