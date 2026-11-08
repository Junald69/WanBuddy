public enum AppBuildConfiguration: String, Equatable, Sendable {
    case debug
    case beta
    case release
}

/// Values read from the built Info.plist. Empty strings mean "missing".
public struct RawAppConfig: Equatable, Sendable {
    public var configurationName: String
    public var supabaseURL: String
    public var publishableKey: String
    public var projectRef: String
    public var bundleIdentifier: String
    public var bundleIDBase: String

    public init(
        configurationName: String,
        supabaseURL: String,
        publishableKey: String,
        projectRef: String,
        bundleIdentifier: String,
        bundleIDBase: String
    ) {
        self.configurationName = configurationName
        self.supabaseURL = supabaseURL
        self.publishableKey = publishableKey
        self.projectRef = projectRef
        self.bundleIdentifier = bundleIdentifier
        self.bundleIDBase = bundleIDBase
    }
}

public struct AppConfig: Equatable, Sendable {
    public var configuration: AppBuildConfiguration
    public var supabaseURL: String
    public var publishableKey: String
    public var projectRef: String
    public var bundleIdentifier: String
    public var bundleIDBase: String

    public init(
        configuration: AppBuildConfiguration,
        supabaseURL: String,
        publishableKey: String,
        projectRef: String,
        bundleIdentifier: String,
        bundleIDBase: String
    ) {
        self.configuration = configuration
        self.supabaseURL = supabaseURL
        self.publishableKey = publishableKey
        self.projectRef = projectRef
        self.bundleIdentifier = bundleIdentifier
        self.bundleIDBase = bundleIDBase
    }
}
