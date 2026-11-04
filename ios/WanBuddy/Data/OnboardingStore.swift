import Foundation
import WanBuddyCore

struct OnboardingStore {
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load(userID: String) -> OnboardingDraft? {
        guard let data = defaults.data(forKey: key(userID)) else { return nil }
        return try? JSONDecoder().decode(OnboardingDraft.self, from: data)
    }

    func save(_ draft: OnboardingDraft, userID: String) {
        guard OnboardingValidator.violations(in: draft).isEmpty else { return }
        guard let data = try? JSONEncoder().encode(draft) else { return }
        defaults.set(data, forKey: key(userID))
    }

    private func key(_ userID: String) -> String {
        "wanbuddy.onboarding.\(userID)"
    }
}
