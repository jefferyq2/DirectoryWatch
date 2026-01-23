// MIT License
// Copyright (c) 2026 Marcin Krzyzanowski

import Foundation
import KQueue
import Synchronization

/// High-level directory watcher built on KQueue.
/// Provides FSEvents-like directory monitoring with configurable recursion.
public final class AsyncDirectoryWatch: Sendable {
    // MARK: - Public Types

    /// Recursion mode for directory watching.
    public enum RecursionMode: Sendable, Hashable {
        /// Watch only the specified directory (shallow).
        case shallow
        /// Watch the directory and all subdirectories recursively.
        case recursive
    }

    /// Configuration for directory watching.
    public struct Configuration: Sendable {
        public var recursionMode: RecursionMode
        public var notifications: KQueue.Notification

        public static let `default` = Configuration(
            recursionMode: .recursive,
            notifications: .default
        )

        public init(
            recursionMode: RecursionMode = .recursive,
            notifications: KQueue.Notification = .default
        ) {
            self.recursionMode = recursionMode
            self.notifications = notifications
        }
    }

    /// Type of file system change.
    public enum ChangeKind: Sendable, Hashable, CustomStringConvertible {
        case created
        case modified
        case deleted
        case renamed
        case attributesChanged

        public var description: String {
            switch self {
            case .created: "created"
            case .modified: "modified"
            case .deleted: "deleted"
            case .renamed: "renamed"
            case .attributesChanged: "attributesChanged"
            }
        }
    }

    /// Type of the item that changed.
    public enum ItemType: Sendable, Hashable {
        case file
        case directory
        case symbolicLink
        case unknown
    }

    /// A directory watch event with rich path information.
    ///
    /// - Note: When comparing `url` or `root` with other URLs, use `standardizedFileURL`
    ///   to ensure consistent comparison, as trailing slashes and path variations may differ.
    ///   For example: `event.root.standardizedFileURL == myURL.standardizedFileURL`
    public struct Event: Sendable, Hashable {
        /// Absolute URL of the item that changed.
        ///
        /// Use `standardizedFileURL` when comparing with other URLs.
        public let url: URL
        /// Path relative to the watched root directory.
        public let relativePath: String
        /// The root directory being watched.
        ///
        /// Use `standardizedFileURL` when comparing with other URLs.
        public let root: URL
        /// What kind of change occurred.
        public let changes: Set<ChangeKind>
        /// Type of the item (file, directory, etc.).
        public let itemType: ItemType
        /// The underlying KQueue notification flags.
        public let rawNotification: KQueue.Notification
    }

    /// Errors that can occur when using AsyncDirectoryWatch.
    public enum Error: Swift.Error, LocalizedError {
        case notADirectory(path: String)
        case cannotAccess(path: String, underlying: Swift.Error)
        case fileDescriptorLimitReached(currentCount: Int, path: String)
        case rootDirectoryDeleted(path: String)
        case kqueueCreationFailed
        case kqueueError(KQueue.Error)

        public var errorDescription: String? {
            switch self {
            case let .notADirectory(path):
                "Path is not a directory: '\(path)'"
            case let .cannotAccess(path, underlying):
                "Cannot access '\(path)': \(underlying.localizedDescription)"
            case let .fileDescriptorLimitReached(count, path):
                "File descriptor limit reached (\(count)) while watching '\(path)'"
            case let .rootDirectoryDeleted(path):
                "Root directory was deleted: '\(path)'"
            case .kqueueCreationFailed:
                "Failed to create kqueue"
            case let .kqueueError(error):
                "KQueue error: \(error.localizedDescription)"
            }
        }
    }

    // MARK: - Private Types

    private struct WatchedDirectory: Sendable {
        let path: String
        let relativePath: String
        var knownContents: Set<String>
    }

    private struct State {
        var rootURL: URL
        var watchedDirectories: [String: WatchedDirectory]
        var isActive: Bool
        var isPaused: Bool
        var processingTask: Task<Void, Never>?
    }

    // MARK: - Properties

    private let kqueue: KQueue
    private let state: Mutex<State>
    private let configuration: Configuration
    private let eventHandler: (@Sendable (Event) -> Void)?
    private let eventsContinuation: AsyncStream<Event>.Continuation
    private let fileDescriptorLimit: Int

    /// Events from the watched directory tree.
    public let events: AsyncStream<Event>

    /// The root directory being watched.
    public var root: URL {
        state.withLock { $0.rootURL }
    }

    /// Number of directories currently being watched.
    public var watchedDirectoryCount: Int {
        state.withLock { $0.watchedDirectories.count }
    }

    /// All paths currently being watched.
    public var watchedPaths: [String] {
        state.withLock { Array($0.watchedDirectories.keys) }
    }

    /// Whether watching is active.
    public var isWatching: Bool {
        state.withLock { $0.isActive }
    }

    /// Whether watching is paused.
    public var isPaused: Bool {
        state.withLock { $0.isPaused }
    }

    // MARK: - Initialization

