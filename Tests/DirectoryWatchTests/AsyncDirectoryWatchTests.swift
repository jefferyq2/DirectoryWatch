@testable import DirectoryWatch
import Foundation
import Testing

@Suite("AsyncDirectoryWatch")
struct AsyncDirectoryWatchTests {
    @Test("Create and start watcher")
    func createAndStart() async throws {
        let tempDir = try createTempDirectory()
        defer { cleanup(tempDir) }

        let watcher = try AsyncDirectoryWatch(url: tempDir)
        #expect(watcher.watchedDirectoryCount == 0)

        try watcher.start()
        #expect(watcher.isWatching)
        #expect(watcher.watchedDirectoryCount == 1)

        watcher.stop()
        #expect(!watcher.isWatching)
    }

    @Test("Detect file creation")
    func detectFileCreation() async throws {
        let tempDir = try createTempDirectory()
        defer { cleanup(tempDir) }

        var receivedEvents: [AsyncDirectoryWatch.Event] = []
        let watcher = try AsyncDirectoryWatch(url: tempDir) { event in
            receivedEvents.append(event)
        }
        try watcher.start()

        try await Task.sleep(for: .milliseconds(50))

        let testFile = tempDir.appendingPathComponent("test.txt")
        try "Hello".write(to: testFile, atomically: true, encoding: .utf8)

        try await Task.sleep(for: .milliseconds(300))

        watcher.stop()

        let createdEvent = receivedEvents.first { $0.changes.contains(.created) && $0.relativePath == "test.txt" }
        #expect(createdEvent != nil)
        #expect(createdEvent?.itemType == .file)
    }

    @Test("Recursive subdirectory watching")
    func recursiveSubdirectoryWatching() async throws {
        let tempDir = try createTempDirectory()
        defer { cleanup(tempDir) }

        var receivedEvents: [AsyncDirectoryWatch.Event] = []
        let watcher = try AsyncDirectoryWatch(
            url: tempDir,
            configuration: .init(recursionMode: .recursive)
        ) { event in
            receivedEvents.append(event)
        }
        try watcher.start()

        try await Task.sleep(for: .milliseconds(50))

        // Create subdirectory
        let subDir = tempDir.appendingPathComponent("subdir")
        try FileManager.default.createDirectory(at: subDir, withIntermediateDirectories: true)

        try await Task.sleep(for: .milliseconds(200))

        // Create file in subdirectory
        let nestedFile = subDir.appendingPathComponent("nested.txt")
        try "Nested".write(to: nestedFile, atomically: true, encoding: .utf8)

        try await Task.sleep(for: .milliseconds(300))

        watcher.stop()

        // Should have event for subdir creation
        let subdirEvent = receivedEvents.first { $0.relativePath == "subdir" && $0.changes.contains(.created) }
        #expect(subdirEvent != nil)

        // Should have event for nested file
        let nestedEvent = receivedEvents.first { $0.relativePath == "subdir/nested.txt" }
        #expect(nestedEvent != nil)
    }

    @Test("Pause and resume")
    func pauseAndResume() async throws {
        let tempDir = try createTempDirectory()
        defer { cleanup(tempDir) }

        let watcher = try AsyncDirectoryWatch(url: tempDir)
        try watcher.start()

        #expect(!watcher.isPaused)

        watcher.pause()
        #expect(watcher.isPaused)

        watcher.resume()
        #expect(!watcher.isPaused)

        watcher.stop()
    }

    @Test("Events not delivered while paused")
    func eventsNotDeliveredWhilePaused() async throws {
        let tempDir = try createTempDirectory()
        defer { cleanup(tempDir) }

        var receivedEvents: [AsyncDirectoryWatch.Event] = []
        let watcher = try AsyncDirectoryWatch(url: tempDir) { event in
            receivedEvents.append(event)
        }
        try watcher.start()

        try await Task.sleep(for: .milliseconds(50))

        watcher.pause()

        // Create file while paused
        let pausedFile = tempDir.appendingPathComponent("paused.txt")
        try "Created while paused".write(to: pausedFile, atomically: true, encoding: .utf8)

        try await Task.sleep(for: .milliseconds(200))

        // Should not have received event for paused.txt
        let pausedEvents = receivedEvents.filter { $0.relativePath == "paused.txt" }
        #expect(pausedEvents.isEmpty)

        watcher.resume()

        // Create another file after resume
        let afterResumeFile = tempDir.appendingPathComponent("after_resume.txt")
        try "After resume".write(to: afterResumeFile, atomically: true, encoding: .utf8)

        try await Task.sleep(for: .milliseconds(300))

        watcher.stop()

        // Should receive event for after_resume.txt
        let afterResumeEvents = receivedEvents.filter { $0.relativePath == "after_resume.txt" }
        #expect(!afterResumeEvents.isEmpty)
    }

    @Test("Shallow mode only watches root")
    func shallowModeOnlyWatchesRoot() async throws {
        let tempDir = try createTempDirectory()
        defer { cleanup(tempDir) }

        // Create subdirectory before starting watcher
        let subDir = tempDir.appendingPathComponent("existing_subdir")
        try FileManager.default.createDirectory(at: subDir, withIntermediateDirectories: true)

        let watcher = try AsyncDirectoryWatch(
            url: tempDir,
            configuration: .init(recursionMode: .shallow)
        )
        try watcher.start()

        // Should only watch root directory
        #expect(watcher.watchedDirectoryCount == 1)

        watcher.stop()
    }

