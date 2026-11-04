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

final class SupabaseProfileRepository: ProfileRepository {
    let client: SupabaseClient

    init(client: SupabaseClient) {
        self.client = client
    }

    func fetchProfile(userID: String) async throws -> UserProfile? {
        let rows: [ProfileRow] = try await client
            .from("profiles")
            .select("id,nickname")
            .eq("id", value: userID)
            .limit(1)
            .execute()
            .value
        guard let row = rows.first else { return nil }
        return UserProfile(id: row.id.uuidString, nickname: row.nickname)
    }

    func fetchDogs(ownerID: String) async throws -> [DogProfile] {
        let rows: [DogRow] = try await client
            .from("dogs")
            .select("id,owner_id,name,breed")
            .eq("owner_id", value: ownerID)
            .execute()
            .value
        return rows.map { row in
            DogProfile(
                id: row.id.uuidString,
                ownerID: row.ownerId.uuidString,
                name: row.name,
                breed: row.breed
            )
        }
    }
}

final class SupabaseFriendRepository: FriendRepository {
    let client: SupabaseClient

    init(client: SupabaseClient) {
        self.client = client
    }

    func fetchAcceptedFriends(userID: String) async throws -> [FriendSummary] {
        let rows: [FriendshipRow] = try await client
            .from("friendships")
            .select("id,requester_id,addressee_id")
            .eq("status", value: "accepted")
            .or("requester_id.eq.\(userID),addressee_id.eq.\(userID)")
            .execute()
            .value
        return rows.map { row in
            let other = row.requesterId.uuidString == userID ? row.addresseeId : row.requesterId
            return FriendSummary(id: row.id.uuidString, otherUserID: other.uuidString)
        }
    }
}

final class SupabasePresenceRepository: PresenceRepository {
    let client: SupabaseClient

    init(client: SupabaseClient) {
        self.client = client
    }

    func fetchActivePresences(userID: String) async throws -> [PresenceSnapshot] {
        let rows: [PresenceRow] = try await client
            .from("presences")
            .select("id,user_id,status,expires_at,ended_at")
            .eq("user_id", value: userID)
            .execute()
            .value
        return rows.compactMap { row in
            guard row.endedAt == nil else { return nil }
            return PresenceSnapshot(
                id: row.id.uuidString,
                userID: row.userId.uuidString,
                status: row.status,
                expiresAt: row.expiresAt
            )
        }
    }
}

final class SupabaseSafetyRepository: SafetyRepository {
    let client: SupabaseClient

    init(client: SupabaseClient) {
        self.client = client
    }

    func fetchBlocks(blockerID: String) async throws -> [BlockedUser] {
        let rows: [BlockRow] = try await client
            .from("blocks")
            .select("blocked_id")
            .eq("blocker_id", value: blockerID)
            .execute()
            .value
        return rows.map { BlockedUser(id: $0.blockedId.uuidString) }
    }
}

private struct ProfileRow: Decodable {
    let id: UUID
    let nickname: String
}

private struct DogRow: Decodable {
    let id: UUID
    let ownerId: UUID
    let name: String
    let breed: String?
}

private struct FriendshipRow: Decodable {
    let id: UUID
    let requesterId: UUID
    let addresseeId: UUID
}

private struct PresenceRow: Decodable {
    let id: UUID
    let userId: UUID
    let status: String
    let expiresAt: String
    let endedAt: String?
}

private struct BlockRow: Decodable {
    let blockedId: UUID
}
