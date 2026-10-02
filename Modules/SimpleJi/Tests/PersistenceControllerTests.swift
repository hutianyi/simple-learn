import CoreData
import XCTest
@testable import WordMemoryCards

final class PersistenceControllerTests: XCTestCase {
    @MainActor
    func testModuleReentryPreservesEntityResolutionAndStoreIsolation() throws {
        let first = PersistenceController(inMemory: true)
        let second = PersistenceController(inMemory: true)
        let context = first.container.viewContext
        let word = NSEntityDescription.insertNewObject(forEntityName: "WordEntity", into: context)
        word.setValuesForKeys([
            "id": UUID(), "english": "apple", "normalizedEnglish": "apple",
            "chinese": "苹果", "createdAt": Date(), "updatedAt": Date()
        ])
        try context.save()

        let inferred = NSFetchRequest<WordEntity>()
        inferred.entity = WordEntity.entity()
        XCTAssertEqual(inferred.entity?.name, "WordEntity")
        guard inferred.entity != nil else { return }
        XCTAssertEqual(try context.fetch(inferred).map(\.english), ["apple"])
        XCTAssertEqual(try second.container.viewContext.count(for: WordEntity.fetchRequest()), 0)
        XCTAssertTrue(first.container.managedObjectModel === second.container.managedObjectModel)
        XCTAssertFalse(first.container.viewContext === second.container.viewContext)
    }

    @MainActor
    func testPreviousStoreMigratesWithoutLosingWords() throws {
        let bundle = PersistenceController.modelBundle
        let modelDirectory = try XCTUnwrap(bundle.url(forResource: "WordMemoryCards", withExtension: "momd"))
        let oldModel = try XCTUnwrap(NSManagedObjectModel(contentsOf: modelDirectory.appendingPathComponent("WordMemoryCards.mom")))
        let newModel = PersistenceController(inMemory: true).container.managedObjectModel
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sqlite")
        let originalID = UUID()
        let oldCoordinator = NSPersistentStoreCoordinator(managedObjectModel: oldModel)
        let oldStore = try oldCoordinator.addPersistentStore(ofType: NSSQLiteStoreType, configurationName: nil, at: url)
        let oldContext = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
        oldContext.persistentStoreCoordinator = oldCoordinator
        let word = NSEntityDescription.insertNewObject(forEntityName: "WordEntity", into: oldContext)
        word.setValuesForKeys(["id": originalID, "english": "zebra", "normalizedEnglish": "zebra",
                              "chinese": "斑马", "createdAt": Date(), "updatedAt": Date()])
        try oldContext.save()
        oldContext.reset()
        try oldCoordinator.remove(oldStore)
        let newCoordinator = NSPersistentStoreCoordinator(managedObjectModel: newModel)
        _ = try newCoordinator.addPersistentStore(ofType: NSSQLiteStoreType, configurationName: nil, at: url,
            options: [NSMigratePersistentStoresAutomaticallyOption: true, NSInferMappingModelAutomaticallyOption: true])
        let context = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
        context.persistentStoreCoordinator = newCoordinator
        let restored = try XCTUnwrap(context.fetch(WordEntity.fetchRequest()).first)
        XCTAssertEqual(restored.id, originalID)
        XCTAssertEqual(restored.english, "zebra")
        XCTAssertEqual(restored.importPosition, 0)
        try newCoordinator.destroyPersistentStore(at: url, ofType: NSSQLiteStoreType)
    }

    @MainActor
    func testVersionThreeStoreMigratesToDailyCompletionWithoutLosingWords() throws {
        let bundle = PersistenceController.modelBundle
        let modelDirectory = try XCTUnwrap(bundle.url(forResource: "WordMemoryCards", withExtension: "momd"))
        let oldModel = try XCTUnwrap(NSManagedObjectModel(contentsOf: modelDirectory.appendingPathComponent("WordMemoryCardsV3.mom")))
        let newModel = PersistenceController(inMemory: true).container.managedObjectModel
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sqlite")
        let originalID = UUID()
        let oldCoordinator = NSPersistentStoreCoordinator(managedObjectModel: oldModel)
        let oldStore = try oldCoordinator.addPersistentStore(ofType: NSSQLiteStoreType, configurationName: nil, at: url)
        let oldContext = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
        oldContext.persistentStoreCoordinator = oldCoordinator
        let word = NSEntityDescription.insertNewObject(forEntityName: "WordEntity", into: oldContext)
        word.setValuesForKeys(["id": originalID, "english": "zebra", "normalizedEnglish": "zebra",
                              "chinese": "斑马", "createdAt": Date(), "updatedAt": Date()])
        try oldContext.save()
        oldContext.reset()
        try oldCoordinator.remove(oldStore)
        let newCoordinator = NSPersistentStoreCoordinator(managedObjectModel: newModel)
        _ = try newCoordinator.addPersistentStore(ofType: NSSQLiteStoreType, configurationName: nil, at: url,
            options: [NSMigratePersistentStoresAutomaticallyOption: true, NSInferMappingModelAutomaticallyOption: true])
        let context = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
        context.persistentStoreCoordinator = newCoordinator
        let restored = try XCTUnwrap(context.fetch(WordEntity.fetchRequest()).first)
        XCTAssertEqual(restored.id, originalID)
        XCTAssertEqual(restored.english, "zebra")
        XCTAssertEqual(restored.importPosition, 0)
        XCTAssertEqual(try context.count(for: StudyCompletionDayEntity.fetchRequest()), 0)
        try newCoordinator.destroyPersistentStore(at: url, ofType: NSSQLiteStoreType)
    }

