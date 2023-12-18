import Foundation
import Combine
import OSLog
import CoreData

private let logger = Logger(subsystem: "Sync", category: "DataStack")

@objc public enum DataStackStoreType: Int {
  case inMemory, sqLite

  var type: String {
    switch self {
    case .inMemory:
      return NSInMemoryStoreType
    case .sqLite:
      return NSSQLiteStoreType
    }
  }
}

@objc public class DataStack: NSObject {
  private var storeType = DataStackStoreType.sqLite

  private var storeName: String?

  private var modelName: String

  private var modelBundle = Bundle.main

  private let backgroundContextName = "DataStack.backgroundContextName"

  private let inMemory: Bool
  private var subscriptions: Set<AnyCancellable> = []

  public init(modelName: String, inMemory: Bool = false) {
    self.modelName = modelName
    self.inMemory = inMemory
    super.init()
    configureSubscriptions()
  }

  private func configureSubscriptions() {
    NotificationCenter.default.publisher(for: .NSPersistentStoreRemoteChange)
      .sink { [weak self] notification in
        logger.debug("Received persistent store remote change notification: \(notification)")

        Task { [weak self] in
          await self?.fetchPersistentHistory()
        }
      }
      .store(in: &subscriptions)
  }

  // MARK: - Core Data stack

  public private(set) lazy var container: NSPersistentContainer = {
    guard
      let dataModelURL = modelBundle.url(forResource: modelName, withExtension: "momd"),
      let dataModel = NSManagedObjectModel(contentsOf: dataModelURL)
    else {
      fatalError("Failed to find data model in the bundle.")
    }

    let container = NSPersistentContainer(name: modelName, managedObjectModel: dataModel)

    guard let description = container.persistentStoreDescriptions.first else {
      fatalError("Failed to retrieve persistent store description.")
    }

    if inMemory {
      description.url = URL(fileURLWithPath: "/dev/null")
    } else {
      guard let appContainer = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).last else {
        fatalError("File container could not be created.")
      }

      let url = appContainer.appendingPathComponent("\(modelName).sqlite")

      if let description = container.persistentStoreDescriptions.first {
        description.url = url
        description.setOption(true as NSNumber, forKey: NSPersistentStoreRemoteChangeNotificationPostOptionKey)
        description.setOption(true as NSNumber, forKey: NSPersistentHistoryTrackingKey)
      }
    }

    container.loadPersistentStores { storeDescription, error in
      if let error {
        // Handle migration by dropping database and recreating the store
        self.drop()
      }
    }

    container.viewContext.automaticallyMergesChangesFromParent = false
    container.viewContext.name = "viewContext"
    container.viewContext.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
    container.viewContext.undoManager = nil
    container.viewContext.shouldDeleteInaccessibleFaults = true

    if !inMemory {
      do {
        try container.viewContext.setQueryGenerationFrom(.current)
      } catch {
        fatalError("Failed to set query generation: \(error)")
      }
    }