    /// Create a directory watcher.
    ///
    /// - Parameters:
    ///   - url: The root directory to watch.
    ///   - configuration: Watch configuration.
    ///   - eventHandler: Optional callback for events (in addition to AsyncStream).
    /// - Throws: Error if the path is not a valid directory or cannot be accessed.
    public init(
        url: URL,
        configuration: Configuration = .default,
        eventHandler: (@Sendable (Event) -> Void)? = nil
    ) throws {
        guard url.isFileURL else {
            throw Error.notADirectory(path: url.absoluteString)
        }

        let path = url.path(percentEncoded: false)

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw Error.notADirectory(path: path)
        }

        guard let kqueue = KQueue() else {
            throw Error.kqueueCreationFailed
        }

        self.kqueue = kqueue
        self.configuration = configuration
        self.eventHandler = eventHandler
        self.fileDescriptorLimit = Self.getSystemFileDescriptorLimit()

        var continuation: AsyncStream<Event>.Continuation!
        self.events = AsyncStream { continuation = $0 }
        self.eventsContinuation = continuation

        self.state = Mutex(State(
            rootURL: url.standardizedFileURL,
            watchedDirectories: [:],
            isActive: false,
            isPaused: false,
            processingTask: nil
        ))
    }

    /// Create a directory watcher from path string.
    public convenience init(
        path: String,
        configuration: Configuration = .default,
        eventHandler: (@Sendable (Event) -> Void)? = nil
    ) throws {
        try self.init(
            url: URL(fileURLWithPath: path),
            configuration: configuration,
            eventHandler: eventHandler
        )
    }

    deinit {
        stop()
    }

    // MARK: - Control

    /// Start watching the directory.
    public func start() throws {
        let rootURL = state.withLock { state -> URL? in
            guard !state.isActive else { return nil }
            state.isActive = true
            return state.rootURL
        }

        guard let rootURL else { return }

        let rootPath = rootURL.path(percentEncoded: false)

        do {
            if configuration.recursionMode == .recursive {
                try enumerateAndWatch(directory: rootPath, relativePath: "")
            } else {
                try watchDirectory(rootPath, relativePath: "")
            }
        } catch {
            state.withLock { $0.isActive = false }
            throw error
        }

        startProcessingEvents()
    }

    /// Stop watching and release all resources.
    public func stop() {
        let task = state.withLock { state -> Task<Void, Never>? in
            state.isActive = false
            state.isPaused = false
            state.watchedDirectories.removeAll()
            let task = state.processingTask
            state.processingTask = nil
            return task
        }

        task?.cancel()
        kqueue.stopWatchingAll()
        eventsContinuation.finish()
    }

    /// Pause event delivery temporarily.
    ///
    /// While paused, file descriptors remain open but events are discarded.
    /// Call `resume()` to continue receiving events.
    public func pause() {
        state.withLock { $0.isPaused = true }
        kqueue.pause()
    }

    /// Resume event delivery after pause.
    public func resume() {
        state.withLock { $0.isPaused = false }
        kqueue.resume()
    }

    // MARK: - Private Methods

    private static func getSystemFileDescriptorLimit() -> Int {
        var rlimit = rlimit()
        if getrlimit(RLIMIT_NOFILE, &rlimit) == 0 {
            return max(Int(rlimit.rlim_cur) - 100, 256)
        }
        return 256
    }

    private func watchDirectory(_ path: String, relativePath: String) throws {
        let currentCount = state.withLock { $0.watchedDirectories.count }

        if currentCount >= fileDescriptorLimit {
            throw Error.fileDescriptorLimitReached(currentCount: currentCount, path: path)
        }

        do {
            try kqueue.watch(path, for: configuration.notifications)
        } catch let error as KQueue.Error {
            throw Error.kqueueError(error)
        }

        let contents = (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []

        state.withLock { state in
            state.watchedDirectories[path] = WatchedDirectory(
                path: path,
                relativePath: relativePath,
                knownContents: Set(contents)
            )
        }
    }

    private func enumerateAndWatch(directory path: String, relativePath: String) throws {
        try watchDirectory(path, relativePath: relativePath)

        let url = URL(fileURLWithPath: path)
        let contents: [URL]
        do {
            contents = try FileManager.default.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: []
            )
        } catch {
            throw Error.cannotAccess(path: path, underlying: error)
        }

        for itemURL in contents {
            do {
                let resourceValues = try itemURL.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])

                if resourceValues.isSymbolicLink == true {
                    continue
                }

                if resourceValues.isDirectory == true {
                    let itemName = itemURL.lastPathComponent
                    let subRelativePath = relativePath.isEmpty ? itemName : "\(relativePath)/\(itemName)"
                    try enumerateAndWatch(directory: itemURL.path(percentEncoded: false), relativePath: subRelativePath)
                }
            } catch let error as Error {
                throw error
            } catch {
                continue
            }
        }
    }

    private func startProcessingEvents() {
        let task = Task { [weak self] in
            guard let self else { return }

            for await kqueueEvent in self.kqueue.events {
                guard !Task.isCancelled else { break }
                self.processKQueueEvent(kqueueEvent)
            }
        }

        state.withLock { $0.processingTask = task }
    }

    private func processKQueueEvent(_ kqueueEvent: KQueue.Event) {
        let path = kqueueEvent.path
        let notification = kqueueEvent.notification

        let (rootURL, watchedDir) = state.withLock { state in
            (state.rootURL, state.watchedDirectories[path])
        }

        let relativePath = watchedDir?.relativePath ?? calculateRelativePath(
            absolutePath: path,
            rootPath: rootURL.path(percentEncoded: false)
        )

        let itemType = determineItemType(path: path)
        let changes = convertNotificationToChanges(notification, itemType: itemType)

        if notification.contains(.delete) {
            handleDeletion(path: path)
        }

        if notification.contains(.write), itemType == .directory {
            handleDirectoryContentsChange(path: path, relativePath: relativePath)
        }

        let event = Event(
            url: URL(fileURLWithPath: path),
            relativePath: relativePath,
            root: rootURL,
            changes: changes,
            itemType: itemType,
            rawNotification: notification
        )

        eventHandler?(event)
        eventsContinuation.yield(event)

        if notification.contains(.delete) {
            let rootPath = rootURL.path(percentEncoded: false)
            if path == rootPath {
                stop()
            }
        }
    }

    private func calculateRelativePath(absolutePath: String, rootPath: String) -> String {
        guard absolutePath.hasPrefix(rootPath) else { return absolutePath }

        var relative = String(absolutePath.dropFirst(rootPath.count))
        if relative.hasPrefix("/") {
            relative = String(relative.dropFirst())
        }
        return relative
    }

    private func determineItemType(path: String) -> ItemType {
        var isDirectory: ObjCBool = false

        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: path)
            if let typeAttribute = attributes[.type] as? FileAttributeType {
                switch typeAttribute {
                case .typeDirectory:
                    return .directory
                case .typeSymbolicLink:
                    return .symbolicLink
                case .typeRegular:
                    return .file
                default:
                    return .unknown
                }
            }
        } catch {
            if FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) {
                return isDirectory.boolValue ? .directory : .file
            }
        }

        return .unknown
    }

    private func convertNotificationToChanges(_ notification: KQueue.Notification, itemType: ItemType) -> Set<ChangeKind> {
        var changes = Set<ChangeKind>()

        if notification.contains(.delete) {
            changes.insert(.deleted)
        }
        if notification.contains(.write) || notification.contains(.extend) {
            if itemType != .directory {
                changes.insert(.modified)
            }
        }
        if notification.contains(.rename) {
            changes.insert(.renamed)
        }
        if notification.contains(.attrib) {
            changes.insert(.attributesChanged)
        }

        return changes
    }

    private func handleDeletion(path: String) {
        state.withLock { state in
            _ = state.watchedDirectories.removeValue(forKey: path)
        }
        kqueue.stopWatching(path)
    }

    private func handleDirectoryContentsChange(path: String, relativePath: String) {
        guard configuration.recursionMode == .recursive else { return }

        let knownContents = state.withLock {
            $0.watchedDirectories[path]?.knownContents ?? []
        }

        let currentContents: Set<String>
        do {
            currentContents = try Set(FileManager.default.contentsOfDirectory(atPath: path))
        } catch {
            return
        }

        let newItems = currentContents.subtracting(knownContents)
        let removedItems = knownContents.subtracting(currentContents)

        state.withLock { state in
            state.watchedDirectories[path]?.knownContents = currentContents
        }

        let rootURL = state.withLock { $0.rootURL }

        for itemName in newItems {
            let itemPath = (path as NSString).appendingPathComponent(itemName)
            let itemRelativePath = relativePath.isEmpty ? itemName : "\(relativePath)/\(itemName)"
            let itemType = determineItemType(path: itemPath)

            if itemType == .directory {
                do {
                    try enumerateAndWatch(directory: itemPath, relativePath: itemRelativePath)
                } catch {
                    continue
                }
            }

            let event = Event(
                url: URL(fileURLWithPath: itemPath),
                relativePath: itemRelativePath,
                root: rootURL,
                changes: [.created],
                itemType: itemType,
                rawNotification: .write
            )

            eventHandler?(event)
            eventsContinuation.yield(event)
        }

        for itemName in removedItems {
            let itemPath = (path as NSString).appendingPathComponent(itemName)
            let itemRelativePath = relativePath.isEmpty ? itemName : "\(relativePath)/\(itemName)"

            let event = Event(
                url: URL(fileURLWithPath: itemPath),
                relativePath: itemRelativePath,
                root: rootURL,
                changes: [.deleted],
                itemType: .unknown,
                rawNotification: .delete
            )

            eventHandler?(event)
            eventsContinuation.yield(event)
        }
    }
}

// MARK: - CustomStringConvertible

extension AsyncDirectoryWatch: CustomStringConvertible {
    public var description: String {
        let rootPath = root.path(percentEncoded: false)
        let count = watchedDirectoryCount
        let mode = configuration.recursionMode == .recursive ? "recursive" : "shallow"
        return "AsyncDirectoryWatch(\(rootPath), \(mode), watching: \(count) directories)"
    }
}
