import CoreData
import Foundation
import Combine
import StudyShell

@MainActor
final class PersistenceController: ObservableObject {
    @Published private(set) var loadErrorMessage: String?
    @Published private(set) var isReady = false

    let container: NSPersistentContainer

    static var modelBundle: Bundle {
        #if SWIFT_PACKAGE
        return .module
        #else
        return Bundle(for: PersistenceController.self)
        #endif
    }

    init(inMemory: Bool = false) {
        guard let url = Self.modelBundle.url(forResource: "WordMemoryCards", withExtension: "momd"),
              let model = NSManagedObjectModel(contentsOf: url) else {
            container = NSPersistentContainer(name: "WordMemoryCards", managedObjectModel: NSManagedObjectModel())
            loadErrorMessage = "缺少简单记数据库模型，请保留数据并重新构建 App。"
            return
        }
        container = NSPersistentContainer(name: "WordMemoryCards", managedObjectModel: model)
        if !inMemory {
            do {
                let url = try ModuleStorage.directory("SimpleJi").appendingPathComponent("WordMemoryCards.sqlite")
                container.persistentStoreDescriptions = [NSPersistentStoreDescription(url: url)]
            } catch { loadErrorMessage = error.localizedDescription; return }
        }

        if inMemory {
            let description = NSPersistentStoreDescription()
            description.type = NSInMemoryStoreType
            description.shouldAddStoreAsynchronously = false
            container.persistentStoreDescriptions = [description]
        }

        for description in container.persistentStoreDescriptions {
            description.shouldMigrateStoreAutomatically = true
            description.shouldInferMappingModelAutomatically = true
        }

        container.loadPersistentStores { [weak self] _, error in
            guard let self else { return }
            if let error {
                Task { @MainActor in
                    self.loadErrorMessage = error.localizedDescription
                }
                return
            }

            let context = self.container.newBackgroundContext()
            context.mergePolicy = NSErrorMergePolicy
            context.undoManager = nil
            do {
                try context.performAndWait {
                    _ = try FSRSMigrationService.migrateAll(in: context)
                }
                Task { @MainActor in self.isReady = true }
            } catch {
                Task { @MainActor in
                    self.loadErrorMessage = "升级学习记录失败：\(error.localizedDescription)"
                }
            }
        }

        container.viewContext.automaticallyMergesChangesFromParent = true
        container.viewContext.mergePolicy = NSErrorMergePolicy
        container.viewContext.undoManager = nil
    }

    func dismissLoadError() {
        loadErrorMessage = nil
    }

    func newBackgroundContext() -> NSManagedObjectContext {
        let context = container.newBackgroundContext()
        context.mergePolicy = NSErrorMergePolicy
        context.undoManager = nil
        return context
    }
}
