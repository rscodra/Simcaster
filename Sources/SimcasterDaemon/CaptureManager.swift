import Foundation

/// Manages the lifecycle of the CaptureHelper process.
///
/// Uses NSLock for synchronization — all mutable state (`_running`,
/// `_restarting`) is accessed exclusively through lock-protected sections.
final class CaptureManager: @unchecked Sendable {
    private let lock = NSLock()
    private var _running: [String: Bool] = [:]
    private var _restarting: [String: Bool] = [:]

    let frameDir = "/tmp/simcaster_frames"

    let helperAppPath: String

    init() {
        let daemonPath = CommandLine.arguments[0]
        let daemonDir = (daemonPath as NSString).deletingLastPathComponent
        let candidates = [
            (daemonDir as NSString).appendingPathComponent("../../Spike/CaptureSpike.app"),
            (daemonDir as NSString).appendingPathComponent("../../../Spike/CaptureSpike.app"),
            NSString(string: FileManager.default.currentDirectoryPath).appendingPathComponent("Spike/CaptureSpike.app"),
        ]
        let raw = candidates.first(where: { FileManager.default.fileExists(atPath: $0) }) ?? candidates.last!
        helperAppPath = URL(fileURLWithPath: raw).standardized.path

        // Clean stale files from previous daemon runs
        cleanStaleFiles()
    }

    /// Remove leftover frame files, command files, and logs from prior runs.
    private func cleanStaleFiles() {
        let fm = FileManager.default
        // Frame files
        if let files = try? fm.contentsOfDirectory(atPath: frameDir) {
            for file in files where file.hasSuffix(".jpg") {
                try? fm.removeItem(atPath: "\(frameDir)/\(file)")
            }
        }
        // Command files
        let cmdDir = "/tmp/simcaster_cmds"
        if let files = try? fm.contentsOfDirectory(atPath: cmdDir) {
            for file in files where file.hasSuffix(".cmd") {
                try? fm.removeItem(atPath: "\(cmdDir)/\(file)")
            }
        }
        // Stale args/log
        try? fm.removeItem(atPath: "/tmp/simcaster_capture_args.json")
        try? fm.removeItem(atPath: "/tmp/simcaster_capture.log")
    }

    /// Path to the frame file for a given session.
    func framePath(for sessionId: String) -> String {
        "\(frameDir)/\(sessionId).jpg"
    }

    func getFrame(_ sessionId: String) -> Data? {
        return try? Data(contentsOf: URL(fileURLWithPath: framePath(for: sessionId)))
    }

    func startCapture(sessionId: String, deviceName: String) throws {
        lock.lock()
        if _running[sessionId] == true {
            lock.unlock()
            return
        }
        _running[sessionId] = true
        lock.unlock()

        try FileManager.default.createDirectory(atPath: frameDir, withIntermediateDirectories: true)

        // Clean stale frame for this session
        try? FileManager.default.removeItem(atPath: framePath(for: sessionId))
        try? FileManager.default.removeItem(atPath: "/tmp/simcaster_capture.log")

        // Write args file for the helper — includes sessionId for per-session frame path
        let args: [String: String] = ["deviceName": deviceName, "sessionId": sessionId]
        let argsData = try JSONSerialization.data(withJSONObject: args)
        try argsData.write(to: URL(fileURLWithPath: "/tmp/simcaster_capture_args.json"))

        print("[\(sessionId)] Launching capture helper: \(helperAppPath)")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-a", helperAppPath, "--args", "--launched-by-daemon"]
        try process.run()
        process.waitUntilExit()

        if process.terminationStatus != 0 {
            print("[\(sessionId)] Warning: open command exited with status \(process.terminationStatus)")
        }

        print("[\(sessionId)] open command completed, waiting for capture helper to start...")

        let fp = framePath(for: sessionId)
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: fp) {
                print("[\(sessionId)] Capture helper is producing frames")
                break
            }
            usleep(200_000)
        }

        startHealthMonitor(sessionId: sessionId, deviceName: deviceName)
    }

    func stopCapture(sessionId: String) {
        lock.lock()
        _running.removeValue(forKey: sessionId)
        lock.unlock()

        sendCommand(sessionId: sessionId, command: Data("{\"type\":\"stop\"}".utf8))

        let killProc = Process()
        killProc.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        killProc.arguments = ["-f", "CaptureSpike"]
        try? killProc.run()

        // Clean up frame file
        try? FileManager.default.removeItem(atPath: framePath(for: sessionId))

        print("[\(sessionId)] Capture stopped")
    }

    func sendCommand(sessionId: String, command: Data) {
        let cmdDir = "/tmp/simcaster_cmds"
        try? FileManager.default.createDirectory(atPath: cmdDir, withIntermediateDirectories: true)
        var cmdData = command
        cmdData.append(Data("\n".utf8))
        let filename = "\(cmdDir)/\(UInt64(Date().timeIntervalSince1970 * 1_000_000))_\(arc4random()).cmd"
        try? cmdData.write(to: URL(fileURLWithPath: filename), options: .atomic)
    }

    // MARK: - Health Monitor

    private func startHealthMonitor(sessionId: String, deviceName: String) {
        let fp = framePath(for: sessionId)

        DispatchQueue.global(qos: .utility).async { [self] in
            var lastMod: Date? = nil
            while true {
                sleep(5)

                lock.lock()
                let active = _running[sessionId] == true
                let alreadyRestarting = _restarting[sessionId] == true
                lock.unlock()

                if !active { return }
                if alreadyRestarting { continue }

                if let attrs = try? FileManager.default.attributesOfItem(atPath: fp),
                   let mod = attrs[.modificationDate] as? Date {
                    if let prev = lastMod, mod == prev {
                        print("[\(sessionId)] Capture helper appears stale, restarting...")
                        restart(sessionId: sessionId, deviceName: deviceName)
                        return
                    }
                    lastMod = mod
                } else {
                    print("[\(sessionId)] No frame file found, restarting capture helper...")
                    restart(sessionId: sessionId, deviceName: deviceName)
                    return
                }
            }
        }
    }

    private func restart(sessionId: String, deviceName: String) {
        lock.lock()
        if _restarting[sessionId] == true {
            lock.unlock()
            return
        }
        _restarting[sessionId] = true
        _running.removeValue(forKey: sessionId)
        lock.unlock()

        defer {
            lock.lock()
            _restarting.removeValue(forKey: sessionId)
            lock.unlock()
        }

        try? startCapture(sessionId: sessionId, deviceName: deviceName)
    }
}
