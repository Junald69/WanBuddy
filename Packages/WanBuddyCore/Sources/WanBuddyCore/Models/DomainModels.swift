public struct AuthSession: Equatable, Sendable {
    public var userID: String
    public var email: String?

    public init(userID: String, email: String?) {
        self.userID = userID
        self.email = email
    }
}
