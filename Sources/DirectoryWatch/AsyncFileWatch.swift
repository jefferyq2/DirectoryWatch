// MIT License
// Copyright (c) 2026 Marcin Krzyzanowski

import Foundation
import KQueue
import Synchronization

/// High-level single-file watcher built on KQueue.
/// Monitors a single file for modifications, deletion, rename, and attribute changes.
/// Automatically re-registers watch when a deleted file is recreated.
public final class AsyncFileWatch: Sendable {
    // MARK: - Public Types

    /// Type of file system change.
    public enum ChangeKind: Sendable, Hashable, CustomStringConvertible {
        case modified
        case deleted
        case renamed
        case attributesChanged

        public var description: String {
            switch self {
            case .modified: "modified"
            case .deleted: "deleted"
            case .renamed: "renamed"
            case .attributesChanged: "attributesChanged"
            }
        }
    }

    /// A file watch event.
    public struct Event: Sendable, Hashable {
        /// Absolute URL of the file.
        public let url: URL
        /// What kind of changes occurred.
        public let changes: Set<ChangeKind>
        /// The underlying KQueue notification flags.
        public let rawNotification: KQueue.Notification
    }

    /// Errors that can occur when using AsyncFileWatch.
    public enum Error: Swift.Error, LocalizedError {
        case notAFile(path: String)
        case cannotAccess(path: String, underlying: Swift.Error)
        case kqueueCreationFailed
        case kqueueError(KQueue.Error)

        public var errorDescription: String? {
            switch self {
            case let .notAFile(path):
                "Path is not a file: '\(path)'"
            case let .cannotAccess(path, underlying):
                "Cannot access '\(path)': \(underlying.localizedDescription)"
            case .kqueueCreationFailed:
                "Failed to create kqueue"
            case let .kqueueError(error):
                "KQueue error: \(error.localizedDescription)"
            }
        }
    }

    /// Configuration for file watching.
    public struct Configuration: Sendable {
        public var notifications: KQueue.Notification
        /// Interval to check if a deleted file has been recreated.
        public var resurrectionCheckInterval: Duration

        public static let `default` = Configuration(
            notifications: .default,
            resurrectionCheckInterval: .milliseconds(500)
        )

        public init(
            notifications: KQueue.Notification = .default,
            resurrectionCheckInterval: Duration = .milliseconds(500)
        ) {
            self.notifications = notifications
            self.resurrectionCheckInterval = resurrectionCheckInterval
        }
    }

    // MARK: - Private Types

    private struct State {
        var fileURL: URL
        var isActive: Bool
        var isPaused: Bool
        var isDeleted: Bool
        var processingTask: Task<Void, Never>?
        var resurrectionTask: Task<Void, Never>?
    }

    // MARK: - Properties

    private let kqueue: KQueue
    private let state: Mutex<State>
    private let configuration: Configuration
    private let eventHandler: (@Sendable (Event) -> Void)?
    private let eventsContinuation: AsyncStream<Event>.Continuation

    /// Events from the watched file.
    public let events: AsyncStream<Event>

    /// The file being watched.
    public var url: URL {
        state.withLock { $0.fileURL }
    }

    /// Whether watching is active.
    public var isWatching: Bool {
        state.withLock { $0.isActive }
    }

    /// Whether watching is paused.
    public var isPaused: Bool {
        state.withLock { $0.isPaused }
    }

    /// Whether the file has been deleted (watching for resurrection).
    public var isDeleted: Bool {
        state.withLock { $0.isDeleted }
    }

    // MARK: - Initialization

    /// Create a file watcher.
    ///
    /// - Parameters:
    ///   - url: The file to watch.
    ///   - configuration: Watch configuration.
    ///   - eventHandler: Optional callback for events (in addition to AsyncStream).
    /// - Throws: Error if the path is not a valid file or cannot be accessed.
    public init(
        url: URL,
        configuration: Configuration = .default,
        eventHandler: (@Sendable (Event) -> Void)? = nil
    ) throws {
        guard url.isFileURL else {
            throw Error.notAFile(path: url.absoluteString)
        }

        let path = url.path(percentEncoded: false)

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
              !isDirectory.boolValue else {
            throw Error.notAFile(path: path)
        }

        guard let kqueue = KQueue() else {
            throw Error.kqueueCreationFailed
        }

        self.kqueue = kqueue
        self.configuration = configuration
        self.eventHandler = eventHandler

        var continuation: AsyncStream<Event>.Continuation!
        self.events = AsyncStream { continuation = $0 }
        self.eventsContinuation = continuation

        self.state = Mutex(State(
            fileURL: url.standardizedFileURL,
            isActive: false,
            isPaused: false,
            isDeleted: false,
            processingTask: nil,
            resurrectionTask: nil
        ))
    }

