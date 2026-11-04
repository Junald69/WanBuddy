import Foundation
import Supabase
import WanBuddyCore

final class SupabaseAuthRepository: AuthRepository {
    let client: SupabaseClient

    init(client: SupabaseClient) {
        self.client = client
    }

    func currentSession() async -> AuthSession? {
        if let stored = client.auth.currentSession, !stored.isExpired {
            return Self.session(stored)
        }
        guard client.auth.currentSession != nil else { return nil }
        do {
            let refreshed = try await client.auth.session
            return Self.session(refreshed)
        } catch {
            return nil
        }
    }

    func signOut() async throws {
        try await client.auth.signOut()
    }

    private static func session(_ session: Session) -> AuthSession {
        AuthSession(userID: session.user.id.uuidString, email: session.user.email)
    }
}
