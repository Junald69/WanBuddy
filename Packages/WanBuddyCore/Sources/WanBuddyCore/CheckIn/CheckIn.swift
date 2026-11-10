import Foundation

public enum CheckInStatus: String, Codable, CaseIterable, Sendable {
    case now
    case planned
}

public enum CheckInVisibility: String, Codable, CaseIterable, Hashable, Sendable {
    case privateOnly = "private"
    case friends
}

public enum CheckInEndReason: String, Codable, Sendable {
    case manual
    case expired
    case switchedToNow = "switched_to_now"
    case cancelled
    case replaced
}

/// Absolute instants, matching the future presence RPC's vocabulary. No location coordinates.
public struct CheckInRecord: Equatable, Codable, Identifiable, Sendable {
    public let id: UUID
    public let ownerID: String
    public let facilityID: String
    public let dogIDs: [String]
    public let status: CheckInStatus
    public let visibility: CheckInVisibility
    public let plannedAt: Date?
    public let startedAt: Date
    public let expiresAt: Date
    public private(set) var endedAt: Date?
    public private(set) var endedReason: CheckInEndReason?

    public func isActive(at now: Date) -> Bool {
        endedAt == nil && now >= startedAt && now < expiresAt
    }

    mutating func end(at now: Date, reason: CheckInEndReason) {
        guard endedAt == nil else { return }
        endedAt = max(startedAt, min(now, expiresAt))
        endedReason = reason
    }
}

public struct CheckInFacility: Equatable, Sendable {
    public let id: String
    public let name: String
    public let timeZoneIdentifier: String
    public let openHour: Int
    public let closeHour: Int

    public init(id: String, name: String, timeZoneIdentifier: String, openHour: Int, closeHour: Int) {
        self.id = id
        self.name = name
        self.timeZoneIdentifier = timeZoneIdentifier
        self.openHour = openHour
        self.closeHour = closeHour
    }

    /// Demo identifier is intentionally not a Supabase facility UUID.
    public static let tatsumiDemo = CheckInFacility(
        id: "demo-tatsumi-no-mori-dogrun", name: "たつみの森ドッグラン",
        timeZoneIdentifier: "Asia/Tokyo", openHour: 6, closeHour: 21
    )

    public func closingTime(for instant: Date) throws -> Date {
        guard let zone = TimeZone(identifier: timeZoneIdentifier),
              (0...23).contains(openHour), (1...23).contains(closeHour), openHour < closeHour else {
            throw CheckInFailure.facility
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let day = calendar.startOfDay(for: instant)
        guard let open = calendar.date(bySettingHour: openHour, minute: 0, second: 0, of: day),
              let close = calendar.date(bySettingHour: closeHour, minute: 0, second: 0, of: day),
              instant >= open, instant < close else { throw CheckInFailure.closed }
        return close
    }
}

public struct CheckInRequest: Equatable, Sendable {
    public let status: CheckInStatus
    public let dogIDs: [String]
    public let visibility: CheckInVisibility
    public let plannedAt: Date?

    public init(status: CheckInStatus, dogIDs: [String], visibility: CheckInVisibility = .privateOnly, plannedAt: Date? = nil) {
        self.status = status
        self.dogIDs = dogIDs
        self.visibility = visibility
        self.plannedAt = plannedAt
    }
}

public enum CheckInFailure: Error, Equatable, Sendable {
    case owner, facility, noDogs, otherDog, tooManyDogs, missingPlan, pastPlan, distantPlan, closed, clock, notFound

    public var message: String {
        let code: String
        switch self {
        case .owner: code = "WB401"
        case .facility: code = "WB101"
        case .noDogs: code = "WB102"
        case .otherDog: code = "WB103"
        case .tooManyDogs: code = "WB107"
        case .missingPlan: code = "WB105"
        case .pastPlan: code = "WB203"
        case .distantPlan: code = "WB204"
        case .closed: code = "WB201"
        case .notFound: code = "WB207"
        case .clock: return "時刻を確認して、もう一度お試しください"
        }
        return WBErrorMessages.message(forCode: code)
    }
}

public enum CheckInPolicy {
    public static let nowLifetime: TimeInterval = 3 * 60 * 60
    public static let plannedGrace: TimeInterval = 60 * 60
    public static let maxPlanAhead: TimeInterval = 24 * 60 * 60
    public static let pastPlanTolerance: TimeInterval = 2 * 60

    public static func makeRecord(
        _ request: CheckInRequest, ownerID: String, ownedDogIDs: Set<String>,
        facility: CheckInFacility, now: Date, id: UUID = UUID()
    ) throws -> CheckInRecord {
        guard now.timeIntervalSince1970.isFinite else { throw CheckInFailure.clock }
        guard !ownerID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw CheckInFailure.owner }
        guard !facility.id.isEmpty else { throw CheckInFailure.facility }
        let dogs = Array(Set(request.dogIDs)).sorted()
        guard !dogs.isEmpty else { throw CheckInFailure.noDogs }
        guard dogs.count <= OnboardingRules.maxDogs else { throw CheckInFailure.tooManyDogs }
        guard dogs.allSatisfy({ !$0.isEmpty && ownedDogIDs.contains($0) }) else { throw CheckInFailure.otherDog }
        let basis: Date
        let planned: Date?
        let lifetime: TimeInterval
        switch request.status {
        case .now:
            basis = now
            planned = nil
            lifetime = nowLifetime
        case .planned:
            guard let date = request.plannedAt, date.timeIntervalSince1970.isFinite else { throw CheckInFailure.missingPlan }
            guard date >= now.addingTimeInterval(-pastPlanTolerance) else { throw CheckInFailure.pastPlan }
            guard date <= now.addingTimeInterval(maxPlanAhead) else { throw CheckInFailure.distantPlan }
            basis = date
            planned = date
            lifetime = plannedGrace
        }
        let expiry = min(basis.addingTimeInterval(lifetime), try facility.closingTime(for: basis))
        guard expiry > now else { throw CheckInFailure.closed }
        return CheckInRecord(id: id, ownerID: ownerID, facilityID: facility.id, dogIDs: dogs,
                             status: request.status, visibility: request.visibility, plannedAt: planned,
                             startedAt: now, expiresAt: expiry)
    }
}