    @Test("File deletion detection")
    func fileDelection() async throws {
        let tempDir = try createTempDirectory()
        defer { cleanup(tempDir) }

        let testFile = tempDir.appendingPathComponent("to_delete.txt")
        try "Delete me".write(to: testFile, atomically: true, encoding: .utf8)

        var receivedEvents: [AsyncDirectoryWatch.Event] = []
        let watcher = try AsyncDirectoryWatch(url: tempDir) { event in
            receivedEvents.append(event)
        }
        try watcher.start()

        try await Task.sleep(for: .milliseconds(50))

        try FileManager.default.removeItem(at: testFile)

        try await Task.sleep(for: .milliseconds(300))

        watcher.stop()

        let deleteEvent = receivedEvents.first { $0.changes.contains(.deleted) && $0.relativePath == "to_delete.txt" }
        #expect(deleteEvent != nil)
    }

    // MARK: - Helpers

    private func createTempDirectory() throws -> URL {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DirectoryWatchTest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        return tempDir
    }

    private func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }
}

extension AsyncDirectoryWatchTests {
    @Test("Deep nested directory watching")
    func deepNestedDirectoryWatching() async throws {
        let tempDir = try createTempDirectory()
        defer { cleanup(tempDir) }

        var receivedEvents: [AsyncDirectoryWatch.Event] = []
        let watcher = try AsyncDirectoryWatch(
            url: tempDir,
            configuration: .init(recursionMode: .recursive)
        ) { event in
            receivedEvents.append(event)
        }
        try watcher.start()

        try await Task.sleep(for: .milliseconds(50))

        // Create level1/level2/level3 directories
        let level1 = tempDir.appendingPathComponent("level1")
        try FileManager.default.createDirectory(at: level1, withIntermediateDirectories: true)
        try await Task.sleep(for: .milliseconds(200))

        let level2 = level1.appendingPathComponent("level2")
        try FileManager.default.createDirectory(at: level2, withIntermediateDirectories: true)
        try await Task.sleep(for: .milliseconds(200))

        let level3 = level2.appendingPathComponent("level3")
        try FileManager.default.createDirectory(at: level3, withIntermediateDirectories: true)
        try await Task.sleep(for: .milliseconds(200))

        // Create file in deepest directory
        let deepFile = level3.appendingPathComponent("deep.txt")
        try "Deep".write(to: deepFile, atomically: true, encoding: .utf8)
        try await Task.sleep(for: .milliseconds(300))

        print("Watched directories: \(watcher.watchedDirectoryCount)")
        print("Events received: \(receivedEvents.map { "\($0.relativePath): \($0.changes)" })")

        watcher.stop()

        // Should be watching: root, level1, level2, level3 = 4 directories
        #expect(watcher.watchedDirectoryCount == 0) // after stop, should be 0

        // Should have events for each level
        let level1Event = receivedEvents.first { $0.relativePath == "level1" }
        let level2Event = receivedEvents.first { $0.relativePath == "level1/level2" }
        let level3Event = receivedEvents.first { $0.relativePath == "level1/level2/level3" }
        let deepFileEvent = receivedEvents.first { $0.relativePath == "level1/level2/level3/deep.txt" }

        #expect(level1Event != nil)
        #expect(level2Event != nil)
        #expect(level3Event != nil)
        #expect(deepFileEvent != nil)
    }

    @Test("Deep file deletion from subdirectory watch")
    func deepFileDeletionFromSubdirectoryWatch() async throws {
        let tempDir = try createTempDirectory()
        defer { cleanup(tempDir) }

        // Create pre-existing deep structure: tempDir/level1/level2/level3/deep.txt
        let level1 = tempDir.appendingPathComponent("level1")
        let level2 = level1.appendingPathComponent("level2")
        let level3 = level2.appendingPathComponent("level3")
        let deepFile = level3.appendingPathComponent("deep.txt")

        try FileManager.default.createDirectory(at: level3, withIntermediateDirectories: true)
        try "Deep content".write(to: deepFile, atomically: true, encoding: .utf8)

        // Watch level1 (not tempDir) - simulating watching a subdirectory
        var receivedEvents: [AsyncDirectoryWatch.Event] = []
        let watcher = try AsyncDirectoryWatch(
            url: level1,
            configuration: .init(recursionMode: .recursive)
        ) { event in
            receivedEvents.append(event)
        }
        try watcher.start()

        // Should watch: level1, level2, level3 = 3 directories
        #expect(watcher.watchedDirectoryCount == 3)
        #expect(watcher.root.standardizedFileURL == level1.standardizedFileURL)

        try await Task.sleep(for: .milliseconds(100))

        // Delete the deep file
        try FileManager.default.removeItem(at: deepFile)

        try await Task.sleep(for: .milliseconds(300))

        watcher.stop()

        // Should receive deletion event with path relative to level1
        let deleteEvent = receivedEvents.first {
            $0.changes.contains(.deleted) && $0.relativePath == "level2/level3/deep.txt"
        }
        #expect(deleteEvent != nil)
        #expect(deleteEvent?.root.standardizedFileURL == level1.standardizedFileURL)
    }
}
