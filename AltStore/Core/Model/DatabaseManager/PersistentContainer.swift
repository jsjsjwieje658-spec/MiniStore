//
//  PersistentContainer.swift
//  AltStore
//
//  Created by Magesh K on 8/9/26.
//  Copyright © 2026 SideStore. All rights reserved.
//

import CoreData

public enum DatabaseError: LocalizedError, CustomNSError, Sendable, Equatable {
    case databaseDowngradeDetected(reason: String)
    case migrationFailed(reason: String)
    case missingAppGroup(reason: String)
    
    public var errorDescription: String? {
        switch self {
        case .databaseDowngradeDetected:
            return NSLocalizedString("Database Downgrade Detected", comment: "")
        case .migrationFailed:
            return NSLocalizedString("Database Migration Failed", comment: "")
        case .missingAppGroup:
            return NSLocalizedString("App Group Container Inaccessible", comment: "")
        }
    }
    
    public var failureReason: String? {
        switch self {
        case .databaseDowngradeDetected(let reason),
             .migrationFailed(let reason),
             .missingAppGroup(let reason):
            return reason
        }
    }
    
    public static var errorDomain: String {
        return "io.sidestore.DatabaseError"
    }
    
    public var errorCode: Int {
        switch self {
        case .databaseDowngradeDetected:
            return -1001
        case .migrationFailed:
            return -1002
        case .missingAppGroup:
            return -1003
        }
    }
}

open class PersistentContainer: NSPersistentContainer, @unchecked Sendable {
    open var isMigrationRequired: Bool {
        for description in self.persistentStoreDescriptions {
            guard let url = description.url,
                  let metadata = try? NSPersistentStoreCoordinator.metadataForPersistentStore(ofType: description.type, at: url, options: description.options) else {
                continue
            }
            if !self.managedObjectModel.isConfiguration(withName: nil, compatibleWithStoreMetadata: metadata) {
                return true
            }
        }
        return false
    }
    
    open var shouldAddStoresAsynchronously = false
    open var preferredMergePolicy: NSMergePolicy = RelationshipPreservingMergePolicy()
    
    private let parentBackgroundContexts = NSHashTable<NSManagedObjectContext>.weakObjects()
    private let pendingSaveParentBackgroundContexts = NSHashTable<NSManagedObjectContext>.weakObjects()
    
