// Compile-time gate. The active flags come from ios/Config/*.xcconfig.
// Release must not also define the dev-login or Debug flags, including when
// those arrive as -D via OTHER_SWIFT_FLAGS rather than SWIFT_ACTIVE_COMPILATION_CONDITIONS.
#if RELEASE && (DEV_LOGIN || DEBUG)
#error("Release must not define DEV_LOGIN or DEBUG")
#endif

#if !DEBUG && !BETA && !RELEASE
#error("Unknown build configuration: define DEBUG, BETA, or RELEASE")
#endif
