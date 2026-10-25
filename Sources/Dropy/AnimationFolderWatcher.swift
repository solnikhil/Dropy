import CoreServices
import Foundation

/// A main-queue FSEvents registration. The stream retains its callback context;
/// the cleanup owner stops, invalidates and releases the stream before that context
/// can go away. Neither the context nor a queued event needs a raw library pointer.
@MainActor
final class AnimationFolderWatcher {
    private final class Callback {
        let changed: @MainActor @Sendable () -> Void
        init(_ changed: @escaping @MainActor @Sendable () -> Void) { self.changed = changed }
    }

    private let cleanup: MainThreadCleanup

    init?(folder: URL, changed: @escaping @MainActor @Sendable () -> Void) {
        let callback = Callback(changed)
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(callback).toOpaque(),
            retain: { pointer in
                guard let pointer else { return nil }
                return UnsafeRawPointer(Unmanaged<Callback>.fromOpaque(pointer).retain().toOpaque())
            }, release: { pointer in
                if let pointer { Unmanaged<Callback>.fromOpaque(pointer).release() }
            }, copyDescription: nil)
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer)
        let stream = withExtendedLifetime(callback) {
            FSEventStreamCreate(nil, { _, info, _, _, _, _ in
                guard let info else { return }
                MainActor.assumeIsolated {
                    Unmanaged<Callback>.fromOpaque(info).takeUnretainedValue().changed()
                }
            }, &context, [folder.path] as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.1, flags)
        }
        guard let stream else { return nil }
        FSEventStreamSetDispatchQueue(stream, .main)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            return nil
        }
        cleanup = MainThreadCleanup {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
    }
}
