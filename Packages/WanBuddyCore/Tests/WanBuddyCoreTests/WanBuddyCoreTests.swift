import XCTest
@testable import WanBuddyCore

final class ConfigValidatorTests: XCTestCase {
    private let base = "com.junald69.wanbuddy"
    private let devRef = WanBuddyKnownEnvironment.developmentProjectRef
    private let devKey = "sb_publishable_rhef8TN72C7vSi6itEHl_g__VXiEkhN"
    private let prodRef = "abcdefghijklmnopqrst"

    func testEmptyReleaseFailsAndDoesNotSubstituteDevelopment() {
        let result = ConfigValidator.validate(release())
        guard case .failure(let failure) = result else {
            return XCTFail("empty Release must fail")
        }
        let violations = failure.violations
        XCTAssertTrue(violations.contains(.empty("SUPABASE_URL")))
        XCTAssertTrue(violations.contains(.empty("SUPABASE_PUBLISHABLE_KEY")))
        XCTAssertTrue(violations.contains(.empty("SUPABASE_PROJECT_REF")))
        XCTAssertFalse(String(describing: violations).contains("https://\(devRef)"))
    }

    func testReleaseWithDevelopmentRefFails() {
        var raw = release()
        raw.projectRef = devRef
        raw.supabaseURL = "https://\(devRef).supabase.co"
        raw.publishableKey = devKey
        let violations = ConfigValidator.violations(in: raw)
        XCTAssertTrue(violations.contains(.releaseUsesDevelopmentRef))
    }

    func testValidReleasePasses() {
        var raw = release()
        raw.projectRef = prodRef
        raw.supabaseURL = "https://\(prodRef).supabase.co"
        raw.publishableKey = "sb_publishable_production_example"
        let result = ConfigValidator.validate(raw)
        guard case .success(let config) = result else {
            return XCTFail("expected success, got \(String(describing: result))")
        }
        XCTAssertEqual(config.configuration, .release)
        XCTAssertEqual(config.projectRef, prodRef)
        XCTAssertNotEqual(config.supabaseURL, "https://\(devRef).supabase.co")
    }

    func testDebugAndBetaAcceptDevelopmentOnly() {
        XCTAssertEqual(try success(debug()), debug().configurationName)
        var betaRaw = debug()
        betaRaw.configurationName = "beta"
        betaRaw.bundleIdentifier = "\(base).beta"
        XCTAssertTrue(ConfigValidator.violations(in: betaRaw).isEmpty)

        var wrong = debug()
        wrong.projectRef = prodRef
        wrong.supabaseURL = "https://\(prodRef).supabase.co"
        XCTAssertTrue(ConfigValidator.violations(in: wrong).contains(.configurationRefMismatch))
    }

    func testDebugRejectsBlockedProductionRef() {
        let raw = debug()
        let violations = ConfigValidator.violations(
            in: raw,
            blockedProductionProjectRefs: [devRef]
        )
        XCTAssertTrue(violations.contains(.refIsBlockedProduction))
    }

    func testBundleIdentifierMustMatchConfiguration() {
        var raw = debug()
        raw.bundleIdentifier = base
        XCTAssertTrue(ConfigValidator.violations(in: raw).contains(.bundleIdentifier))

        var releaseRaw = validRelease()
        releaseRaw.bundleIdentifier = "\(base).dev"
        XCTAssertTrue(ConfigValidator.violations(in: releaseRaw).contains(.bundleIdentifier))

        var betaAsDev = debug()
        betaAsDev.configurationName = "beta"
        XCTAssertTrue(ConfigValidator.violations(in: betaAsDev).contains(.bundleIdentifier))
    }

    func testKeyRules() {
        var legacy = validRelease()
        legacy.publishableKey = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.payload.sig"
        let legacyViolations = ConfigValidator.violations(in: legacy)
        XCTAssertTrue(legacyViolations.contains(.keyPrefix))
        XCTAssertTrue(legacyViolations.contains(.keyLooksLikeSecret))

        var secret = validRelease()
        secret.publishableKey = "sb_secret_not_a_client_key"
        XCTAssertTrue(ConfigValidator.violations(in: secret).contains(.keyLooksLikeSecret))

        var service = validRelease()
        service.publishableKey = "sb_publishable_but_service_role_inside"
        XCTAssertTrue(ConfigValidator.violations(in: service).contains(.keyLooksLikeSecret))

        var missingPrefix = validRelease()
        missingPrefix.publishableKey = "publishable_missing_prefix_value"
        XCTAssertTrue(ConfigValidator.violations(in: missingPrefix).contains(.keyPrefix))
        XCTAssertFalse(ConfigValidator.violations(in: missingPrefix).contains(.keyLooksLikeSecret))
    }

