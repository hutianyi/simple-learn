import Foundation
import Combine

@MainActor
final class AppDataStore: ObservableObject {
    @Published private(set) var appData: AppData
    @Published private(set) var loadError: String?
    private let persistence: PersistenceService

    init(persistence: PersistenceService = .shared) {
        self.persistence = persistence
        do { appData = try persistence.load() }
        catch { appData = AppData(); loadError = error.localizedDescription }
    }

    var sessions: [SessionRecord] { appData.sessions.sorted { $0.completedAt > $1.completedAt } }
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
