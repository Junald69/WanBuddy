import Foundation
import Observation
import Supabase
import WanBuddyCore

@MainActor
@Observable
final class AppModel {
    let config: AppConfig
    let authRepository: SupabaseAuthRepository
    let profileRepository: ProfileRepository
    let friendRepository: FriendRepository
    let presenceRepository: PresenceRepository
    let safetyRepository: SafetyRepository

    let onboardingStore: OnboardingStore

    var session: AuthSession?
    var onboarding: OnboardingDraft?
    var isReady = false
    var isSigningIn = false
    var authErrorMessage: String?

    init(config: AppConfig, onboardingStore: OnboardingStore = OnboardingStore()) {
        self.config = config
        guard let url = URL(string: config.supabaseURL), url.scheme == "https", url.host != nil else {
            fatalError("WanBuddy SUPABASE_URL is not a usable https URL. Refusing to launch.")
        }
        let client = SupabaseClient(supabaseURL: url, supabaseKey: config.publishableKey)
        authRepository = SupabaseAuthRepository(client: client)
        profileRepository = SupabaseProfileRepository(client: client)
        friendRepository = SupabaseFriendRepository(client: client)
        presenceRepository = SupabasePresenceRepository(client: client)
        safetyRepository = SupabaseSafetyRepository(client: client)
        self.onboardingStore = onboardingStore
        #if DEBUG
        DebugMockSmokeTest.touch()
        #endif
    }

    var root: RootDestination {
        RootRouter.destination(hasSession: session != nil, onboardingComplete: onboarding != nil)
    }

    func restoreSession() async {
        let restored = await authRepository.currentSession()
        session = restored
        if let restored {
            onboarding = onboardingStore.load(userID: restored.userID)
        }
        isReady = true
    }

    func completeOnboarding(_ draft: OnboardingDraft) {
        guard let session else { return }
        guard OnboardingValidator.violations(in: draft).isEmpty else { return }
        onboardingStore.save(draft, userID: session.userID)
        onboarding = draft
    }

    func signOut() async {
        try? await authRepository.signOut()
        session = nil
        onboarding = nil
        authErrorMessage = nil
    }
}
