import Foundation

public struct OnboardingDog: Equatable, Sendable, Codable, Identifiable {
    public var id: String
    public var name: String
    public var breed: String

    public init(id: String, name: String, breed: String) {
        self.id = id
        self.name = name
        self.breed = breed
    }
}

public struct OnboardingDraft: Equatable, Sendable, Codable {
    public var nickname: String
    public var dogs: [OnboardingDog]
    public var acceptedTerms: Bool

    public init(nickname: String, dogs: [OnboardingDog], acceptedTerms: Bool) {
        self.nickname = nickname
        self.dogs = dogs
        self.acceptedTerms = acceptedTerms
    }
}

public enum OnboardingRules {
    public static let nicknameMax = 20
    public static let dogNameMax = 30
    public static let breedMax = 50
    public static let minDogs = 1
    public static let maxDogs = 5
}

public enum OnboardingViolation: Equatable, Sendable {
    case nicknameLength
    case dogCount
    case dogNameLength(index: Int)
    case breedLength(index: Int)
    case termsNotAccepted
}

public enum OnboardingValidator {
    public static func violations(in draft: OnboardingDraft) -> [OnboardingViolation] {
        var violations: [OnboardingViolation] = []
        let nickname = draft.nickname.trimmingCharacters(in: .whitespacesAndNewlines)
        if nickname.isEmpty || nickname.count > OnboardingRules.nicknameMax {
            violations.append(.nicknameLength)
        }
        if draft.dogs.count < OnboardingRules.minDogs || draft.dogs.count > OnboardingRules.maxDogs {
            violations.append(.dogCount)
        }
        for (index, dog) in draft.dogs.enumerated() {
            let name = dog.name.trimmingCharacters(in: .whitespacesAndNewlines)
            if name.isEmpty || name.count > OnboardingRules.dogNameMax {
                violations.append(.dogNameLength(index: index))
            }
            let breed = dog.breed.trimmingCharacters(in: .whitespacesAndNewlines)
            if breed.count > OnboardingRules.breedMax {
                violations.append(.breedLength(index: index))
            }
        }
        if !draft.acceptedTerms {
            violations.append(.termsNotAccepted)
        }
        return violations
    }
}
