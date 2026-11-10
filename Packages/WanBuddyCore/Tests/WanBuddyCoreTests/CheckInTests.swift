import Foundation
import XCTest
@testable import WanBuddyCore

final class CheckInTests: XCTestCase {
    private let facility = CheckInFacility.tatsumiDemo
    private let dogs: Set<String> = ["dog-a", "dog-b"]
    private func instant(_ string: String) -> Date {
        ISO8601DateFormatter().date(from: string)!
    }
    private var noon: Date { instant("2026-11-10T03:00:00Z") } // 12:00 JST

    private func request(_ status: CheckInStatus = .now, planned: Date? = nil,
                         dogIDs: [String] = ["dog-a"], visibility: CheckInVisibility = .privateOnly) -> CheckInRequest {
        CheckInRequest(status: status, dogIDs: dogIDs, visibility: visibility, plannedAt: planned)
    }

    private func make(_ request: CheckInRequest, now: Date? = nil) throws -> CheckInRecord {
        try CheckInPolicy.makeRecord(request, ownerID: "owner-a", ownedDogIDs: dogs, facility: facility, now: now ?? noon)
    }

    func testNowExpiresAfterThreeHoursAndAtExactBoundary() throws {
        let record = try make(request())
        XCTAssertEqual(record.expiresAt, noon.addingTimeInterval(10800))
        XCTAssertTrue(record.isActive(at: record.expiresAt.addingTimeInterval(-0.001)))
        XCTAssertFalse(record.isActive(at: record.expiresAt))
        XCTAssertFalse(record.isActive(at: noon.addingTimeInterval(-1)))
        XCTAssertNil(record.plannedAt)
        XCTAssertEqual(record.visibility, .privateOnly)
    }

    func testExpiryIsCappedAtTokyoClosingTime() throws {
        let late = instant("2026-11-10T11:30:00Z") // 20:30 JST
        let record = try make(request(), now: late)
        XCTAssertEqual(record.expiresAt, instant("2026-11-10T12:00:00Z"))
    }

    func testOpeningAndClosingBoundariesUseFacilityTimeZone() throws {
        let opening = instant("2026-11-09T21:00:00Z") // next day 06:00 JST
        XCTAssertNoThrow(try make(request(), now: opening))
        XCTAssertThrowsError(try make(request(), now: opening.addingTimeInterval(-1))) {
            XCTAssertEqual($0 as? CheckInFailure, .closed)
        }
        XCTAssertThrowsError(try make(request(), now: instant("2026-11-10T12:00:00Z"))) {
            XCTAssertEqual($0 as? CheckInFailure, .closed)
        }
    }

    func testPlannedExpiresOneHourAfterArrivalAndNeverBecomesNow() throws {
        let arrival = noon.addingTimeInterval(1800)
        let record = try make(request(.planned, planned: arrival))
        XCTAssertEqual(record.expiresAt, arrival.addingTimeInterval(3600))
        XCTAssertEqual(record.plannedAt, arrival)
        var session = CheckInSession(ownerID: "owner-a")
        try session.register(request(.planned, planned: arrival), ownedDogIDs: dogs, facility: facility, now: noon, uptime: 100)
        session.refresh(at: arrival, uptime: 1900)
        XCTAssertEqual(session.activeRecords(at: arrival, uptime: 1900).first?.status, .planned)
        session.refresh(at: record.expiresAt, uptime: 5500)
        XCTAssertTrue(session.activeRecords(at: record.expiresAt, uptime: 5500).isEmpty)
        XCTAssertEqual(session.records.last?.endedReason, .expired)
    }

    func testPlannedCanBeRegisteredWhileClosedForNextOpening() throws {
        let midnight = instant("2026-11-09T15:00:00Z") // 00:00 JST
        let morning = instant("2026-11-09T21:00:00Z")
        XCTAssertNoThrow(try make(request(.planned, planned: morning), now: midnight))
        XCTAssertThrowsError(try make(request(.planned, planned: midnight), now: midnight))
    }

    func testPlannedGraceIsCappedAtClosingTime() throws {
        let arrival = instant("2026-11-10T11:45:00Z")
        XCTAssertEqual(try make(request(.planned, planned: arrival)).expiresAt, instant("2026-11-10T12:00:00Z"))
    }

