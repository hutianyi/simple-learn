import Foundation
import Combine
import StudyShell

@MainActor
final class AppDataStore: ObservableObject {
    enum RepairError: LocalizedError {
        case unavailable
        var errorDescription: String? { "补学机会已经结束，请正常开始今天的学习。" }
    }
    @Published private(set) var appData: AppData
    @Published private(set) var loadError: String?
    private let persistence: PersistenceService

    init(persistence: PersistenceService = .shared) {
        self.persistence = persistence
        do { appData = try persistence.load() }
        catch { appData = AppData(); loadError = error.localizedDescription }
    }

    var sessions: [SessionRecord] { appData.sessions.sorted { $0.completedAt > $1.completedAt } }
    func repairOffer(now: Date = Date(), calendar: Calendar = .current) -> OneDayStreakRepair.Offer? {
        guard loadError == nil else { return nil }
        return OneDayStreakRepair.offer(completedKeys: PracticeActivity(sessions: sessions, now: now, calendar: calendar).completedKeys,
            handledKeys: appData.handledRepairDays ?? [], now: now, calendar: calendar)
    }
    func handleRepair(_ offer: OneDayStreakRepair.Offer, now: Date = Date()) throws {
        guard repairOffer(now: now) == offer else { throw RepairError.unavailable }
        var updated = appData
        updated.handledRepairDays = (updated.handledRepairDays ?? []).union([offer.yesterdayKey])
        try persistence.save(updated)
        appData = updated
    }
    func exportData() throws -> Data {
        guard loadError == nil else { throw CocoaError(.fileReadCorruptFile) }
        return try SuanBackup.encode(appData)
    }
    func add(_ session: SessionRecord) throws {
        guard loadError == nil else { throw CocoaError(.fileReadCorruptFile) }
        var updated = appData
        if !updated.sessions.contains(where: { $0.id == session.id }) { updated.sessions.append(session) }
        try persistence.save(updated); appData = updated
    }
    func delete(_ session: SessionRecord) throws {
        guard loadError == nil else { throw CocoaError(.fileReadCorruptFile) }
        let updatedData = appData.removingSession(withID: session.id)
        try persistence.save(updatedData); appData = updatedData
    }
    func restore(_ data: AppData) throws {
        try persistence.save(data); appData = data; loadError = nil
    }
}
