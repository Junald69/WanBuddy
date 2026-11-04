import WanBuddyCore

#if DEBUG
enum DebugMockSmokeTest {
    /// References the debug-only mock type so a Debug build fails if it was compiled out.
    static func touch() {
        _ = MockAuthRepository()
    }
}
#endif
