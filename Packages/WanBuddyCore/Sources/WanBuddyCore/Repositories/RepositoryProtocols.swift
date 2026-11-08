public protocol AuthRepository: AnyObject {
    func currentSession() async -> AuthSession?
    func signOut() async throws
}