    @MainActor
    func testModelContainsCardAndDictationEntities() {
        let persistence = PersistenceController(inMemory: true)
        let names = Set(persistence.container.managedObjectModel.entities.compactMap(\.name))

        XCTAssertEqual(
            names,
            ["WordEntity", "ReviewStateEntity", "ReviewEventEntity", "StudySessionEntity",
             "DictationStateEntity", "DictationDayEntity", "DictationEventEntity", "StudyCompletionDayEntity"]
        )
    }

    @MainActor
    func testV2StoreMigratesToV3WithoutLosingCardProgress() throws {
        let bundle = PersistenceController.modelBundle
        let directory = try XCTUnwrap(bundle.url(forResource: "WordMemoryCards", withExtension: "momd"))
        let v2 = try XCTUnwrap(NSManagedObjectModel(
            contentsOf: directory.appendingPathComponent("WordMemoryCardsV2.mom")
        ))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sqlite")
        let coordinator = NSPersistentStoreCoordinator(managedObjectModel: v2)
        let oldStore = try coordinator.addPersistentStore(ofType: NSSQLiteStoreType, configurationName: nil, at: url)
        let context = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
        context.persistentStoreCoordinator = coordinator
        let wordID = UUID()
        let word = NSEntityDescription.insertNewObject(forEntityName: "WordEntity", into: context)
        word.setValuesForKeys([
            "id": wordID, "english": "zebra", "normalizedEnglish": "zebra",
            "chinese": "斑马", "importPosition": 7, "createdAt": Date(), "updatedAt": Date()
        ])
        try context.save()
        context.reset()
        try coordinator.remove(oldStore)

        let v3 = PersistenceController(inMemory: true).container.managedObjectModel
        let migratedCoordinator = NSPersistentStoreCoordinator(managedObjectModel: v3)
        _ = try migratedCoordinator.addPersistentStore(
            ofType: NSSQLiteStoreType, configurationName: nil, at: url,
            options: [NSMigratePersistentStoresAutomaticallyOption: true,
                      NSInferMappingModelAutomaticallyOption: true]
        )
        let migrated = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
        migrated.persistentStoreCoordinator = migratedCoordinator
        let restored = try XCTUnwrap(migrated.fetch(WordEntity.fetchRequest()).first)
        XCTAssertEqual(restored.id, wordID)
        XCTAssertEqual(restored.importPosition, 7)
        XCTAssertNil(restored.dictationState)
        XCTAssertEqual(try migrated.count(for: DictationDayEntity.fetchRequest()), 0)
        try migratedCoordinator.destroyPersistentStore(at: url, ofType: NSSQLiteStoreType)
    }

    @MainActor
    func testAWordCanOwnTwoIndependentReviewStates() throws {
        let persistence = PersistenceController(inMemory: true)
        let context = persistence.container.viewContext
        let now = Date()

        let word = WordEntity(context: context)
        word.id = UUID()
        word.english = "apple"
        word.normalizedEnglish = "apple"
        word.chinese = "苹果"
        word.createdAt = now
        word.updatedAt = now

        for direction in ReviewDirection.allCases {
            let state = ReviewStateEntity(context: context)
            state.id = UUID()
            state.direction = direction.rawValue
            state.level = 0
            state.nextReviewDate = now
            state.createdAt = now
            state.updatedAt = now
            state.word = word
        }

        try context.save()

        let request = ReviewStateEntity.fetchRequest()
        request.predicate = NSPredicate(format: "word == %@", word)
        let states = try context.fetch(request)

        XCTAssertEqual(states.count, 2)
        XCTAssertEqual(Set(states.map(\.direction)), Set(ReviewDirection.allCases.map(\.rawValue)))
        XCTAssertTrue(states.allSatisfy { $0.level == 0 })
    }
}