    func testRefShapeAndURLMustAgree() {
        var short = validRelease()
        short.projectRef = "abc"
        short.supabaseURL = "https://abc.supabase.co"
        let shortViolations = ConfigValidator.violations(in: short)
        XCTAssertTrue(shortViolations.contains(.refLength))
        XCTAssertTrue(shortViolations.contains(.refCharset))

        var mismatch = validRelease()
        mismatch.supabaseURL = "https://\(devRef).supabase.co"
        XCTAssertTrue(ConfigValidator.violations(in: mismatch).contains(.urlMismatch))

        var upper = validRelease()
        upper.projectRef = "ABCDEFGHIJKLMNOPQRST"
        upper.supabaseURL = "https://ABCDEFGHIJKLMNOPQRST.supabase.co"
        XCTAssertTrue(ConfigValidator.violations(in: upper).contains(.refCharset))
    }

    func testUnknownConfigurationFails() {
        var raw = validRelease()
        raw.configurationName = "Staging"
        XCTAssertTrue(ConfigValidator.violations(in: raw).contains(.unknownConfiguration("Staging")))
    }

    func testWhitespaceIsEmpty() {
        var raw = release()
        raw.supabaseURL = "   "
        raw.publishableKey = "\n"
        raw.projectRef = " "
        XCTAssertTrue(ConfigValidator.violations(in: raw).contains(.empty("SUPABASE_URL")))
        XCTAssertTrue(ConfigValidator.violations(in: raw).contains(.empty("SUPABASE_PUBLISHABLE_KEY")))
        XCTAssertTrue(ConfigValidator.violations(in: raw).contains(.empty("SUPABASE_PROJECT_REF")))
    }

    private func success(_ raw: RawAppConfig) throws -> String {
        let result = ConfigValidator.validate(raw)
        guard case .success = result else {
            XCTFail("expected success, got \(String(describing: result))")
            return ""
        }
        return raw.configurationName
    }

    private func release() -> RawAppConfig {
        RawAppConfig(
            configurationName: "release",
            supabaseURL: "",
            publishableKey: "",
            projectRef: "",
            bundleIdentifier: base,
            bundleIDBase: base
        )
    }

    private func validRelease() -> RawAppConfig {
        var raw = release()
        raw.projectRef = prodRef
        raw.supabaseURL = "https://\(prodRef).supabase.co"
        raw.publishableKey = "sb_publishable_production_example"
        return raw
    }

    private func debug() -> RawAppConfig {
        RawAppConfig(
            configurationName: "debug",
            supabaseURL: "https://\(devRef).supabase.co",
            publishableKey: devKey,
            projectRef: devRef,
            bundleIdentifier: "\(base).dev",
            bundleIDBase: base
        )
    }
}

final class WBErrorMessageTests: XCTestCase {
    func testKnownCodes() {
        XCTAssertEqual(
            WBErrorMessages.message(forCode: "WB201"),
            "ドッグランの利用時間(6時〜21時)外です"
        )
        XCTAssertEqual(WBErrorMessages.message(forCode: "WB203"), "予定時刻が過去です")
        XCTAssertEqual(WBErrorMessages.message(forCode: "WB001"), "このQRコードは使用できません")
        XCTAssertEqual(WBErrorMessages.message(forCode: "WB401"), "ログインが必要です")
    }

    func testExtractsCodeFromWrappedText() {
        let message = WBErrorMessages.message(extractingFrom: "PostgrestError(code: \"WB205\", message: \"nope\")")
        XCTAssertEqual(message, "閉園時刻を超えて延長できません")
    }

    func testUnknownCodeIsGeneric() {
        XCTAssertEqual(WBErrorMessages.message(forCode: "WB999"), WBErrorMessages.generic)
        XCTAssertEqual(WBErrorMessages.message(extractingFrom: "network timeout"), WBErrorMessages.generic)
    }
}