    func testPlannedRangeAndTwoMinuteTolerance() throws {
        XCTAssertNoThrow(try make(request(.planned, planned: noon.addingTimeInterval(-120))))
        XCTAssertThrowsError(try make(request(.planned, planned: noon.addingTimeInterval(-121)))) {
            XCTAssertEqual($0 as? CheckInFailure, .pastPlan)
        }
        XCTAssertNoThrow(try make(request(.planned, planned: noon.addingTimeInterval(86400))))
        XCTAssertThrowsError(try make(request(.planned, planned: noon.addingTimeInterval(86401)))) {
            XCTAssertEqual($0 as? CheckInFailure, .distantPlan)
        }
        XCTAssertThrowsError(try make(request(.planned))) {
            XCTAssertEqual($0 as? CheckInFailure, .missingPlan)
        }
    }

    func testDogValidationAndDeduplication() throws {
        XCTAssertEqual(try make(request(dogIDs: ["dog-b", "dog-a", "dog-a"])).dogIDs, ["dog-a", "dog-b"])
        XCTAssertThrowsError(try make(request(dogIDs: []))) { XCTAssertEqual($0 as? CheckInFailure, .noDogs) }
        XCTAssertThrowsError(try make(request(dogIDs: ["other-dog"]))) { XCTAssertEqual($0 as? CheckInFailure, .otherDog) }
        XCTAssertThrowsError(try make(request(dogIDs: [""]))) { XCTAssertEqual($0 as? CheckInFailure, .otherDog) }
        let six = (1...6).map { "dog-\($0)" }
        XCTAssertThrowsError(try CheckInPolicy.makeRecord(request(dogIDs: six), ownerID: "owner-a",
                            ownedDogIDs: Set(six), facility: facility, now: noon)) {
            XCTAssertEqual($0 as? CheckInFailure, .tooManyDogs)
        }
    }

    func testInvalidOwnerAndFacilityAreRejected() {
        XCTAssertThrowsError(try CheckInPolicy.makeRecord(request(), ownerID: " ", ownedDogIDs: dogs, facility: facility, now: noon))
        let invalid = CheckInFacility(id: "bad", name: "Bad", timeZoneIdentifier: "Invalid/Zone", openHour: 6, closeHour: 21)
        XCTAssertThrowsError(try CheckInPolicy.makeRecord(request(), ownerID: "owner-a", ownedDogIDs: dogs, facility: invalid, now: noon))
    }

    func testVisibilityRoundTripsAndUnknownVisibilityIsRejected() throws {
        for visibility in CheckInVisibility.allCases {
            let record = try make(request(visibility: visibility))
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let data = try encoder.encode(record)
            XCTAssertEqual(try decoder.decode(CheckInRecord.self, from: data), record)
        }
        XCTAssertThrowsError(try JSONDecoder().decode(CheckInVisibility.self, from: Data("\"public\"".utf8)))
    }

    func testNowReplacesNowAndSwitchesSameFacilityPlan() throws {
        var session = CheckInSession(ownerID: "owner-a")
        let first = try session.register(request(), ownedDogIDs: dogs, facility: facility, now: noon, uptime: 100)
        let plan = try session.register(request(.planned, planned: noon.addingTimeInterval(1800)),
                                        ownedDogIDs: dogs, facility: facility, now: noon, uptime: 100)
        try session.register(request(), ownedDogIDs: dogs, facility: facility, now: noon, uptime: 100)
        XCTAssertEqual(session.records.first { $0.id == first.id }?.endedReason, .replaced)
        XCTAssertEqual(session.records.first { $0.id == plan.id }?.endedReason, .switchedToNow)
        XCTAssertEqual(session.activeRecords(at: noon, uptime: 100).map(\.status), [.now])
    }

    func testDifferentFacilityPlanIsNotCancelledByNow() throws {
        var session = CheckInSession(ownerID: "owner-a")
        let other = CheckInFacility(id: "other", name: "Other", timeZoneIdentifier: "Asia/Tokyo", openHour: 6, closeHour: 21)
        try session.register(request(.planned, planned: noon.addingTimeInterval(1800)), ownedDogIDs: dogs, facility: other, now: noon, uptime: 100)
        try session.register(request(), ownedDogIDs: dogs, facility: facility, now: noon, uptime: 100)
        XCTAssertEqual(session.activeRecords(at: noon, uptime: 100).count, 2)
    }

    func testNewPlanReplacesPreviousPlan() throws {
        var session = CheckInSession(ownerID: "owner-a")
        let first = try session.register(request(.planned, planned: noon.addingTimeInterval(1800)), ownedDogIDs: dogs, facility: facility, now: noon, uptime: 100)
        try session.register(request(.planned, planned: noon.addingTimeInterval(3600)), ownedDogIDs: dogs, facility: facility, now: noon, uptime: 100)
        XCTAssertEqual(session.records.first { $0.id == first.id }?.endedReason, .replaced)
        XCTAssertEqual(session.activeRecords(at: noon, uptime: 100).count, 1)
    }