    /// App Support store used when the shared app group container cannot be opened.
    /// Temporary directories are purged by iOS, so this has to live in the sandbox.
    static func sandboxDatabaseDirectoryURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let directory = base.appendingPathComponent("Database", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// Prefer the app group. If iOS will not open it (sideload without the entitlement, or a
    /// refresh that stamped `.AltWidget` onto the host so `containerURL` returns nil), use the
    /// sandbox store instead of refusing to launch.
    static func resolvedDatabaseDirectoryURL() -> URL {
        #if os(tvOS)
        return FileManager.default.cachesDirectory
        #else
        if let sharedDirectoryURL = FileManager.default.altstoreSharedDirectory {
            let databaseDirectoryURL = sharedDirectoryURL.appendingPathComponent("Database", isDirectory: true)
            try? FileManager.default.createDirectory(at: databaseDirectoryURL, withIntermediateDirectories: true)
            migrateSandboxStoreIfNeeded(into: databaseDirectoryURL)
            return databaseDirectoryURL
        }
        debugLog("[Database] App group container is unavailable. Using the sandbox database so launch and Apple ID sign-in can finish.")
        return sandboxDatabaseDirectoryURL()
        #endif
    }

    private static func migrateSandboxStoreIfNeeded(into sharedDirectory: URL) {
        let sandbox = sandboxDatabaseDirectoryURL()
        let fileName = AppConstants.Database.fileName
        let sandboxStore = sandbox.appendingPathComponent(fileName)
        let sharedStore = sharedDirectory.appendingPathComponent(fileName)
        guard FileManager.default.fileExists(atPath: sandboxStore.path),
              !FileManager.default.fileExists(atPath: sharedStore.path) else { return }
        for suffix in ["", "-wal", "-shm"] {
            let source = sandbox.appendingPathComponent(fileName + suffix)
            let destination = sharedDirectory.appendingPathComponent(fileName + suffix)
            guard FileManager.default.fileExists(atPath: source.path) else { continue }
            do {
                try FileManager.default.moveItem(at: source, to: destination)
                debugLog("[Database] Moved sandbox store '\(source.lastPathComponent)' into the app group.")
            } catch {
                debugLog("[Database] Failed to move sandbox store '\(source.lastPathComponent)': \(error.localizedDescription)")
            }
        }
    }

    open override class func defaultDirectoryURL() -> URL {
        resolvedDatabaseDirectoryURL()
    }
    
    public init(name: String, bundle: Bundle) {
        let models = [bundle]
        let managedObjectModel = NSManagedObjectModel.mergedModel(from: models)!
        super.init(name: name, managedObjectModel: managedObjectModel)
        initialize()
    }
    
    public override init(name: String, managedObjectModel model: NSManagedObjectModel) {
        super.init(name: name, managedObjectModel: model)
        initialize()
    }
    
    private func initialize() {
        shouldAddStoresAsynchronously = false
        preferredMergePolicy = RelationshipPreservingMergePolicy()
        
        NotificationCenter.default.addObserver(self, selector: #selector(managedObjectContextWillSave(_:)), name: .NSManagedObjectContextWillSave, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(managedObjectContextObjectsDidChange(_:)), name: .NSManagedObjectContextObjectsDidChange, object: nil)
    }
    
    open func loadPersistentStores() async throws {
        // Retarget in case the description was captured before the group became available.
        // A missing group must not throw: the launch screen then shows "App Group Container
        // Inaccessible", and the later account save raises NSInternalInconsistencyException
        // ("no persistent stores") which kills the process after the 2FA passcode.
        let directory = Self.resolvedDatabaseDirectoryURL()
        for description in self.persistentStoreDescriptions {
            let fileName = description.url?.lastPathComponent ?? AppConstants.Database.fileName
            description.url = directory.appendingPathComponent(fileName)
        }

        for description in self.persistentStoreDescriptions {
            guard let url = description.url,
                  let metadata = try? NSPersistentStoreCoordinator.metadataForPersistentStore(ofType: description.type, at: url, options: description.options) else {
                continue
            }
            
            if !self.managedObjectModel.isConfiguration(withName: nil, compatibleWithStoreMetadata: metadata) {
                try self.validateMigrationCompatibility(metadata: metadata, configuration: description.configuration)
                
                if description.shouldMigrateStoreAutomatically {
                    try await self.progressivelyMigratePersistentStore(to: self.managedObjectModel, configuration: description.configuration)
                }
            }
        }
        
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            super.loadPersistentStores { [weak self] description, error in
                guard let self = self else { return }
                if let error = error {
                    continuation.resume(throwing: error)
                    return
                }
                self.configure(self.viewContext, parent: nil)
                continuation.resume(returning: ())
            }
        }
    }

    private func validateMigrationCompatibility(metadata: [String: Any], configuration: String?) throws {
        guard let sourceModel = NSManagedObjectModel.mergedModel(from: Bundle.allBundles, forStoreMetadata: metadata) else {
            throw DatabaseError.databaseDowngradeDetected(
                reason: NSLocalizedString("The database on disk was created with a newer version of SideStore. Downgrading the database schema is not supported. Please update SideStore or reset your database.", comment: "")
            )
        }
        
        var mappingModel: NSMappingModel?
        guard self.progressiveMigrationManager(forSourceModel: sourceModel, destinationModel: self.managedObjectModel, configuration: configuration, mappingModel: &mappingModel) != nil, mappingModel != nil else {
            throw DatabaseError.databaseDowngradeDetected(
                reason: NSLocalizedString("No valid migration path exists to downgrade this database. Please update SideStore or reset your database.", comment: "")
            )
        }
    }
    
    open override func newBackgroundContext() -> NSManagedObjectContext {
        let context = super.newBackgroundContext()
        self.configure(context, parent: nil)
        return context
    }
    
    open func newBackgroundSavingViewContext() -> NSManagedObjectContext {
        let parentBackgroundContext = self.newBackgroundContext()
        self.parentBackgroundContexts.add(parentBackgroundContext)
        
        let context = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
        self.configure(context, parent: parentBackgroundContext)
        return context
    }
    
    open func newViewContext(parent parentContext: NSManagedObjectContext?) -> NSManagedObjectContext {
        let context = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
        self.configure(context, parent: parentContext)
        
        if parentContext == nil {
            context.persistentStoreCoordinator = self.persistentStoreCoordinator
        }
        
        return context
    }
    
    open func newBackgroundContext(parent parentContext: NSManagedObjectContext) -> NSManagedObjectContext {
        let context = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
        self.configure(context, parent: parentContext)
        return context
    }
    
    private func configure(_ context: NSManagedObjectContext, parent: NSManagedObjectContext?) {
        if let parent = parent {
            context.parent = parent
        }
        context.automaticallyMergesChangesFromParent = true
        context.mergePolicy = self.preferredMergePolicy
    }
    
    private func progressivelyMigratePersistentStore(to model: NSManagedObjectModel, configuration: String?) async throws {
        try await Task.detached(priority: .userInitiated) { [weak self] in
            guard let self = self else { return }
            try self._progressivelyMigratePersistentStore(to: model, configuration: configuration)
        }.value
    }
    
    private func _progressivelyMigratePersistentStore(to model: NSManagedObjectModel, configuration: String?) throws {
        guard let description = self.persistentStoreDescriptions.first, let url = description.url else {
            throw DatabaseError.migrationFailed(reason: "Unable to find a persistent store.")
        }
        
        let sourceMetadata = try NSPersistentStoreCoordinator.metadataForPersistentStore(ofType: description.type, at: url, options: description.options)
        
        if self.managedObjectModel.isConfiguration(withName: nil, compatibleWithStoreMetadata: sourceMetadata) {
            return
        }
        
        guard let sourceModel = NSManagedObjectModel.mergedModel(from: Bundle.allBundles, forStoreMetadata: sourceMetadata) else {
            throw DatabaseError.databaseDowngradeDetected(
                reason: NSLocalizedString("The database on disk was created with a newer version of SideStore. Downgrading the database schema is not supported. Please update SideStore or reset your database.", comment: "")
            )
        }
        
        var mappingModel: NSMappingModel?
        guard let migrationManager = self.progressiveMigrationManager(forSourceModel: sourceModel, destinationModel: model, configuration: configuration, mappingModel: &mappingModel), let finalMappingModel = mappingModel else {
            throw DatabaseError.migrationFailed(
                reason: NSLocalizedString("Unable to find a valid migration path for the database.", comment: "")
            )
        }
        
        let temporaryFilename = UUID().uuidString + "." + url.pathExtension
        let temporaryDestinationURL = FileManager.default.temporaryDirectory.appendingPathComponent(temporaryFilename)
        
        try migrationManager.migrateStore(from: url, sourceType: description.type, options: description.options, with: finalMappingModel, toDestinationURL: temporaryDestinationURL, destinationType: description.type, destinationOptions: description.options)
        
        try self.persistentStoreCoordinator.replacePersistentStore(at: url, destinationOptions: description.options, withPersistentStoreFrom: temporaryDestinationURL, sourceOptions: description.options, ofType: description.type)
        
        do {
            try self.persistentStoreCoordinator.destroyPersistentStore(at: temporaryDestinationURL, ofType: description.type, options: description.options)
        } catch {
            debugLog("Error destroying temporary store: \(error)")
        }
        
        try self._progressivelyMigratePersistentStore(to: model, configuration: configuration)
    }
    
    private func progressiveMigrationManager(forSourceModel sourceModel: NSManagedObjectModel, destinationModel: NSManagedObjectModel, configuration: String?, mappingModel: inout NSMappingModel?) -> NSMigrationManager? {
        if let explicit = self.explicitMappingModel(forSourceModel: sourceModel, destinationModel: destinationModel, configuration: configuration) {
            mappingModel = explicit
            return NSMigrationManager(sourceModel: sourceModel, destinationModel: destinationModel)
        }
        
        let managedObjectModelURLs = self.managedObjectModelURLs()
        for modelURL in managedObjectModelURLs {
            guard let model = NSManagedObjectModel(contentsOf: modelURL) else { continue }
            if let mapping = self.explicitMappingModel(forSourceModel: sourceModel, destinationModel: model, configuration: configuration) {
                mappingModel = mapping
                return NSMigrationManager(sourceModel: sourceModel, destinationModel: model)
            }
        }
        
        if let inferred = try? NSMappingModel.inferredMappingModel(forSourceModel: sourceModel, destinationModel: destinationModel) {
            mappingModel = inferred
            return NSMigrationManager(sourceModel: sourceModel, destinationModel: destinationModel)
        }
        
        return nil
    }
    
    private func managedObjectModelURLs() -> [URL] {
        var modelURLs = [URL]()
        for bundle in Bundle.allBundles {
            if let momdURLs = bundle.urls(forResourcesWithExtension: "momd", subdirectory: nil) {
                for url in momdURLs {
                    let resourceDirectory = url.lastPathComponent
                    if let momURLs = bundle.urls(forResourcesWithExtension: "mom", subdirectory: resourceDirectory) {
                        modelURLs.append(contentsOf: momURLs)
                    }
                }
            }
            if let momURLs = bundle.urls(forResourcesWithExtension: "mom", subdirectory: nil) {
                modelURLs.append(contentsOf: momURLs)
            }
        }
        return modelURLs
    }
    
    private func explicitMappingModel(forSourceModel sourceModel: NSManagedObjectModel, destinationModel: NSManagedObjectModel, configuration: String?) -> NSMappingModel? {
        guard let mappingModel = NSMappingModel(from: Bundle.allBundles, forSourceModel: sourceModel, destinationModel: destinationModel) else {
            return nil
        }
        
        let entities = self.managedObjectModel.entities(forConfigurationName: configuration) ?? []
        for entityDescription in entities {
            guard let entityName = entityDescription.name else { continue }
            if destinationModel.entitiesByName[entityName] == nil {
                continue
            }
            
            for mapping in mappingModel.entityMappings {
                if mapping.destinationEntityName == entityName {
                    return mappingModel
                }
            }
        }
        
        return nil
    }
    
    @objc private func managedObjectContextWillSave(_ notification: Notification) {
        guard let context = notification.object as? NSManagedObjectContext else { return }
        if let parent = context.parent, self.parentBackgroundContexts.contains(parent) {
            self.pendingSaveParentBackgroundContexts.add(parent)
        }
    }
    
    @objc private func managedObjectContextObjectsDidChange(_ notification: Notification) {
        guard let context = notification.object as? NSManagedObjectContext else { return }
        if self.pendingSaveParentBackgroundContexts.contains(context) {
            do {
                try context.save()
            } catch {
                debugLog("Context save error: \(error)")
            }
            self.pendingSaveParentBackgroundContexts.remove(context)
        }
    }
}
