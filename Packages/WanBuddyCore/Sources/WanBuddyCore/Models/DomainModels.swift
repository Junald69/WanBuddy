public struct AuthSession: Equatable, Sendable {
    public var userID: String
    public var email: String?

    public init(userID: String, email: String?) {
        self.userID = userID
        self.email = email
    }
}

public struct UserProfile: Equatable, Sendable, Identifiable {
    public var id: String
    public var nickname: String

    public init(id: String, nickname: String) {
        self.id = id
        self.nickname = nickname
    }
}

public struct DogProfile: Equatable, Sendable, Identifiable {
    public var id: String
    public var ownerID: String
    public var name: String
    public var breed: String?

    public init(id: String, ownerID: String, name: String, breed: String?) {
        self.id = id
        self.ownerID = ownerID
        self.name = name
        self.breed = breed
    }
}

public struct FriendSummary: Equatable, Sendable, Identifiable {
    public var id: String
    public var otherUserID: String

    public init(id: String, otherUserID: String) {
        self.id = id
        self.otherUserID = otherUserID
    }
}

public struct PresenceSnapshot: Equatable, Sendable, Identifiable {
    public var id: String
    public var userID: String
    public var status: String
    public var expiresAt: String

    public init(id: String, userID: String, status: String, expiresAt: String) {
        self.id = id
        self.userID = userID
        self.status = status
        self.expiresAt = expiresAt
    }
}

public struct BlockedUser: Equatable, Sendable, Identifiable {
    public var id: String

    public init(id: String) {
        self.id = id
    }
}
