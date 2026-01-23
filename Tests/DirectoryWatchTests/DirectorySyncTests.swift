@testable import DirectoryWatch
import Foundation
import Testing

@Suite("DirectorySync")
struct DirectorySyncTests {
    // MARK: - Initialization Tests

    @Test("Create watcher with valid directories")
    func createWithValidDirectories() async throws {
        let sourceDir = try createTempDirectory()
        let destDir = try createTempDirectory()
        defer { cleanup(sourceDir); cleanup(destDir) }

        let watcher = try DirectorySync(
            sourceURL: sourceDir,
            destinationURL: destDir
        )

        #expect(watcher.sourceURL == sourceDir.standardizedFileURL)
        #expect(watcher.destinationURL == destDir.standardizedFileURL)
        let isRunning = await watcher.isRunning
        #expect(!isRunning)
    }

    @Test("Fail to create watcher with non-existent source")
    func failWithNonExistentSource() async throws {
        let nonExistent = URL(fileURLWithPath: "/non/existent/path")
        let destDir = try createTempDirectory()
        defer { cleanup(destDir) }

        #expect(throws: DirectorySync.Error.self) {
            _ = try DirectorySync(
                sourceURL: nonExistent,
                destinationURL: destDir
            )
        }
    }

    // MARK: - Initial Diff Tests

    @Test("Initial diff detects new files to copy")
    func initialDiffDetectsNewFiles() async throws {
        let sourceDir = try createTempDirectory()
        let destDir = try createTempDirectory()
        defer { cleanup(sourceDir); cleanup(destDir) }

        // Create files in source
        try "Hello".write(to: sourceDir.appendingPathComponent("file1.txt"), atomically: true, encoding: .utf8)
        try "World".write(to: sourceDir.appendingPathComponent("file2.txt"), atomically: true, encoding: .utf8)

        let watcher = try DirectorySync(
            sourceURL: sourceDir,
            destinationURL: destDir,
            configuration: .init(computeInitialDiff: false)
        )

        let operations = await watcher.computeDiff()

        #expect(operations.count == 2)
        #expect(operations.contains { op in
            if case let .copyFile(src, dst) = op {
                return src.lastPathComponent == "file1.txt" && dst.lastPathComponent == "file1.txt"
            }
            return false
        })
        #expect(operations.contains { op in
            if case let .copyFile(src, dst) = op {
                return src.lastPathComponent == "file2.txt" && dst.lastPathComponent == "file2.txt"
            }
            return false
        })
    }

    @Test("Initial diff detects files to delete")
    func initialDiffDetectsFilesToDelete() async throws {
        let sourceDir = try createTempDirectory()
        let destDir = try createTempDirectory()
        defer { cleanup(sourceDir); cleanup(destDir) }

        // Create file only in destination (should be deleted)
        try "Orphan".write(to: destDir.appendingPathComponent("orphan.txt"), atomically: true, encoding: .utf8)

        let watcher = try DirectorySync(
            sourceURL: sourceDir,
            destinationURL: destDir,
            configuration: .init(computeInitialDiff: false)
        )

        let operations = await watcher.computeDiff()

        #expect(operations.count == 1)
        #expect(operations.contains { op in
            if case let .deleteFile(dst) = op {
                return dst.lastPathComponent == "orphan.txt"
            }
            return false
        })
    }

    @Test("Diff detects when source file is newer")
    func diffDetectsNewerSourceFile() async throws {
        let sourceDir = try createTempDirectory()
        let destDir = try createTempDirectory()
        defer { cleanup(sourceDir); cleanup(destDir) }

        // Create file in destination first (will be older)
        let dstFile = destDir.appendingPathComponent("data.txt")
        try "Old".write(to: dstFile, atomically: true, encoding: .utf8)

        // Wait to ensure clear time difference
        try await Task.sleep(for: .seconds(1.5))

        // Create file with same name in source (will be newer)
        let srcFile = sourceDir.appendingPathComponent("data.txt")
        try "New and longer content".write(to: srcFile, atomically: true, encoding: .utf8)

        let watcher = try DirectorySync(
            sourceURL: sourceDir,
            destinationURL: destDir,
            configuration: .init(computeInitialDiff: false)
        )

        let operations = await watcher.computeDiff()

        // Should detect the file needs updating (either by date or size)
        let hasUpdateOrCopy = operations.contains { op in
            switch op {
            case .updateFile, .copyFile:
                true
            default:
                false
            }
        }
        #expect(hasUpdateOrCopy)
    }

    @Test("Initial diff detects directories to create")
    func initialDiffDetectsDirectoriesToCreate() async throws {
        let sourceDir = try createTempDirectory()
        let destDir = try createTempDirectory()
        defer { cleanup(sourceDir); cleanup(destDir) }

        // Create subdirectory in source
        let subDir = sourceDir.appendingPathComponent("subdir")
        try FileManager.default.createDirectory(at: subDir, withIntermediateDirectories: true)

        let watcher = try DirectorySync(
            sourceURL: sourceDir,
            destinationURL: destDir,
            configuration: .init(computeInitialDiff: false)
        )

        let operations = await watcher.computeDiff()

        #expect(operations.contains { op in
            if case let .createDirectory(dst) = op {
                return dst.lastPathComponent == "subdir"
            }
            return false
        })
    }

    @Test("Initial diff detects directories to delete")
    func initialDiffDetectsDirectoriesToDelete() async throws {
        let sourceDir = try createTempDirectory()
        let destDir = try createTempDirectory()
        defer { cleanup(sourceDir); cleanup(destDir) }

        // Create subdirectory only in destination
        let orphanDir = destDir.appendingPathComponent("orphan_dir")
        try FileManager.default.createDirectory(at: orphanDir, withIntermediateDirectories: true)

        let watcher = try DirectorySync(
            sourceURL: sourceDir,
            destinationURL: destDir,
            configuration: .init(computeInitialDiff: false)
        )

        let operations = await watcher.computeDiff()

        #expect(operations.contains { op in
            if case let .deleteDirectory(dst) = op {
                return dst.lastPathComponent == "orphan_dir"
            }
            return false
        })
    }

    @Test("No operations when both directories are empty")
    func noOperationsWhenBothEmpty() async throws {
        let sourceDir = try createTempDirectory()
        let destDir = try createTempDirectory()
        defer { cleanup(sourceDir); cleanup(destDir) }

        let watcher = try DirectorySync(
            sourceURL: sourceDir,
            destinationURL: destDir,
            configuration: .init(computeInitialDiff: false)
        )

        let operations = await watcher.computeDiff()

        #expect(operations.isEmpty)
    }

    @Test("No operations when files are identical")
    func noOperationsWhenFilesIdentical() async throws {
        let sourceDir = try createTempDirectory()
        let destDir = try createTempDirectory()
        defer { cleanup(sourceDir); cleanup(destDir) }

        // Create file in source
        let srcFile = sourceDir.appendingPathComponent("file.txt")
        try "Same content".write(to: srcFile, atomically: true, encoding: .utf8)

        // Copy to destination (same content, same size)
        let dstFile = destDir.appendingPathComponent("file.txt")
        try FileManager.default.copyItem(at: srcFile, to: dstFile)

        let watcher = try DirectorySync(
            sourceURL: sourceDir,
            destinationURL: destDir,
            configuration: .init(computeInitialDiff: false)
        )

        let operations = await watcher.computeDiff()

        #expect(operations.isEmpty)
    }

    // MARK: - Watch Event Tests

    @Test("Start and stop watcher")
    func startAndStopWatcher() async throws {
        let sourceDir = try createTempDirectory()
        let destDir = try createTempDirectory()
        defer { cleanup(sourceDir); cleanup(destDir) }

        let watcher = try DirectorySync(
            sourceURL: sourceDir,
            destinationURL: destDir,
            configuration: .init(computeInitialDiff: false)
        )

        var isRunning = await watcher.isRunning
        #expect(!isRunning)

        try await watcher.start()
        isRunning = await watcher.isRunning
        #expect(isRunning)

        await watcher.stop()
        isRunning = await watcher.isRunning
        #expect(!isRunning)
    }

    @Test("Emits started and stopped events")
    func emitsStartedAndStoppedEvents() async throws {
        let sourceDir = try createTempDirectory()
        let destDir = try createTempDirectory()
        defer { cleanup(sourceDir); cleanup(destDir) }

        let watcher = try DirectorySync(
            sourceURL: sourceDir,
            destinationURL: destDir,
            configuration: .init(computeInitialDiff: false)
        )

        var receivedEvents: [DirectorySync.Event] = []

        let collectTask = Task {
            for await event in watcher.events {
                receivedEvents.append(event)
            }
        }

        try await watcher.start()
        try await Task.sleep(for: .milliseconds(50))
        await watcher.stop()

        collectTask.cancel()
        try await Task.sleep(for: .milliseconds(50))

        #expect(receivedEvents.contains { if case .started = $0 { return true }; return false })
        #expect(receivedEvents.contains { if case .stopped = $0 { return true }; return false })
    }

    @Test("Emits initial diff on start")
    func emitsInitialDiffOnStart() async throws {
        let sourceDir = try createTempDirectory()
        let destDir = try createTempDirectory()
        defer { cleanup(sourceDir); cleanup(destDir) }

        // Create file in source
        try "Test".write(to: sourceDir.appendingPathComponent("test.txt"), atomically: true, encoding: .utf8)

        let watcher = try DirectorySync(
            sourceURL: sourceDir,
            destinationURL: destDir,
            configuration: .init(computeInitialDiff: true)
        )

        var receivedEvents: [DirectorySync.Event] = []

        let collectTask = Task {
            for await event in watcher.events {
                receivedEvents.append(event)
            }
        }

        try await watcher.start()
        try await Task.sleep(for: .milliseconds(100))
        await watcher.stop()

        collectTask.cancel()

        let initialDiffEvent = receivedEvents.first { event in
            if case let .initialDiff(ops) = event {
                return !ops.isEmpty
            }
            return false
        }
        #expect(initialDiffEvent != nil)
    }

    @Test("Detects file creation in source")
    func detectsFileCreation() async throws {
        let sourceDir = try createTempDirectory()
        let destDir = try createTempDirectory()
        defer { cleanup(sourceDir); cleanup(destDir) }

        let watcher = try DirectorySync(
            sourceURL: sourceDir,
            destinationURL: destDir,
            configuration: .init(computeInitialDiff: false)
        )

        var receivedOperations: [DirectorySync.SyncOperation] = []

        let collectTask = Task {
            for await event in watcher.events {
                if case let .operation(op) = event {
                    receivedOperations.append(op)
                }
            }
        }

        try await watcher.start()
        try await Task.sleep(for: .milliseconds(100))

        // Create new file in source
        try "New file".write(to: sourceDir.appendingPathComponent("new.txt"), atomically: true, encoding: .utf8)

        try await Task.sleep(for: .milliseconds(300))
        await watcher.stop()
        collectTask.cancel()

        let copyOp = receivedOperations.first { op in
            if case let .copyFile(src, _) = op {
                return src.lastPathComponent == "new.txt"
            }
            return false
        }
        #expect(copyOp != nil)
    }

    @Test("Detects file deletion in source")
    func detectsFileDeletion() async throws {
        let sourceDir = try createTempDirectory()
        let destDir = try createTempDirectory()
        defer { cleanup(sourceDir); cleanup(destDir) }

        // Create file first
        let testFile = sourceDir.appendingPathComponent("to_delete.txt")
        try "Delete me".write(to: testFile, atomically: true, encoding: .utf8)

        let watcher = try DirectorySync(
            sourceURL: sourceDir,
            destinationURL: destDir,
            configuration: .init(computeInitialDiff: false)
        )

        var receivedOperations: [DirectorySync.SyncOperation] = []

        let collectTask = Task {
            for await event in watcher.events {
                if case let .operation(op) = event {
                    receivedOperations.append(op)
                }
            }
        }

        try await watcher.start()
        try await Task.sleep(for: .milliseconds(100))

        // Delete the file
        try FileManager.default.removeItem(at: testFile)

        try await Task.sleep(for: .milliseconds(300))
        await watcher.stop()
        collectTask.cancel()

        let deleteOp = receivedOperations.first { op in
            if case let .deleteFile(dst) = op {
                return dst.lastPathComponent == "to_delete.txt"
            }
            return false
        }
        #expect(deleteOp != nil)
    }

    // MARK: - Exclusion Pattern Tests

    @Test("Excludes files matching patterns")
    func excludesFilesMatchingPatterns() async throws {
        let sourceDir = try createTempDirectory()
        let destDir = try createTempDirectory()
        defer { cleanup(sourceDir); cleanup(destDir) }

        // Create files including one that should be excluded
        try "Include".write(to: sourceDir.appendingPathComponent("include.txt"), atomically: true, encoding: .utf8)
        try "Exclude".write(to: sourceDir.appendingPathComponent(".DS_Store"), atomically: true, encoding: .utf8)

        let watcher = try DirectorySync(
            sourceURL: sourceDir,
            destinationURL: destDir,
            configuration: .init(
                computeInitialDiff: false,
                excludePatterns: [".DS_Store"],
                includeHiddenFiles: true
            )
        )

        let operations = await watcher.computeDiff()

        // Should only have operation for include.txt
        #expect(operations.count == 1)
        #expect(operations.contains { op in
            if case let .copyFile(src, _) = op {
                return src.lastPathComponent == "include.txt"
            }
            return false
        })
    }

    @Test("Excludes directories matching patterns")
    func excludesDirectoriesMatchingPatterns() async throws {
        let sourceDir = try createTempDirectory()
        let destDir = try createTempDirectory()
        defer { cleanup(sourceDir); cleanup(destDir) }

        // Create directories including one that should be excluded
        let includeDir = sourceDir.appendingPathComponent("include")
        let excludeDir = sourceDir.appendingPathComponent(".git")

        try FileManager.default.createDirectory(at: includeDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: excludeDir, withIntermediateDirectories: true)

        // Create file inside excluded directory
        try "Hidden".write(to: excludeDir.appendingPathComponent("config"), atomically: true, encoding: .utf8)

        let watcher = try DirectorySync(
            sourceURL: sourceDir,
            destinationURL: destDir,
            configuration: .init(
                computeInitialDiff: false,
                excludePatterns: [".git"],
                includeHiddenFiles: true
            )
        )

        let operations = await watcher.computeDiff()

        // Should only have operation for include directory
        #expect(operations.count == 1)
        #expect(operations.contains { op in
            if case let .createDirectory(dst) = op {
                return dst.lastPathComponent == "include"
            }
            return false
        })
    }

    // MARK: - Nested Directory Tests

    @Test("Handles nested directory structure")
    func handlesNestedDirectoryStructure() async throws {
        let sourceDir = try createTempDirectory()
        let destDir = try createTempDirectory()
        defer { cleanup(sourceDir); cleanup(destDir) }

        // Create nested structure: level1/level2/file.txt
        let level1 = sourceDir.appendingPathComponent("level1")
        let level2 = level1.appendingPathComponent("level2")
        try FileManager.default.createDirectory(at: level2, withIntermediateDirectories: true)
        try "Deep".write(to: level2.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)

        let watcher = try DirectorySync(
            sourceURL: sourceDir,
            destinationURL: destDir,
            configuration: .init(computeInitialDiff: false)
        )

        let operations = await watcher.computeDiff()

        // Should have: createDirectory(level1), createDirectory(level2), copyFile(file.txt)
        #expect(operations.count == 3)

        // Directories should be created shallowest first
        let dirOps = operations.compactMap { op -> String? in
            if case let .createDirectory(dst) = op {
                return dst.lastPathComponent
            }
            return nil
        }
        #expect(dirOps == ["level1", "level2"])
    }

    @Test("Deletes nested directories deepest first")
    func deletesNestedDirectoriesDeepestFirst() async throws {
        let sourceDir = try createTempDirectory()
        let destDir = try createTempDirectory()
        defer { cleanup(sourceDir); cleanup(destDir) }

        // Create nested structure only in destination
        let level1 = destDir.appendingPathComponent("level1")
        let level2 = level1.appendingPathComponent("level2")
        try FileManager.default.createDirectory(at: level2, withIntermediateDirectories: true)
        try "Deep".write(to: level2.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)

        let watcher = try DirectorySync(
            sourceURL: sourceDir,
            destinationURL: destDir,
            configuration: .init(computeInitialDiff: false)
        )

        let operations = await watcher.computeDiff()

        // Should delete deepest first: file.txt, level2, level1
        let deleteOps = operations.compactMap { op -> String? in
            switch op {
            case let .deleteFile(dst), let .deleteDirectory(dst):
                return dst.lastPathComponent
            default:
                return nil
            }
        }
        #expect(deleteOps == ["file.txt", "level2", "level1"])
    }

    // MARK: - Sync Workflow Tests

    @Test("Sync workflow: add, remove, rename files")
    func syncWorkflow() throws {
        let fm = FileManager.default
        let sourceDir = try createTempDirectory()
        let destDir = try createTempDirectory()
        defer { cleanup(sourceDir); cleanup(destDir) }

        // Step 1: Initial state - add files to source
        try "main content".write(to: sourceDir.appendingPathComponent("main.swift"), atomically: true, encoding: .utf8)
        try "lib content".write(to: sourceDir.appendingPathComponent("lib.swift"), atomically: true, encoding: .utf8)

        // First diff - should copy both files
        var ops = DirectorySync.computeDiff(source: sourceDir, destination: destDir)
        #expect(ops.count == 2)
        #expect(ops.allSatisfy { if case .copyFile = $0 { true } else { false } })

        // Apply operations
        for op in ops {
            switch op {
            case let .copyFile(src, dst):
                try fm.copyItem(at: src, to: dst)
            default:
                break
            }
        }

        // Verify sync - should be empty now
        ops = DirectorySync.computeDiff(source: sourceDir, destination: destDir)
        #expect(ops.isEmpty, "After sync, diff should be empty but got: \(ops)")

        // Step 2: Add new file
        try "helper content".write(to: sourceDir.appendingPathComponent("helper.swift"), atomically: true, encoding: .utf8)

        ops = DirectorySync.computeDiff(source: sourceDir, destination: destDir)
        #expect(ops.count == 1)
        if case let .copyFile(src, _) = ops.first {
            #expect(src.lastPathComponent == "helper.swift")
        } else {
            Issue.record("Expected copyFile for helper.swift")
        }

        // Apply
        for op in ops {
            if case let .copyFile(src, dst) = op {
                try fm.copyItem(at: src, to: dst)
            }
        }

        // Step 3: Remove file from source
        try fm.removeItem(at: sourceDir.appendingPathComponent("lib.swift"))

        ops = DirectorySync.computeDiff(source: sourceDir, destination: destDir)
        #expect(ops.count == 1)
        if case let .deleteFile(dst) = ops.first {
            #expect(dst.lastPathComponent == "lib.swift")
        } else {
            Issue.record("Expected deleteFile for lib.swift, got: \(ops)")
        }

        // Apply
        for op in ops {
            if case let .deleteFile(dst) = op {
                try fm.removeItem(at: dst)
            }
        }

        // Step 4: Rename file (simulated as delete + add)
        try fm.moveItem(
            at: sourceDir.appendingPathComponent("helper.swift"),
            to: sourceDir.appendingPathComponent("utils.swift")
        )

        ops = DirectorySync.computeDiff(source: sourceDir, destination: destDir)
        #expect(ops.count == 2, "Rename should produce delete + copy, got: \(ops)")

        let deleteOps = ops.filter { if case .deleteFile = $0 { true } else { false } }
        let copyOps = ops.filter { if case .copyFile = $0 { true } else { false } }

        #expect(deleteOps.count == 1)
        #expect(copyOps.count == 1)

        if case let .deleteFile(dst) = deleteOps.first {
            #expect(dst.lastPathComponent == "helper.swift")
        }
        if case let .copyFile(src, _) = copyOps.first {
            #expect(src.lastPathComponent == "utils.swift")
        }

        // Apply all
        for op in ops {
            switch op {
            case let .deleteFile(dst):
                try fm.removeItem(at: dst)
            case let .copyFile(src, dst):
                try fm.copyItem(at: src, to: dst)
            default:
                break
            }
        }

        // Final verification
        ops = DirectorySync.computeDiff(source: sourceDir, destination: destDir)
        #expect(ops.isEmpty, "Final diff should be empty but got: \(ops)")

        let sourceFiles = try Set(fm.contentsOfDirectory(atPath: sourceDir.path))
        let destFiles = try Set(fm.contentsOfDirectory(atPath: destDir.path))
        #expect(sourceFiles == destFiles)
        #expect(sourceFiles == ["main.swift", "utils.swift"])
    }

    // MARK: - Rename Detection Tests

    @Test("Detects file rename as delete plus copy")
    func detectsFileRename() throws {
        let sourceDir = try createTempDirectory()
        let destDir = try createTempDirectory()
        defer { cleanup(sourceDir); cleanup(destDir) }

        // Set up initial state: file exists in both directories with same name
        try "content".write(to: sourceDir.appendingPathComponent("original.txt"), atomically: true, encoding: .utf8)
        try "content".write(to: destDir.appendingPathComponent("original.txt"), atomically: true, encoding: .utf8)

        // Simulate rename in source: original.txt -> renamed.txt
        try FileManager.default.moveItem(
            at: sourceDir.appendingPathComponent("original.txt"),
            to: sourceDir.appendingPathComponent("renamed.txt")
        )

        let operations = DirectorySync.computeDiff(source: sourceDir, destination: destDir)

        // Rename should produce: delete old file + copy new file
        #expect(operations.count == 2)

        let deleteOps = operations.filter { if case .deleteFile = $0 { true } else { false } }
        let copyOps = operations.filter { if case .copyFile = $0 { true } else { false } }

        #expect(deleteOps.count == 1)
        #expect(copyOps.count == 1)

        if case let .deleteFile(dst) = deleteOps.first {
            #expect(dst.lastPathComponent == "original.txt")
        } else {
            Issue.record("Expected deleteFile for original.txt")
        }

        if case let .copyFile(src, dst) = copyOps.first {
            #expect(src.lastPathComponent == "renamed.txt")
            #expect(dst.lastPathComponent == "renamed.txt")
        } else {
            Issue.record("Expected copyFile for renamed.txt")
        }
    }

    @Test("Detects directory rename as delete plus create")
    func detectsDirectoryRename() throws {
        let sourceDir = try createTempDirectory()
        let destDir = try createTempDirectory()
        defer { cleanup(sourceDir); cleanup(destDir) }

        // Set up initial state: directory exists in both with same name
        let srcOriginal = sourceDir.appendingPathComponent("original_dir")
        let dstOriginal = destDir.appendingPathComponent("original_dir")
        try FileManager.default.createDirectory(at: srcOriginal, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dstOriginal, withIntermediateDirectories: true)

        // Simulate rename in source: original_dir -> renamed_dir
        try FileManager.default.moveItem(
            at: srcOriginal,
            to: sourceDir.appendingPathComponent("renamed_dir")
        )

        let operations = DirectorySync.computeDiff(source: sourceDir, destination: destDir)

        // Rename should produce: delete old directory + create new directory
        #expect(operations.count == 2)

        let deleteOps = operations.filter { if case .deleteDirectory = $0 { true } else { false } }
        let createOps = operations.filter { if case .createDirectory = $0 { true } else { false } }

        #expect(deleteOps.count == 1)
        #expect(createOps.count == 1)

        if case let .deleteDirectory(dst) = deleteOps.first {
            #expect(dst.lastPathComponent == "original_dir")
        } else {
            Issue.record("Expected deleteDirectory for original_dir")
        }

        if case let .createDirectory(dst) = createOps.first {
            #expect(dst.lastPathComponent == "renamed_dir")
        } else {
            Issue.record("Expected createDirectory for renamed_dir")
        }
    }

    @Test("Detects directory rename with contents")
    func detectsDirectoryRenameWithContents() throws {
        let sourceDir = try createTempDirectory()
        let destDir = try createTempDirectory()
        defer { cleanup(sourceDir); cleanup(destDir) }

        // Set up initial state: directory with files in both locations
        let srcOriginal = sourceDir.appendingPathComponent("original_dir")
        let dstOriginal = destDir.appendingPathComponent("original_dir")
        try FileManager.default.createDirectory(at: srcOriginal, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dstOriginal, withIntermediateDirectories: true)
        try "file1".write(to: srcOriginal.appendingPathComponent("file1.txt"), atomically: true, encoding: .utf8)
        try "file2".write(to: srcOriginal.appendingPathComponent("file2.txt"), atomically: true, encoding: .utf8)
        try "file1".write(to: dstOriginal.appendingPathComponent("file1.txt"), atomically: true, encoding: .utf8)
        try "file2".write(to: dstOriginal.appendingPathComponent("file2.txt"), atomically: true, encoding: .utf8)

        // Simulate rename in source: original_dir -> renamed_dir (with contents)
        try FileManager.default.moveItem(
            at: srcOriginal,
            to: sourceDir.appendingPathComponent("renamed_dir")
        )

        let operations = DirectorySync.computeDiff(source: sourceDir, destination: destDir)

        // Should delete old contents (deepest first) then create new directory + copy files
        // Delete: file1.txt, file2.txt, original_dir
        // Create: renamed_dir, copy file1.txt, copy file2.txt

        let deleteFileOps = operations.filter { if case .deleteFile = $0 { true } else { false } }
        let deleteDirOps = operations.filter { if case .deleteDirectory = $0 { true } else { false } }
        let createDirOps = operations.filter { if case .createDirectory = $0 { true } else { false } }
        let copyOps = operations.filter { if case .copyFile = $0 { true } else { false } }

        #expect(deleteFileOps.count == 2, "Should delete 2 files from old directory")
        #expect(deleteDirOps.count == 1, "Should delete old directory")
        #expect(createDirOps.count == 1, "Should create new directory")
        #expect(copyOps.count == 2, "Should copy 2 files to new directory")

        // Verify the directory operations
        if case let .deleteDirectory(dst) = deleteDirOps.first {
            #expect(dst.lastPathComponent == "original_dir")
        }
        if case let .createDirectory(dst) = createDirOps.first {
            #expect(dst.lastPathComponent == "renamed_dir")
        }
    }

    @Test("Detects file rename within subdirectory")
    func detectsFileRenameInSubdirectory() throws {
        let sourceDir = try createTempDirectory()
        let destDir = try createTempDirectory()
        defer { cleanup(sourceDir); cleanup(destDir) }

        // Set up: subdirectory with a file in both locations
        let srcSubdir = sourceDir.appendingPathComponent("subdir")
        let dstSubdir = destDir.appendingPathComponent("subdir")
        try FileManager.default.createDirectory(at: srcSubdir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dstSubdir, withIntermediateDirectories: true)
        try "content".write(to: srcSubdir.appendingPathComponent("old_name.txt"), atomically: true, encoding: .utf8)
        try "content".write(to: dstSubdir.appendingPathComponent("old_name.txt"), atomically: true, encoding: .utf8)

        // Rename file inside subdirectory
        try FileManager.default.moveItem(
            at: srcSubdir.appendingPathComponent("old_name.txt"),
            to: srcSubdir.appendingPathComponent("new_name.txt")
        )

        let operations = DirectorySync.computeDiff(source: sourceDir, destination: destDir)

        #expect(operations.count == 2)

        let deleteOps = operations.filter { if case .deleteFile = $0 { true } else { false } }
        let copyOps = operations.filter { if case .copyFile = $0 { true } else { false } }

        #expect(deleteOps.count == 1)
        #expect(copyOps.count == 1)

        // Verify paths include the subdirectory
        if case let .deleteFile(dst) = deleteOps.first {
            #expect(dst.path.contains("subdir/old_name.txt") || dst.path.contains("subdir\\old_name.txt"))
        }
        if case let .copyFile(src, dst) = copyOps.first {
            #expect(src.path.contains("subdir/new_name.txt") || src.path.contains("subdir\\new_name.txt"))
            #expect(dst.path.contains("subdir/new_name.txt") || dst.path.contains("subdir\\new_name.txt"))
        }
    }

    @Test("Detects file move between directories as delete plus copy")
    func detectsFileMovesBetweenDirectories() throws {
        let sourceDir = try createTempDirectory()
        let destDir = try createTempDirectory()
        defer { cleanup(sourceDir); cleanup(destDir) }

        // Set up: file in dir_a in both locations, empty dir_b
        let srcDirA = sourceDir.appendingPathComponent("dir_a")
        let srcDirB = sourceDir.appendingPathComponent("dir_b")
        let dstDirA = destDir.appendingPathComponent("dir_a")
        let dstDirB = destDir.appendingPathComponent("dir_b")

        try FileManager.default.createDirectory(at: srcDirA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: srcDirB, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dstDirA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dstDirB, withIntermediateDirectories: true)

        try "content".write(to: srcDirA.appendingPathComponent("movable.txt"), atomically: true, encoding: .utf8)
        try "content".write(to: dstDirA.appendingPathComponent("movable.txt"), atomically: true, encoding: .utf8)

        // Move file from dir_a to dir_b in source
        try FileManager.default.moveItem(
            at: srcDirA.appendingPathComponent("movable.txt"),
            to: srcDirB.appendingPathComponent("movable.txt")
        )

        let operations = DirectorySync.computeDiff(source: sourceDir, destination: destDir)

        // Move should appear as delete from old location + copy to new location
        #expect(operations.count == 2)

        let deleteOps = operations.filter { if case .deleteFile = $0 { true } else { false } }
        let copyOps = operations.filter { if case .copyFile = $0 { true } else { false } }

        #expect(deleteOps.count == 1)
        #expect(copyOps.count == 1)

        if case let .deleteFile(dst) = deleteOps.first {
            #expect(dst.path.contains("dir_a/movable.txt") || dst.path.contains("dir_a\\movable.txt"))
        }
        if case let .copyFile(src, dst) = copyOps.first {
            #expect(src.path.contains("dir_b/movable.txt") || src.path.contains("dir_b\\movable.txt"))
            #expect(dst.path.contains("dir_b/movable.txt") || dst.path.contains("dir_b\\movable.txt"))
        }
    }

    // MARK: - Helpers

    private func createTempDirectory() throws -> URL {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DirectorySyncTest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        return tempDir
    }

    private func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }
}