    return container
  }()

  /// Creates and configures a private queue context.
  public func newTaskContext() -> NSManagedObjectContext {
    let taskContext = container.newBackgroundContext()
    taskContext.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
    taskContext.undoManager = nil
    return taskContext
  }

  // MARK: - History token

  private let tokenManager = PersistentHistoryTokenManager(dataModelName: "DataModel")

  // MARK: - Changes observing

  private func fetchPersistentHistory() async {
    do {
      try await fetchPersistentHistoryTransactionsAndChanges()
    } catch {
      logger.error("Failed to fetch persistent history: \(error)")
    }
  }

  private func fetchPersistentHistoryTransactionsAndChanges() async throws {
    let taskContext = newTaskContext()
    taskContext.name = "persistentHistoryContext"

    logger.debug("Starting to fetch persistent history changes from the store")

    let lastToken = await tokenManager.lastToken

    let history = try await taskContext.perform {
      let changeRequest = NSPersistentHistoryChangeRequest.fetchHistory(after: lastToken)
      let historyResult = try taskContext.execute(changeRequest) as? NSPersistentHistoryResult

      if
        let history = historyResult?.result as? [NSPersistentHistoryTransaction],
        !history.isEmpty
      {
        return history
      } else {
        logger.debug("No persistent history transactions found")
        return []
      }
    }

    await mergePersistentHistoryChanges(from: history)

    logger.debug("Finished merging history changes")
  }

  private func mergePersistentHistoryChanges(from history: [NSPersistentHistoryTransaction]) async {
    logger.debug("Received \(history.count) persistent history transactions")

    let viewContext = container.viewContext
    var lastToken: NSPersistentHistoryToken?

    await viewContext.perform {
      for transaction in history {
        viewContext.mergeChanges(fromContextDidSave: transaction.objectIDNotification())
        lastToken = transaction.token
      }
    }

    if let lastToken {
      await tokenManager.storeHistoryToken(lastToken)
    }
  }

  public var mainContext: NSManagedObjectContext {
    container.viewContext
  }

  public var viewContext: NSManagedObjectContext {
    container.viewContext
  }

  public func newBackgroundContext() -> NSManagedObjectContext {
    newTaskContext()
  }

  /**
   Returns a background context perfect for data mutability operations.
   - parameter operation: The block that contains the created background context.
   */
  @objc public func performInNewBackgroundContext(_ operation: @escaping (_ backgroundContext: NSManagedObjectContext) -> Void) {
    let context = newTaskContext()
    let contextBlock: @convention(block) () -> Void = {
      operation(context)
    }
    let blockObject: AnyObject = unsafeBitCast(contextBlock, to: AnyObject.self)
    context.perform(DataStack.performSelectorForBackgroundContext(), with: blockObject)
  }

  /**
   Returns a background context perfect for data mutability operations.
   - parameter operation: The block that contains the created background context.
   */
  @objc public func performBackgroundTask(operation: @escaping (_ backgroundContext: NSManagedObjectContext) -> Void) {
    self.performInNewBackgroundContext(operation)
  }

  public func drop() {
    container.persistentStoreDescriptions.forEach { storeDescription in
      if let url = storeDescription.url {
        let type = NSPersistentStore.StoreType(rawValue: storeDescription.type)
        try? container.persistentStoreCoordinator.destroyPersistentStore(at: url, type: type)
      }
    }

    Task { await tokenManager.deleteHistoryToken() }

    container.loadPersistentStores { storeDescription, error in
      if let error {
        fatalError("Unresolved error: \(error)")
      }
    }
  }

  /// Sends a request to all the persistent stores associated with the receiver.
  ///
  /// - Parameters:
  ///   - request: A fetch, save or delete request.
  ///   - context: The context against which request should be executed.
  /// - Returns: An array containing managed objects, managed object IDs, or dictionaries as appropriate for a fetch request; an empty array if request is a save request, or nil if an error occurred.
  /// - Throws: If an error occurs, upon return contains an NSError object that describes the problem.
  @objc public func execute(_ request: NSPersistentStoreRequest, with context: NSManagedObjectContext) throws -> Any {
    return try self.container.persistentStoreCoordinator.execute(request, with: context)
  }

  private static func backgroundConcurrencyType() -> NSManagedObjectContextConcurrencyType {
    return TestCheck.isTesting ? .mainQueueConcurrencyType : .privateQueueConcurrencyType
  }

  private static func performSelectorForBackgroundContext() -> Selector {
    return TestCheck.isTesting ? NSSelectorFromString("performBlockAndWait:") : NSSelectorFromString("performBlock:")
  }
}

