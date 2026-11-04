public enum BuildFeatures {
    /// True only when this module was compiled with the `DEV_LOGIN` flag (debug configuration).
    public static var devLoginCompiledIn: Bool {
        #if DEV_LOGIN
        return true
        #else
        return false
        #endif
    }
}