final class SignInFailureMessageTests: XCTestCase {
    func testInvalidCredentials() {
        XCTAssertEqual(
            SignInFailureMessage.message(forServerText: "AuthError: Invalid login credentials"),
            SignInFailureMessage.invalidCredentials
        )
    }

    func testGeneric() {
        XCTAssertEqual(
            SignInFailureMessage.message(forServerText: "offline"),
            SignInFailureMessage.generic
        )
    }
}

final class AvatarPaletteTests: XCTestCase {
    func testStableColorForTheSameID() {
        XCTAssertEqual(AvatarPalette.hex(for: "dog-1"), AvatarPalette.hex(for: "dog-1"))
    }

    func testIndexStaysInsideThePalette() {
        for id in ["", "a", "user-123", "モカ", String(repeating: "x", count: 40)] {
            let index = AvatarPalette.index(for: id)
            XCTAssertGreaterThanOrEqual(index, 0)
            XCTAssertLessThan(index, AvatarPalette.hexColors.count)
            XCTAssertTrue(AvatarPalette.hexColors.contains(AvatarPalette.hex(for: id)))
        }
    }
}

final class OnboardingValidatorTests: XCTestCase {
    func testValidDraft() {
        let draft = OnboardingDraft(
            nickname: "じゅん",
            dogs: [OnboardingDog(id: "1", name: "モカ", breed: "柴")],
            acceptedTerms: true
        )
        XCTAssertTrue(OnboardingValidator.violations(in: draft).isEmpty)
    }

    func testRejectsBlankNicknameTooManyDogsAndMissingTerms() {
        let dogs = (0..<6).map { OnboardingDog(id: "\($0)", name: "犬\($0)", breed: "") }
        let draft = OnboardingDraft(nickname: "  ", dogs: dogs, acceptedTerms: false)
        let violations = OnboardingValidator.violations(in: draft)
        XCTAssertTrue(violations.contains(.nicknameLength))
        XCTAssertTrue(violations.contains(.dogCount))
        XCTAssertTrue(violations.contains(.termsNotAccepted))
    }

    func testRejectsEmptyDogName() {
        let draft = OnboardingDraft(
            nickname: "じゅん",
            dogs: [OnboardingDog(id: "1", name: " ", breed: "")],
            acceptedTerms: true
        )
        XCTAssertEqual(OnboardingValidator.violations(in: draft), [.dogNameLength(index: 0)])
    }
}

final class RootRouterTests: XCTestCase {
    func testRoutes() {
        XCTAssertEqual(RootRouter.destination(hasSession: false, onboardingComplete: false), .welcome)
        XCTAssertEqual(RootRouter.destination(hasSession: false, onboardingComplete: true), .welcome)
        XCTAssertEqual(RootRouter.destination(hasSession: true, onboardingComplete: false), .onboarding)
        XCTAssertEqual(RootRouter.destination(hasSession: true, onboardingComplete: true), .main)
    }
}

final class BuildFeatureTests: XCTestCase {
    func testDevLoginIsCompiledIntoTheDebugTestBuild() {
        XCTAssertTrue(
            BuildFeatures.devLoginCompiledIn,
            "swift test builds the debug configuration, which must include DEV_LOGIN"
        )
    }
}

#if DEV_LOGIN
final class MockRepositoryTests: XCTestCase {
    func testMockSignInPersistsSessionUntilSignOut() async throws {
        let auth = MockAuthRepository()
        let session = try await auth.signInWithEmail(email: "dog@example.com", password: "secret")
        let current = await auth.currentSession()
        XCTAssertEqual(current, session)
        try await auth.signOut()
        let after = await auth.currentSession()
        XCTAssertNil(after)
    }

    func testMockSignInRejectsBlankPassword() async {
        let auth = MockAuthRepository()
        do {
            _ = try await auth.signInWithEmail(email: "dog@example.com", password: "")
            XCTFail("expected invalid credentials")
        } catch MockAuthError.invalidCredentials {
            let current = await auth.currentSession()
            XCTAssertNil(current)
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    func testMockProfileUsesPrototypeDogs() async throws {
        let dogs = try await MockProfileRepository().fetchDogs(ownerID: "owner")
        XCTAssertEqual(dogs.map(\.name), ["モカ", "ルル", "コタロウ", "ソラ", "ミミ"])
    }
}
#endif
