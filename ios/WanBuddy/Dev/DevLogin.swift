#if DEV_LOGIN
import Foundation
import Supabase
import WanBuddyCore

extension SupabaseAuthRepository {
    func signInWithEmail(email: String, password: String) async throws -> AuthSession {
        let session = try await client.auth.signIn(email: email, password: password)
        return AuthSession(userID: session.user.id.uuidString, email: session.user.email)
    }
}

extension AppModel {
    func signInWithEmail(email: String, password: String) async {
        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedEmail.isEmpty, !password.isEmpty else {
            authErrorMessage = SignInFailureMessage.invalidCredentials
            return
        }
        isSigningIn = true
        authErrorMessage = nil
        defer { isSigningIn = false }
        do {
            let signedIn = try await authRepository.signInWithEmail(email: trimmedEmail, password: password)
            session = signedIn
            onboarding = onboardingStore.load(userID: signedIn.userID)
        } catch {
            let described = String(describing: error)
            if described.contains("WB") {
                authErrorMessage = WBErrorMessages.message(extractingFrom: described)
            } else {
                authErrorMessage = SignInFailureMessage.message(forServerText: described)
            }
        }
    }
}
#endif
