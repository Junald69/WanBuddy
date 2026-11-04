import WanBuddyCore

#if DEBUG
enum DebugMockSmokeTest {
    /// References the debug-only mock types so a Debug build fails if they were compiled out.
    static func touch() {
        _ = MockAuthRepository()
        _ = MockProfileRepository()
        _ = MockFriendRepository()
        _ = MockPresenceRepository()
        _ = MockSafetyRepository()
    }
}
#endif
