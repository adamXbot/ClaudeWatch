import Foundation
import CoreServices

/// Tells a `TranscriptStore` which files changed, so it never has to go looking.
public protocol TranscriptWatching: AnyObject {
    /// Begin reporting changes under `directories`, on `queue`. `onChange` gets the paths
    /// that changed, or nil when the watcher lost track and the caller should list the
    /// directories again. Returns false if watching is unavailable (the caller then polls).
    func start(directories: [URL], queue: DispatchQueue, onChange: @escaping ([String]?) -> Void) -> Bool
    func stop()
}

/// File-level FSEvents: the kernel reports each transcript that is written, so an idle
/// history costs nothing and a busy one costs a `stat` per changed file.
public final class FSEventsWatcher: TranscriptWatching {

    private var stream: FSEventStreamRef?
    private var onChange: (([String]?) -> Void)?
    private let latency: TimeInterval

    /// Changes arriving within `latency` of each other are delivered together; the first
    /// one after a quiet spell is delivered at once.
    public init(latency: TimeInterval = 1.0) {
        self.latency = latency
    }

    deinit { stop() }

    public func start(directories: [URL], queue: DispatchQueue, onChange: @escaping ([String]?) -> Void) -> Bool {
        stop()
        self.onChange = onChange

        var context = FSEventStreamContext(
            version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
            guard let info else { return }
            let watcher = Unmanaged<FSEventsWatcher>.fromOpaque(info).takeUnretainedValue()
            let paths = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
            watcher.deliver(paths: paths, flags: UnsafeBufferPointer(start: flags, count: count))
        }
        let flags = kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes
            | kFSEventStreamCreateFlagWatchRoot | kFSEventStreamCreateFlagNoDefer
        guard let stream = FSEventStreamCreate(
            nil, callback, &context,
            directories.map { EventScanner.realPath($0.path) } as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            latency, FSEventStreamCreateFlags(flags)
        ) else { return false }

        FSEventStreamSetDispatchQueue(stream, queue)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            return false
        }
        self.stream = stream
        return true
    }

    public func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
        onChange = nil
    }

    private func deliver(paths: [String], flags: UnsafeBufferPointer<FSEventStreamEventFlags>) {
        // Events were dropped, a watched directory itself moved, or a whole folder was
        // renamed or removed (its files get no events of their own): only a fresh listing
        // can say what is there now.
        let lostTrack = kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped
            | kFSEventStreamEventFlagKernelDropped | kFSEventStreamEventFlagRootChanged
            | kFSEventStreamEventFlagMount | kFSEventStreamEventFlagUnmount
        let folderMoved = kFSEventStreamEventFlagItemRenamed | kFSEventStreamEventFlagItemRemoved

        var changed: [String] = []
        for (path, flag) in zip(paths, flags) {
            let flag = Int(flag)
            if flag & lostTrack != 0
                || (flag & kFSEventStreamEventFlagItemIsDir != 0 && flag & folderMoved != 0) {
                onChange?(nil)
                return
            }
            changed.append(path)
        }
        if !changed.isEmpty { onChange?(changed) }
    }
}
