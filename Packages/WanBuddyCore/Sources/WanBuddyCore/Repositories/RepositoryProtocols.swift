public protocol AuthRepository: AnyObject {
    func currentSession() async -> AuthSession?
    func signOut() async throws
}

public protocol ProfileRepository: AnyObject {
    func fetchProfile(userID: String) async throws -> UserProfile?
    func fetchDogs(ownerID: String) async throws -> [DogProfile]
}

public protocol FriendRepository: AnyObject {
    func fetchAcceptedFriends(userID: String) async throws -> [FriendSummary]
}

public protocol PresenceRepository: AnyObject {
    func fetchActivePresences(userID: String) async throws -> [PresenceSnapshot]
}

public protocol SafetyRepository: AnyObject {
    func fetchBlocks(blockerID: String) async throws -> [BlockedUser]
}
