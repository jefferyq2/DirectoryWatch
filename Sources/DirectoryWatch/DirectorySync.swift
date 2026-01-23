// MIT License
// Copyright (c) 2026 Marcin Krzyzanowski

import Foundation

/// A directory watcher that produces sync operations for one-way synchronization.
///
/// This watcher monitors a source directory and emits operations describing what
/// needs to be done to keep a destination in sync. It does not perform any file
/// operations itself - the consumer is responsible for executing the operations.
public actor DirectorySync {
    // MARK: - Public Types

    /// Configuration for the sync watcher.
    public struct Configuration: Sendable {
        /// Whether to compute initial diff on start (default: true).
        public var computeInitialDiff: Bool
        /// File/directory patterns to exclude (e.g., ".DS_Store", ".git").
        public var excludePatterns: [String]
        /// Whether to include hidden files (files starting with '.'), default: false.
        public var includeHiddenFiles: Bool

        public static let `default` = Configuration(
            computeInitialDiff: true,
            excludePatterns: [".DS_Store", ".git", ".build", ".swiftpm"],
            includeHiddenFiles: false
        )

        public init(
            computeInitialDiff: Bool = Self.default.computeInitialDiff,
            excludePatterns: [String] = Self.default.excludePatterns,
            includeHiddenFiles: Bool = Self.default.includeHiddenFiles
        ) {
            self.computeInitialDiff = computeInitialDiff
            self.excludePatterns = excludePatterns
            self.includeHiddenFiles = includeHiddenFiles
        }
    }

    /// Represents a sync operation to be executed by the consumer.
    public enum SyncOperation: Sendable, Hashable {
        /// Copy file from source to destination.
        case copyFile(source: URL, destination: URL)
        /// Update file at destination with source content.
        case updateFile(source: URL, destination: URL)
        /// Create directory at destination.
        case createDirectory(destination: URL)
        /// Delete file at destination.
        case deleteFile(destination: URL)
        /// Delete directory at destination.
        case deleteDirectory(destination: URL)

        /// The relative path component for this operation.
        public var relativePath: String {
            switch self {
            case let .copyFile(_, dst), let .updateFile(_, dst),
                 let .createDirectory(dst), let .deleteFile(dst), let .deleteDirectory(dst):
                dst.lastPathComponent
            }
        }
    }

    /// Events emitted by the sync watcher.
    public enum Event: Sendable {
        case started
        case initialDiff(operations: [SyncOperation])
        case operation(SyncOperation)
        case stopped
    }

    /// Errors that can occur.
    public enum Error: Swift.Error, LocalizedError, Sendable {
        case sourceNotFound(path: String)
        case destinationNotFound(path: String)
        case watcherFailed(underlying: String)
        case alreadyRunning
        case notRunning

        public var errorDescription: String? {
            switch self {
            case let .sourceNotFound(path):
                "Source directory not found: \(path)"
            case let .destinationNotFound(path):
                "Destination directory not found: \(path)"
            case let .watcherFailed(underlying):
                "File watcher error: \(underlying)"
            case .alreadyRunning:
                "Sync watcher is already running"
            case .notRunning:
                "Sync watcher is not running"
            }
        }
    }

    // MARK: - Public Properties

    /// Async stream of sync events.
    public nonisolated let events: AsyncStream<Event>

    /// The source directory URL being watched.
    public nonisolated let sourceURL: URL

    /// The destination directory URL for sync operations.
    public nonisolated let destinationURL: URL

    /// Whether the watcher is currently active.
    public var isRunning: Bool { _isRunning }

    // MARK: - Private State

    private let _configuration: Configuration
    private var _isRunning: Bool = false
    private var _directoryWatch: AsyncDirectoryWatch?
    private var _watchTask: Task<Void, Never>?
    private let _eventsContinuation: AsyncStream<Event>.Continuation

    // MARK: - Initialization

    /// Creates a new directory sync watcher.
    ///
    /// - Parameters:
    ///   - sourceURL: The source directory to watch.
    ///   - destinationURL: The destination directory for generated operations.
    ///   - configuration: Optional configuration (defaults to .default).
    /// - Throws: Error.sourceNotFound if source doesn't exist.
    public init(
        sourceURL: URL,
        destinationURL: URL,
        configuration: Configuration = .default
    ) throws {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: sourceURL.path, isDirectory: &isDir),
              isDir.boolValue
        else {
            throw Error.sourceNotFound(path: sourceURL.path)
        }

        self.sourceURL = sourceURL.standardizedFileURL
        self.destinationURL = destinationURL.standardizedFileURL
        self._configuration = configuration

        var continuation: AsyncStream<Event>.Continuation!
        self.events = AsyncStream { continuation = $0 }
        self._eventsContinuation = continuation
    }

    // MARK: - Control Methods

    /// Starts the sync watcher.
    ///
    /// Computes initial diff (if configured) and begins watching for changes.
    /// - Throws: Error.alreadyRunning if already started.
    public func start() async throws {
        guard !_isRunning else {
            throw Error.alreadyRunning
        }

        _isRunning = true
        _eventsContinuation.yield(.started)

        // Compute initial diff if configured
        if _configuration.computeInitialDiff {
            let operations = computeDiff()
            _eventsContinuation.yield(.initialDiff(operations: operations))
        }

        // Set up directory watcher
        do {
            _directoryWatch = try AsyncDirectoryWatch(
                url: sourceURL,
                configuration: .init(recursionMode: .recursive)
            )
            try _directoryWatch?.start()
            startWatching()
        } catch {
            throw Error.watcherFailed(underlying: error.localizedDescription)
        }
    }

    /// Stops the sync watcher.
    public func stop() {
        guard _isRunning else { return }

        _watchTask?.cancel()
        _watchTask = nil

        _directoryWatch?.stop()
        _directoryWatch = nil

        _isRunning = false

        _eventsContinuation.yield(.stopped)
        _eventsContinuation.finish()
    }

    /// Computes a fresh diff between source and destination.
    ///
    /// - Returns: Array of operations needed to sync destination with source.
    public func computeDiff() -> [SyncOperation] {
        Self.computeDiff(source: sourceURL, destination: destinationURL, configuration: _configuration)
    }

    /// Computes a diff between source and destination directories.
    ///
    /// - Parameters:
    ///   - source: The source directory URL.
    ///   - destination: The destination directory URL.
    ///   - configuration: Configuration for exclusions and hidden files.
    /// - Returns: Array of operations needed to sync destination with source.
    public static func computeDiff(
        source: URL,
        destination: URL,
        configuration: Configuration = .default
    ) -> [SyncOperation] {
        var operations: [SyncOperation] = []

        // Enumerate source and destination trees
        let sourceItems = enumerateDirectory(at: source, relativeTo: source, configuration: configuration)
        let destItems = enumerateDirectory(at: destination, relativeTo: destination, configuration: configuration)

        // Build lookup maps
        let sourceMap = Dictionary(uniqueKeysWithValues: sourceItems.map { ($0.relativePath, $0) })
        let destMap = Dictionary(uniqueKeysWithValues: destItems.map { ($0.relativePath, $0) })

        // Items to delete (in dest but not in source) - deepest first
        let toDelete = destItems.filter { sourceMap[$0.relativePath] == nil }
            .sorted { $0.relativePath.components(separatedBy: "/").count > $1.relativePath.components(separatedBy: "/").count }

        for item in toDelete {
            let dstURL = destination.appendingPathComponent(item.relativePath)
            if item.isDirectory {
                operations.append(.deleteDirectory(destination: dstURL))
            } else {
                operations.append(.deleteFile(destination: dstURL))
            }
        }

        // Directories to create (in source but not in dest) - shallowest first
        let directoriesToCreate = sourceItems
            .filter { $0.isDirectory && destMap[$0.relativePath] == nil }
            .sorted { $0.relativePath.components(separatedBy: "/").count < $1.relativePath.components(separatedBy: "/").count }

        for dir in directoriesToCreate {
            let dstURL = destination.appendingPathComponent(dir.relativePath)
            operations.append(.createDirectory(destination: dstURL))
        }

        // Files to create or update
        let filesToSync = sourceItems.filter { !$0.isDirectory }

        for srcItem in filesToSync {
            let srcURL = source.appendingPathComponent(srcItem.relativePath)
            let dstURL = destination.appendingPathComponent(srcItem.relativePath)

            if let destItem = destMap[srcItem.relativePath] {
                if needsUpdate(source: srcItem, destination: destItem) {
                    operations.append(.updateFile(source: srcURL, destination: dstURL))
                }
            } else {
                operations.append(.copyFile(source: srcURL, destination: dstURL))
            }
        }

        return operations
    }

    // MARK: - Private Types

    private struct ItemState: Hashable {
        let relativePath: String
        let isDirectory: Bool
        let modificationDate: Date?
        let size: Int64?
    }

    // MARK: - Private Methods

    private static func enumerateDirectory(at url: URL, relativeTo root: URL, configuration: Configuration) -> [ItemState] {
        var items: [ItemState] = []

        guard FileManager.default.fileExists(atPath: url.path) else {
            return items
        }

        let options: FileManager.DirectoryEnumerationOptions = configuration.includeHiddenFiles
            ? []
            : [.skipsHiddenFiles]

        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey, .fileSizeKey],
            options: options
        ) else {
            return items
        }

        // Resolve symlinks to ensure consistent path comparison
        // (e.g., /var vs /private/var on macOS)
        let resolvedRoot = root.resolvingSymlinksInPath()
        let rootPath = resolvedRoot.path.hasSuffix("/") ? resolvedRoot.path : resolvedRoot.path + "/"

        for case let itemURL as URL in enumerator {
            let resolvedItem = itemURL.resolvingSymlinksInPath()
            let relativePath = String(resolvedItem.path.dropFirst(rootPath.count))

            if shouldExclude(relativePath: relativePath, configuration: configuration) {
                if let resourceValues = try? itemURL.resourceValues(forKeys: [.isDirectoryKey]),
                   resourceValues.isDirectory == true {
                    enumerator.skipDescendants()
                }
                continue
            }

            let resourceValues = try? itemURL.resourceValues(forKeys: [.isDirectoryKey, .contentModificationDateKey, .fileSizeKey])

            items.append(ItemState(
                relativePath: relativePath,
                isDirectory: resourceValues?.isDirectory ?? false,
                modificationDate: resourceValues?.contentModificationDate,
                size: resourceValues?.fileSize.map { Int64($0) }
            ))
        }

        return items
    }

    private static func needsUpdate(source: ItemState, destination: ItemState) -> Bool {
        if let srcDate = source.modificationDate, let dstDate = destination.modificationDate {
            if srcDate > dstDate {
                return true
            }
        }
        return source.size != destination.size
    }

    private static func shouldExclude(relativePath: String, configuration: Configuration) -> Bool {
        let components = relativePath.components(separatedBy: "/")
        return configuration.excludePatterns.contains { components.contains($0) }
    }

    private func startWatching() {
        guard let directoryWatch = _directoryWatch else { return }

        _watchTask = Task { [weak self] in
            for await event in directoryWatch.events {
                guard let self, !Task.isCancelled else { break }
                await self.handleWatchEvent(event)
            }
        }
    }

    private func handleWatchEvent(_ event: AsyncDirectoryWatch.Event) async {
        guard !Self.shouldExclude(relativePath: event.relativePath, configuration: _configuration) else { return }

        let operations = mapWatchEventToOperations(event)
        for operation in operations {
            _eventsContinuation.yield(.operation(operation))
        }
    }

    private func mapWatchEventToOperations(_ event: AsyncDirectoryWatch.Event) -> [SyncOperation] {
        let relativePath = event.relativePath
        let srcURL = sourceURL.appendingPathComponent(relativePath)
        let dstURL = destinationURL.appendingPathComponent(relativePath)

        if event.changes.contains(.deleted) {
            if event.itemType == .directory {
                return [.deleteDirectory(destination: dstURL)]
            } else {
                return [.deleteFile(destination: dstURL)]
            }
        }

        if event.changes.contains(.created) {
            if event.itemType == .directory {
                return [.createDirectory(destination: dstURL)]
            } else {
                return [.copyFile(source: srcURL, destination: dstURL)]
            }
        }

        if event.changes.contains(.modified) {
            if event.itemType == .file {
                return [.updateFile(source: srcURL, destination: dstURL)]
            }
        }

        if event.changes.contains(.renamed) {
            // Check if source still exists at this path
            if FileManager.default.fileExists(atPath: srcURL.path) {
                if event.itemType == .directory {
                    return [.createDirectory(destination: dstURL)]
                } else {
                    return [.copyFile(source: srcURL, destination: dstURL)]
                }
            } else {
                if event.itemType == .directory {
                    return [.deleteDirectory(destination: dstURL)]
                } else {
                    return [.deleteFile(destination: dstURL)]
                }
            }
        }

        return []
    }
}
