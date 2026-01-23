# DirectoryWatch

A Swift package for monitoring directory changes using BSD kqueue. Provides FSEvents-like recursive directory watching with fine-grained control.

## Features

- **Recursive or shallow monitoring** - Watch entire directory trees or single directories
- **Rich event information** - Events include both absolute URLs and relative paths
- **Automatic subdirectory tracking** - New directories are automatically watched in recursive mode
- **File descriptor limit protection** - Throws clear errors when system limits are reached
- **Swift Concurrency support** - AsyncStream-based event delivery with optional callback handler

## Requirements

- macOS 15.0+ / iOS 18.0+ / tvOS 18.0+ / watchOS 11.0+ / visionOS 2.0+
- Swift 5.9+

## Installation

Add DirectoryWatch to your `Package.swift`:

```swift
dependencies: [
    .package(path: "../DirectoryWatch")  // Local package
]
```

## Usage

### Basic Usage

```swift
import DirectoryWatch

let watcher = try AsyncDirectoryWatch(url: projectURL)
try watcher.start()

for await event in watcher.events {
    print("[\(event.changes)] \(event.relativePath)")
}
```

### Configuration

```swift
let config = AsyncDirectoryWatch.Configuration(
    recursionMode: .shallow,           // or .recursive (default)
    notifications: [.write, .delete]   // KQueue notification types
)

let watcher = try AsyncDirectoryWatch(
    url: directoryURL,
    configuration: config
)
```

### Callback Handler

```swift
let watcher = try AsyncDirectoryWatch(url: directoryURL) { event in
    print("Changed: \(event.relativePath)")
}
try watcher.start()
```

### Pause and Resume

```swift
// Pause event delivery (file descriptors remain open)
watcher.pause()

// Resume event delivery
watcher.resume()
```

While paused, file descriptors remain open but events are discarded.

## Event Structure

```swift
public struct Event: Sendable, Hashable {
    public let url: URL                    // Absolute URL
    public let relativePath: String        // Path relative to watched root
    public let root: URL                   // The watched root directory
    public let changes: Set<ChangeKind>    // What changed
    public let itemType: ItemType          // file, directory, symbolicLink, unknown
    public let rawNotification: KQueue.Notification
}
```

> **Note:** The `url` and `root` properties return standardized file URLs. When comparing URLs, use `standardizedFileURL` to ensure consistent comparison (e.g., `event.root.standardizedFileURL == myURL.standardizedFileURL`), as trailing slashes and other path variations may differ.

### Change Kinds

- `.created` - New file or directory
- `.modified` - File contents changed
- `.deleted` - Item removed
- `.renamed` - Item renamed
- `.attributesChanged` - Permissions, timestamps, etc.

## API Reference

### AsyncDirectoryWatch

```swift
// Initialize
init(url: URL, configuration: Configuration, eventHandler: ((Event) -> Void)?) throws
init(path: String, configuration: Configuration, eventHandler: ((Event) -> Void)?) throws

// Control
func start() throws
func stop()
func pause()
func resume()

// Properties
var events: AsyncStream<Event>
var root: URL
var watchedDirectoryCount: Int
var watchedPaths: [String]
var isWatching: Bool
var isPaused: Bool
```

### Configuration

```swift
struct Configuration: Sendable {
    var recursionMode: RecursionMode  // .shallow or .recursive
    var notifications: KQueue.Notification

    static let `default`  // recursive with default notifications
}
```

## How It Works

DirectoryWatch wraps the low-level [KQueue](https://github.com/krzyzanowskim/KQueue.git) package to provide directory-level monitoring:

1. **Initialization** - Validates the path is a directory
2. **Start** - Enumerates directory tree (if recursive) and watches each directory
3. **Event Detection** - Processes KQueue events and enriches them with path information
4. **New Item Detection** - Compares directory contents on write events to detect new files/subdirectories
5. **Cleanup** - Stops watching deleted directories automatically

### Limitations

- **File descriptor usage** - Each watched directory uses one file descriptor
- **Rename detection** - KQueue doesn't provide new names; renames are detected but old→new mapping isn't available
- **Polling interval** - Events are detected within ~1 second (KQueue's polling timeout)

## License

MIT License - Copyright (c) 2026 Marcin Krzyzanowski
