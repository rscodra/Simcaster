import Foundation

/// Watches a frame file for changes using a GCD directory watcher.
///
/// Atomic writes (write-to-temp → rename) invalidate per-file kqueue
/// descriptors, so we watch the parent directory instead. The directory
/// receives a write event on every rename/create inside it.
final class FrameWatcher: @unchecked Sendable {
    private let path: String
    private let dirPath: String
    private var source: DispatchSourceFileSystemObject?
    private var fileDescriptor: Int32 = -1

    init(path: String) {
        self.path = path
        self.dirPath = (path as NSString).deletingLastPathComponent
    }

    deinit {
        stop()
    }

    func frames() -> AsyncStream<Data> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            var lastSize: Int = 0
            let queue = DispatchQueue(label: "com.simview.framewatcher")
            let fileName = (self.path as NSString).lastPathComponent

            let startWatching: () -> Void = { [self] in
                fileDescriptor = open(dirPath, O_EVTONLY)
                guard fileDescriptor >= 0 else {
                    continuation.finish()
                    return
                }

                let src = DispatchSource.makeFileSystemObjectSource(
                    fileDescriptor: fileDescriptor,
                    eventMask: .write,
                    queue: queue
                )

                src.setEventHandler {
                    // Read the frame directly — skip stat syscall
                    guard let data = try? Data(contentsOf: URL(fileURLWithPath: self.path)),
                          !data.isEmpty,
                          data.count != lastSize
                    else { return }
                    lastSize = data.count

                    continuation.yield(data)
                }

                src.setCancelHandler { [self] in
                    if fileDescriptor >= 0 {
                        close(fileDescriptor)
                        fileDescriptor = -1
                    }
                }

                source = src
                src.resume()
            }

            continuation.onTermination = { [weak self] _ in
                self?.stop()
            }

            DispatchQueue.global(qos: .userInitiated).async {
                startWatching()
            }
        }
    }

    func stop() {
        source?.cancel()
        source = nil
    }
}