    func testInvalidReplacementLeavesCurrentStateUntouched() throws {
        var session = CheckInSession(ownerID: "owner-a")
        try session.register(request(), ownedDogIDs: dogs, facility: facility, now: noon, uptime: 100)
        let before = session.records
        XCTAssertThrowsError(try session.register(request(dogIDs: []), ownedDogIDs: dogs, facility: facility, now: noon, uptime: 100))
        XCTAssertEqual(session.records, before)
    }

    func testCancelIsIdempotentAndSeparatesNowAndPlanReasons() throws {
        for status in CheckInStatus.allCases {
            var session = CheckInSession(ownerID: "owner-a")
            let record = try session.register(request(status, planned: status == .planned ? noon.addingTimeInterval(1800) : nil),
                                             ownedDogIDs: dogs, facility: facility, now: noon, uptime: 100)
            try session.cancel(id: record.id, at: noon, uptime: 100)
            let ended = session.records
            try session.cancel(id: record.id, at: noon.addingTimeInterval(5), uptime: 105)
            XCTAssertEqual(session.records, ended)
            XCTAssertEqual(session.records.first?.endedReason, status == .now ? .manual : .cancelled)
            XCTAssertTrue(session.activeRecords(at: noon, uptime: 105).isEmpty)
        }
    }

    func testForeignIDCannotBeCancelledAndOwnersDoNotShareState() throws {
        var first = CheckInSession(ownerID: "owner-a")
        let record = try first.register(request(), ownedDogIDs: dogs, facility: facility, now: noon, uptime: 100)
        var other = CheckInSession(ownerID: "owner-b")
        XCTAssertThrowsError(try other.cancel(id: record.id, at: noon, uptime: 100)) {
            XCTAssertEqual($0 as? CheckInFailure, .notFound)
        }
        XCTAssertEqual(first.activeRecords(at: noon, uptime: 100).count, 1)
        XCTAssertTrue(other.records.isEmpty)
    }

    func testExpiredReadIsHiddenWithoutTimerAndCancelKeepsExpiredReason() throws {
        var session = CheckInSession(ownerID: "owner-a")
        let record = try session.register(request(), ownedDogIDs: dogs, facility: facility, now: noon, uptime: 100)
        XCTAssertTrue(session.activeRecords(at: record.expiresAt, uptime: 10900).isEmpty)
        try session.cancel(id: record.id, at: record.expiresAt, uptime: 10900)
        XCTAssertEqual(session.records.last?.endedReason, .expired)
        XCTAssertEqual(session.records.last?.endedAt, record.expiresAt)
    }

    func testMonotonicDeadlinePreventsClockDriftFromExtendingLifetime() throws {
        var session = CheckInSession(ownerID: "owner-a")
        try session.register(request(), ownedDogIDs: dogs, facility: facility, now: noon, uptime: 100)
        session.refresh(at: noon.addingTimeInterval(100), uptime: 10900)
        XCTAssertTrue(session.activeRecords(at: noon.addingTimeInterval(100), uptime: 10900).isEmpty)
        XCTAssertEqual(session.records.last?.endedReason, .expired)
    }

    func testClockRollbackOrRebootClearsStateAndDoesNotRevive() throws {
        for reboot in [false, true] {
            var session = CheckInSession(ownerID: "owner-a")
            try session.register(request(), ownedDogIDs: dogs, facility: facility, now: noon, uptime: 100)
            session.refresh(at: noon.addingTimeInterval(10), uptime: 110)
            session.refresh(at: reboot ? noon.addingTimeInterval(20) : noon, uptime: reboot ? 1 : 120)
            XCTAssertTrue(session.clockWasReset)
            XCTAssertTrue(session.activeRecords(at: noon.addingTimeInterval(30), uptime: 130).isEmpty)
            session.refresh(at: noon.addingTimeInterval(40), uptime: 140)
            XCTAssertTrue(session.activeRecords(at: noon.addingTimeInterval(40), uptime: 140).isEmpty)
        }
    }

    func testForwardJumpExpiresPermanentlyAndHistoryIsBounded() throws {
        var session = CheckInSession(ownerID: "owner-a")
        for _ in 0..<20 {
            try session.register(request(), ownedDogIDs: dogs, facility: facility, now: noon, uptime: 100)
        }
        XCTAssertEqual(session.records.count, 10)
        session.refresh(at: noon.addingTimeInterval(20000), uptime: 200)
        session.refresh(at: noon, uptime: 300)
        XCTAssertTrue(session.activeRecords(at: noon, uptime: 300).isEmpty)
        session.reset()
        XCTAssertTrue(session.records.isEmpty)
    }
}
