#if DEV_LOGIN
import Foundation

/// In-memory repositories for tests and Debug previews.
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

public final class MockProfileRepository: ProfileRepository {
    public init() {}

    public func fetchProfile(userID: String) async throws -> UserProfile? {
        UserProfile(id: userID, nickname: "クレア")
    }

    public func fetchDogs(ownerID: String) async throws -> [DogProfile] {
        [
            DogProfile(id: "moka", ownerID: ownerID, name: "モカ", breed: "柴"),
            DogProfile(id: "ruru", ownerID: ownerID, name: "ルル", breed: "トイプードル"),
            DogProfile(id: "kotaro", ownerID: ownerID, name: "コタロウ", breed: "コーギー"),
            DogProfile(id: "sora", ownerID: ownerID, name: "ソラ", breed: "ミックス"),
            DogProfile(id: "mimi", ownerID: ownerID, name: "ミミ", breed: "プードル"),
        ]
    }
}

public final class MockFriendRepository: FriendRepository {
    public init() {}

    public func fetchAcceptedFriends(userID: String) async throws -> [FriendSummary] {
        [
            FriendSummary(id: "friend-moka", otherUserID: "owner-moka"),
            FriendSummary(id: "friend-ruru", otherUserID: "owner-ruru"),
        ]
    }
}

public final class MockPresenceRepository: PresenceRepository {
    public init() {}

    public func fetchActivePresences(userID: String) async throws -> [PresenceSnapshot] {
        [
            PresenceSnapshot(
                id: "presence-moka",
                userID: "owner-moka",
                status: "now",
                expiresAt: "2026-11-04T12:00:00Z"
            ),
        ]
    }
}

public final class MockSafetyRepository: SafetyRepository {
    public init() {}

    public func fetchBlocks(blockerID: String) async throws -> [BlockedUser] {
        []
    }
}

#endif
