/// Constants used only to reject a mis-pointed build.
///
/// `developmentProjectRef` is never turned into a URL and is never used as a
/// stand-in when Production values are missing.
public enum WanBuddyKnownEnvironment {
    public static let developmentProjectRef = "nlvjvmymeuvbxlzikpjx"

    /// Production project refs. Empty until that project exists.
    /// Keep this identical to `ios/Config/production_refs.blocklist`.
    public static let blockedProductionProjectRefs: [String] = []
}
