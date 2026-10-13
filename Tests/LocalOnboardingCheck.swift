import Foundation

@main
struct OnboardingChecks {
    static func main() {
        let suite = "DropyOnboardingChecks.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let progress = OnboardingProgress(defaults: defaults)
        precondition(!progress.isComplete && progress.step == .welcome)
        progress.save(.permissions)
        let resumed = OnboardingProgress(defaults: defaults)
        precondition(resumed.step == .permissions && !resumed.isComplete, "closing or relaunching must resume without completing setup")
        resumed.complete()
        precondition(OnboardingProgress(defaults: defaults).isComplete)
        progress.save(.welcome)
        precondition(progress.isComplete, "replaying the tour must not undo completion")
        defaults.set(999, forKey: "org.dropy.onboarding.step.v1")
        precondition(progress.step == .welcome, "unknown stored steps must recover safely")
        precondition(OnboardingProgress.shouldPresent(isComplete: false, arguments: [], isCheck: false))
        precondition(!OnboardingProgress.shouldPresent(isComplete: true, arguments: [], isCheck: false))
        precondition(OnboardingProgress.shouldPresent(isComplete: true, arguments: ["--onboarding"], isCheck: false))
        precondition(!OnboardingProgress.shouldPresent(isComplete: false, arguments: ["--show"], isCheck: true))
        precondition(!OnboardingProgress.shouldPresent(isComplete: false, arguments: ["--settings", "general"], isCheck: false))
        precondition(!OnboardingProgress.shouldPresent(isComplete: false, arguments: ["--studio", "float"], isCheck: false))
        precondition(!OnboardingProgress.shouldPresent(isComplete: false, arguments: ["--onboarding"], isCheck: true))
        print("Onboarding progress and launch policy checks passed")
    }
}
