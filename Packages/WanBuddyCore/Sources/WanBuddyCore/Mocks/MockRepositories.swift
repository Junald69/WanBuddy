#if DEV_LOGIN
import Foundation

/// In-memory auth for tests and Debug previews.
/// The enclosing `#if` compiles this file out of Release package builds.
public final class MockAuthRepository: AuthRepository {
    public var session: AuthSession?
    public private(set) var signedInEmail: String?

    public init(session: AuthSession? = nil) {
        self.session = session
    }

    public func currentSession() async -> AuthSession? {
        session
    }

    public func signOut() async throws {
        session = nil
    }

    public func signInWithEmail(email: String, password: String) async throws -> AuthSession {
        if email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || password.isEmpty {
            throw MockAuthError.invalidCredentials
        }
        let session = AuthSession(userID: "mock-\(email)", email: email)
        self.session = session
        signedInEmail = email
        return session
    }
}

public enum MockAuthError: Error, Equatable {
    case invalidCredentials
}

#endif