    /// Create a file watcher from path string.
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

    /// Start watching the file.
    public func start() throws {
        let fileURL = state.withLock { state -> URL? in
            guard !state.isActive else { return nil }
            state.isActive = true
            state.isDeleted = false
            return state.fileURL
        }

        guard let fileURL else { return }

        do {
            try kqueue.watch(fileURL, for: configuration.notifications)
        } catch let error as KQueue.Error {
            state.withLock { $0.isActive = false }
            throw Error.kqueueError(error)
        }

        startProcessingEvents()
    }

    /// Stop watching and release all resources.
    public func stop() {
        let (processingTask, resurrectionTask) = state.withLock { state -> (Task<Void, Never>?, Task<Void, Never>?) in
            state.isActive = false
            state.isPaused = false
            state.isDeleted = false
            let processing = state.processingTask
            let resurrection = state.resurrectionTask
            state.processingTask = nil
            state.resurrectionTask = nil
            return (processing, resurrection)
        }

        processingTask?.cancel()
        resurrectionTask?.cancel()
        kqueue.stopWatchingAll()
        eventsContinuation.finish()
    }

    /// Pause event delivery temporarily.
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
        let notification = kqueueEvent.notification
        let fileURL = state.withLock { $0.fileURL }

        let changes = convertNotificationToChanges(notification)

        let event = Event(
            url: fileURL,
            changes: changes,
            rawNotification: notification
        )

        eventHandler?(event)
        eventsContinuation.yield(event)

        // Handle file deletion - start watching for resurrection
        if notification.contains(.delete) || notification.contains(.rename) {
            handleFileDeletion()
        }
    }

    private func convertNotificationToChanges(_ notification: KQueue.Notification) -> Set<ChangeKind> {
        var changes = Set<ChangeKind>()

        if notification.contains(.delete) {
            changes.insert(.deleted)
        }
        if notification.contains(.write) || notification.contains(.extend) {
            changes.insert(.modified)
        }
        if notification.contains(.rename) {
            changes.insert(.renamed)
        }
        if notification.contains(.attrib) {
            changes.insert(.attributesChanged)
        }

        return changes
    }

    private func handleFileDeletion() {
        let fileURL = state.withLock { state -> URL? in
            guard state.isActive, !state.isDeleted else { return nil }
            state.isDeleted = true
            return state.fileURL
        }

        guard let fileURL else { return }

        // Stop watching the deleted file
        kqueue.stopWatching(fileURL)

        // Start resurrection monitoring
        startResurrectionMonitoring(for: fileURL)
    }

    private func startResurrectionMonitoring(for fileURL: URL) {
        let task = Task { [weak self, configuration] in
            guard let self else { return }
            let path = fileURL.path(percentEncoded: false)

            while !Task.isCancelled {
                try? await Task.sleep(for: configuration.resurrectionCheckInterval)

                guard !Task.isCancelled else { break }

                // Check if file exists again
                var isDirectory: ObjCBool = false
                if FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
                   !isDirectory.boolValue {
                    // File is back - re-register watch
                    await self.handleFileResurrection(fileURL: fileURL)
                    break
                }
            }
        }

        state.withLock { $0.resurrectionTask = task }
    }

    private func handleFileResurrection(fileURL: URL) async {
        let shouldReregister = state.withLock { state -> Bool in
            guard state.isActive, state.isDeleted else { return false }
            state.isDeleted = false
            state.resurrectionTask = nil
            return true
        }

        guard shouldReregister else { return }

        do {
            try kqueue.watch(fileURL, for: configuration.notifications)

            // Emit a modified event to indicate the file has new content
            let event = Event(
                url: fileURL,
                changes: [.modified],
                rawNotification: .write
            )
            eventHandler?(event)
            eventsContinuation.yield(event)
        } catch {
            // Failed to re-register, stop watching
            stop()
        }
    }
}

// MARK: - CustomStringConvertible

extension AsyncFileWatch: CustomStringConvertible {
    public var description: String {
        let path = url.path(percentEncoded: false)
        let status = isDeleted ? "deleted, watching for resurrection" : (isWatching ? "active" : "inactive")
        return "AsyncFileWatch(\(path), \(status))"
    }
}
