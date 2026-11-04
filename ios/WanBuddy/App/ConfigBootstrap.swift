import Foundation
import WanBuddyCore

enum ConfigBootstrap {
    /// Reads the built Info.plist and stops the process when the configuration is unusable.
    /// Missing values stay empty. They are never replaced with the Development project.
    static func loadOrStop(bundle: Bundle = .main) -> AppConfig {
        let info = bundle.infoDictionary
        let bundleIdentifier: String
        if let identifier = bundle.bundleIdentifier {
            bundleIdentifier = identifier
        } else {
            bundleIdentifier = ""
        }
        let raw = RawAppConfig(
            configurationName: string(info, "WANBUDDY_CONFIGURATION"),
            supabaseURL: string(info, "SUPABASE_URL"),
            publishableKey: string(info, "SUPABASE_PUBLISHABLE_KEY"),
            projectRef: string(info, "SUPABASE_PROJECT_REF"),
            bundleIdentifier: bundleIdentifier,
            bundleIDBase: string(info, "WANBUDDY_BUNDLE_ID_BASE")
        )
        switch ConfigValidator.validate(raw) {
        case .success(let config):
            return config
        case .failure(let failure):
            let summary = failure.violations.map(\.description).joined(separator: ", ")
            fatalError(
                "WanBuddy configuration rejected: \(summary). Refusing to launch. There is no Development fallback."
            )
        }
    }

    private static func string(_ info: [String: Any]?, _ key: String) -> String {
        guard let info else { return "" }
        guard let value = info[key] else { return "" }
        guard let text = value as? String else { return "" }
        return text
    }
}
