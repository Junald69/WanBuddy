#if DEV_LOGIN
import Foundation
import Observation
import WanBuddyCore

/// No Supabase client, disk storage, or shared user state. Destroyed on logout.
@MainActor
@Observable
final class CheckInDemoModel {
    private(set) var session: CheckInSession
    private(set) var now = Date()
    private(set) var uptime = ProcessInfo.processInfo.systemUptime
    private(set) var demoOffset: TimeInterval = 0
    var errorMessage: String?
    let facility = CheckInFacility.tatsumiDemo

    init(ownerID: String) {
        session = CheckInSession(ownerID: ownerID)
    }

    var active: [CheckInRecord] { session.activeRecords(at: now, uptime: uptime) }
    var latestEnded: CheckInRecord? { session.records.last(where: { $0.endedAt != nil }) }

    func refresh() {
        now = Date().addingTimeInterval(demoOffset)
        uptime = ProcessInfo.processInfo.systemUptime + demoOffset
        session.refresh(at: now, uptime: uptime)
    }

    @discardableResult
    func submit(_ request: CheckInRequest, ownedDogIDs: Set<String>) -> Bool {
        refresh()
        do {
            try session.register(request, ownedDogIDs: ownedDogIDs, facility: facility, now: now, uptime: uptime)
            errorMessage = nil
            return true
        } catch let failure as CheckInFailure {
            errorMessage = failure.message
        } catch {
            errorMessage = "チェックインを保存できませんでした"
        }
        return false
    }

    func cancel(_ record: CheckInRecord) {
        refresh()
        do {
            try session.cancel(id: record.id, at: now, uptime: uptime)
            errorMessage = nil
        } catch {
            errorMessage = "チェックインを取り消せませんでした"
        }
    }

    func advanceDemo(by seconds: TimeInterval) {
        demoOffset += seconds
        refresh()
    }

    func returnToRealTime() {
        demoOffset = 0
        refresh()
    }
}
#endif
