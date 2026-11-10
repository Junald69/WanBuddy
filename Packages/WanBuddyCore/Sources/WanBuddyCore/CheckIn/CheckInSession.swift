import Foundation

/// Value-based state machine for a single owner. A server adapter must enforce auth/atomicity itself.
/// Keeps at most the latest 10 transitions in memory; no disk persistence or network calls.
public struct CheckInSession: Sendable {
    public let ownerID: String
    public private(set) var records: [CheckInRecord] = []
    public private(set) var clockWasReset = false
    private var deadlines: [UUID: TimeInterval] = [:]
    private var lastWall: Date?
    private var lastUptime: TimeInterval?

    public init(ownerID: String) { self.ownerID = ownerID }

    public func activeRecords(at now: Date, uptime: TimeInterval) -> [CheckInRecord] {
        guard now.timeIntervalSince1970.isFinite, uptime.isFinite else { return [] }
        if let wall = lastWall, now < wall { return [] }
        if let last = lastUptime, uptime < last { return [] }
        return records.filter { record in
            guard let deadline = deadlines[record.id] else { return false }
            return record.isActive(at: now) && uptime < deadline
        }
    }

    /// No timer/cron dependency: read filtering also excludes exact-boundary expiry.
    public mutating func refresh(at now: Date, uptime: TimeInterval) {
        guard now.timeIntervalSince1970.isFinite, uptime.isFinite else {
            clearForClockChange(at: lastWall ?? Date(timeIntervalSince1970: 0))
            return
        }
        if (lastWall.map { now < $0 } ?? false) || (lastUptime.map { uptime < $0 } ?? false) {
            clearForClockChange(at: lastWall ?? now)
        } else {
            for index in records.indices where records[index].endedAt == nil {
                let record = records[index]
                if now >= record.expiresAt || uptime >= (deadlines[record.id] ?? -.infinity) {
                    records[index].end(at: record.expiresAt, reason: .expired)
                    deadlines.removeValue(forKey: record.id)
                }
            }
        }
        lastWall = now
        lastUptime = uptime
    }

    @discardableResult
    public mutating func register(
        _ request: CheckInRequest, ownedDogIDs: Set<String>, facility: CheckInFacility,
        now: Date, uptime: TimeInterval
    ) throws -> CheckInRecord {
        guard uptime.isFinite, uptime >= 0 else { throw CheckInFailure.clock }
        // Validate before mutation: a bad submission must not replace an existing record.
        let record = try CheckInPolicy.makeRecord(request, ownerID: ownerID, ownedDogIDs: ownedDogIDs, facility: facility, now: now)
        refresh(at: now, uptime: uptime)
        for index in records.indices where records[index].endedAt == nil {
            let previous = records[index]
            if previous.status == record.status {
                records[index].end(at: now, reason: .replaced)
                deadlines.removeValue(forKey: previous.id)
            } else if record.status == .now && previous.status == .planned && previous.facilityID == facility.id {
                records[index].end(at: now, reason: .switchedToNow)
                deadlines.removeValue(forKey: previous.id)
            }
        }
        records.append(record)
        deadlines[record.id] = uptime + record.expiresAt.timeIntervalSince(now)
        if records.count > 10 {
            let activeIDs = Set(records.filter { $0.endedAt == nil }.map(\.id))
            let oldIDs = records.filter { !activeIDs.contains($0.id) }.prefix(records.count - 10).map(\.id)
            records.removeAll { oldIDs.contains($0.id) }
        }
        clockWasReset = false
        return record
    }

    /// Owner scoping comes from this session; unknown/foreign IDs cannot be ended.
    public mutating func cancel(id: UUID, at now: Date, uptime: TimeInterval) throws {
        refresh(at: now, uptime: uptime)
        guard let index = records.firstIndex(where: { $0.id == id }) else { throw CheckInFailure.notFound }
        guard records[index].endedAt == nil else { return }
        let reason: CheckInEndReason = records[index].status == .now ? .manual : .cancelled
        records[index].end(at: now, reason: reason)
        deadlines.removeValue(forKey: id)
    }

    public mutating func reset() {
        records.removeAll()
        deadlines.removeAll()
        lastWall = nil
        lastUptime = nil
        clockWasReset = false
    }

    private mutating func clearForClockChange(at instant: Date) {
        for index in records.indices where records[index].endedAt == nil {
            let reason: CheckInEndReason = records[index].status == .now ? .manual : .cancelled
            records[index].end(at: instant, reason: reason)
        }
        deadlines.removeAll()
        clockWasReset = true
    }
}
