public enum RootDestination: Equatable, Sendable {
    case welcome
    case onboarding
    case main
}

public enum RootRouter {
    public static func destination(hasSession: Bool, onboardingComplete: Bool) -> RootDestination {
        if !hasSession {
            return .welcome
        }
        if !onboardingComplete {
            return .onboarding
        }
        return .main
    }
}
