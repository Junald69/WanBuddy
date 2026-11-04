import Foundation

public enum ConfigViolation: Equatable, Sendable, Error, CustomStringConvertible {
    case missingConfiguration
    case unknownConfiguration(String)
    case empty(String)
    case refLength
    case refCharset
    case releaseUsesDevelopmentRef
    case configurationRefMismatch
    case refIsBlockedProduction
    case urlMismatch
    case keyPrefix
    case keyLooksLikeSecret
    case bundleIdentifier
    case bundleIDBaseMissing

    public var description: String {
        switch self {
        case .missingConfiguration:
            return "missingConfiguration"
        case .unknownConfiguration(let name):
            return "unknownConfiguration(\(name))"
        case .empty(let field):
            return "empty(\(field))"
        case .refLength:
            return "refLength"
        case .refCharset:
            return "refCharset"
        case .releaseUsesDevelopmentRef:
            return "releaseUsesDevelopmentRef"
        case .configurationRefMismatch:
            return "configurationRefMismatch"
        case .refIsBlockedProduction:
            return "refIsBlockedProduction"
        case .urlMismatch:
            return "urlMismatch"
        case .keyPrefix:
            return "keyPrefix"
        case .keyLooksLikeSecret:
            return "keyLooksLikeSecret"
        case .bundleIdentifier:
            return "bundleIdentifier"
        case .bundleIDBaseMissing:
            return "bundleIDBaseMissing"
        }
    }
}

public struct ConfigFailure: Error, Equatable, Sendable {
    public let violations: [ConfigViolation]

    public init(violations: [ConfigViolation]) {
        self.violations = violations
    }
}

public enum ConfigValidator {
    public static let publishableKeyPrefix = "sb_publishable_"

    public static func validate(
        _ raw: RawAppConfig,
        developmentProjectRef: String = WanBuddyKnownEnvironment.developmentProjectRef,
        blockedProductionProjectRefs: [String] = WanBuddyKnownEnvironment.blockedProductionProjectRefs
    ) -> Result<AppConfig, ConfigFailure> {
        let violations = self.violations(
            in: raw,
            developmentProjectRef: developmentProjectRef,
            blockedProductionProjectRefs: blockedProductionProjectRefs
        )
        if let configuration = AppBuildConfiguration(rawValue: trim(raw.configurationName)),
           violations.isEmpty {
            return .success(
                AppConfig(
                    configuration: configuration,
                    supabaseURL: trim(raw.supabaseURL),
                    publishableKey: trim(raw.publishableKey),
                    projectRef: trim(raw.projectRef),
                    bundleIdentifier: trim(raw.bundleIdentifier),
                    bundleIDBase: trim(raw.bundleIDBase)
                )
            )
        }
        return .failure(ConfigFailure(violations: violations))
    }

    public static func violations(
        in raw: RawAppConfig,
        developmentProjectRef: String = WanBuddyKnownEnvironment.developmentProjectRef,
        blockedProductionProjectRefs: [String] = WanBuddyKnownEnvironment.blockedProductionProjectRefs
    ) -> [ConfigViolation] {
        var violations: [ConfigViolation] = []
        let configurationName = trim(raw.configurationName)
        let url = trim(raw.supabaseURL)
        let key = trim(raw.publishableKey)
        let ref = trim(raw.projectRef)
        let bundleIdentifier = trim(raw.bundleIdentifier)
        let bundleIDBase = trim(raw.bundleIDBase)

        let configuration = AppBuildConfiguration(rawValue: configurationName)
        if configurationName.isEmpty {
            violations.append(.missingConfiguration)
        } else if configuration == nil {
            violations.append(.unknownConfiguration(configurationName))
        }

        if url.isEmpty { violations.append(.empty("SUPABASE_URL")) }
        if key.isEmpty { violations.append(.empty("SUPABASE_PUBLISHABLE_KEY")) }
        if ref.isEmpty { violations.append(.empty("SUPABASE_PROJECT_REF")) }

        if !ref.isEmpty {
            if ref.count != 20 {
                violations.append(.refLength)
            }
            if ref.range(of: "^[a-z0-9]{20}$", options: .regularExpression) == nil {
                violations.append(.refCharset)
            }
        }

        if let configuration {
            switch configuration {
            case .release:
                if ref == developmentProjectRef {
                    violations.append(.releaseUsesDevelopmentRef)
                }
            case .debug, .beta:
                if ref != developmentProjectRef {
                    violations.append(.configurationRefMismatch)
                }
                if blockedProductionProjectRefs.contains(ref) {
                    violations.append(.refIsBlockedProduction)
                }
            }
        }

        if url != expectedURL(forProjectRef: ref) {
            violations.append(.urlMismatch)
        }

        if !key.hasPrefix(publishableKeyPrefix) {
            violations.append(.keyPrefix)
        }
        if keyLooksLikeSecret(key) {
            violations.append(.keyLooksLikeSecret)
        }

        if bundleIDBase.isEmpty {
            violations.append(.bundleIDBaseMissing)
        } else if let configuration {
            let expected = expectedBundleIdentifier(base: bundleIDBase, configuration: configuration)
            if bundleIdentifier != expected {
                violations.append(.bundleIdentifier)
            }
        }

        return violations
    }

    /// Comparison helper. The returned string is not a connection default.
    public static func expectedURL(forProjectRef ref: String) -> String {
        "https://\(ref).supabase.co"
    }

    public static func expectedBundleIdentifier(
        base: String,
        configuration: AppBuildConfiguration
    ) -> String {
        switch configuration {
        case .debug:
            return base + ".dev"
        case .beta:
            return base + ".beta"
        case .release:
            return base
        }
    }

    private static func trim(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func keyLooksLikeSecret(_ key: String) -> Bool {
        let lower = key.lowercased()
        if lower.hasPrefix("eyj") { return true }
        if lower.contains("service_role") { return true }
        if lower.contains("sb_secret") { return true }
        return false
    }
}