extension NSPersistentStoreCoordinator {
  func addPersistentStore(storeType: DataStackStoreType, bundle: Bundle, modelName: String, storeName: String?, containerURL: URL) throws {
    let filePath = (storeName ?? modelName) + ".sqlite"
    switch storeType {
    case .inMemory:
      do {
        try self.addPersistentStore(ofType: NSInMemoryStoreType, configurationName: nil, at: nil, options: nil)
      } catch let error as NSError {
        throw NSError(info: "There was an error creating the persistentStoreCoordinator for in memory store", previousError: error)
      }

      break
    case .sqLite:
      let storeURL = containerURL.appendingPathComponent(filePath)
      let storePath = storeURL.path

      let shouldPreloadDatabase = !FileManager.default.fileExists(atPath: storePath)
      if shouldPreloadDatabase {
        if let preloadedPath = bundle.path(forResource: modelName, ofType: "sqlite") {
          let preloadURL = URL(fileURLWithPath: preloadedPath)

          do {
            try FileManager.default.copyItem(at: preloadURL, to: storeURL)
          } catch let error as NSError {
            throw NSError(info: "Oops, could not copy preloaded data", previousError: error)
          }
        }
      }

      let options = [NSMigratePersistentStoresAutomaticallyOption: true, NSInferMappingModelAutomaticallyOption: true, NSSQLitePragmasOption: ["journal_mode": "DELETE"]] as [AnyHashable : Any]
      do {
        try self.addPersistentStore(ofType: NSSQLiteStoreType, configurationName: nil, at: storeURL, options: options)
      } catch {
        do {
          try FileManager.default.removeItem(atPath: storePath)
          do {
            try self.addPersistentStore(ofType: NSSQLiteStoreType, configurationName: nil, at: storeURL, options: options)
          } catch let addPersistentError as NSError {
            throw NSError(info: "There was an error creating the persistentStoreCoordinator", previousError: addPersistentError)
          }
        } catch let removingError as NSError {
          throw NSError(info: "There was an error removing the persistentStoreCoordinator", previousError: removingError)
        }
      }

      let shouldExcludeSQLiteFromBackup = storeType == .sqLite && TestCheck.isTesting == false
      if shouldExcludeSQLiteFromBackup {
        do {
          try (storeURL as NSURL).setResourceValue(true, forKey: .isExcludedFromBackupKey)
        } catch let excludingError as NSError {
          throw NSError(info: "Excluding SQLite file from backup caused an error", previousError: excludingError)
        }
      }

      break
    }
  }
}

extension NSManagedObjectModel {
  convenience init(bundle: Bundle, name: String) {
    if let momdModelURL = bundle.url(forResource: name, withExtension: "momd") {
      self.init(contentsOf: momdModelURL)!
    } else if let momModelURL = bundle.url(forResource: name, withExtension: "mom") {
      self.init(contentsOf: momModelURL)!
    } else {
      self.init()
    }
  }
}

extension NSError {
  convenience init(info: String, previousError: NSError?) {
    if let previousError = previousError {
      var userInfo = previousError.userInfo
      if let _ = userInfo[NSLocalizedFailureReasonErrorKey] {
        userInfo["Additional reason"] = info
      } else {
        userInfo[NSLocalizedFailureReasonErrorKey] = info
      }

      self.init(domain: previousError.domain, code: previousError.code, userInfo: userInfo)
    } else {
      var userInfo = [String: String]()
      userInfo[NSLocalizedDescriptionKey] = info
      self.init(domain: "com.SyncDB.DataStack", code: 9999, userInfo: userInfo)
    }
  }
}

actor PersistentHistoryTokenManager {
  public let dataModelName: String

  private let tokenFileURL: URL
  private(set) var lastToken: NSPersistentHistoryToken?

  init(dataModelName: String) {
    self.dataModelName = dataModelName
    self.tokenFileURL = Self.tokenFileURL(for: dataModelName)
    self.lastToken = Self.loadHistoryToken(for: tokenFileURL)
  }

  func storeHistoryToken(_ token: NSPersistentHistoryToken) {
    do {
      let data = try NSKeyedArchiver.archivedData(withRootObject: token, requiringSecureCoding: true)
      try data.write(to: tokenFileURL)
      lastToken = token
    } catch {
      logger.error("Storing history token failed: \(error)")
    }
  }

  func deleteHistoryToken() {
    do {
      try FileManager.default.removeItem(at: tokenFileURL)
      lastToken = nil
    } catch {
      logger.error("Deleting history token failed: \(error)")
    }
  }

  private static func tokenFileURL(for dataModelName: String) -> URL {
    let url = NSPersistentContainer.defaultDirectoryURL().appendingPathComponent(dataModelName, isDirectory: true)
    do {
      try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: nil)
    } catch {
      logger.error("Creating token file directory failed: \(error)")
    }
    return url.appendingPathComponent("token.data", isDirectory: false)
  }

  private static func loadHistoryToken(for tokenFileURL: URL) -> NSPersistentHistoryToken? {
    do {
      let tokenData = try Data(contentsOf: tokenFileURL)
      return try NSKeyedUnarchiver.unarchivedObject(ofClass: NSPersistentHistoryToken.self, from: tokenData)
    } catch {
      logger.error("Loading history token failed: \(error)")
      return nil
    }
  }
}
