// Simcaster Capture Helper
// Runs as an .app bundle for TCC permissions.
// Writes JPEG frames to /tmp/simcaster_frames/latest.jpg
// Reads JSON commands from /tmp/simcaster_commands.json (poll)

import AppKit
import CommonCrypto
import CoreGraphics
import CoreImage
import CoreMedia
import Foundation
import ScreenCaptureKit

// MARK: - Frame Output

let stderr = FileHandle.standardError
let frameDir = "/tmp/simcaster_frames"
let commandDir = "/tmp/simcaster_cmds"
/// Set from args file at startup; falls back to "latest" for backwards compat
var activeSessionId = "latest"

func log(_ msg: String) {
    let line = "[\(ISO8601DateFormatter().string(from: Date()))] \(msg)\n"
    stderr.write(Data(line.utf8))
    // Also write to log file since stderr may not be visible when launched via `open`
    let logPath = "/tmp/simcaster_capture.log"
    if let handle = FileHandle(forWritingAtPath: logPath) {
        handle.seekToEndOfFile()
        handle.write(Data(line.utf8))
        handle.closeFile()
    } else {
        try? Data(line.utf8).write(to: URL(fileURLWithPath: logPath))
    }
}

func writeFrame(_ jpegData: Data) {
    let path = "\(frameDir)/\(activeSessionId).jpg"
    try? jpegData.write(to: URL(fileURLWithPath: path), options: .atomic)
}

// MARK: - Window Discovery

func findSimulatorWindow(matching name: String?) async throws -> SCWindow? {
    let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
    var candidates: [SCWindow] = []
    for window in content.windows {
        guard let app = window.owningApplication,
              app.bundleIdentifier == "com.apple.iphonesimulator",
              window.frame.width > 100, window.frame.height > 100
        else { continue }
        candidates.append(window)
    }

    if let name, !name.isEmpty {
        if let match = candidates.first(where: { $0.title?.contains(name) == true }) {
            return match
        }
    }
    return candidates.first
}

// MARK: - Capture Stream

/// Fast content fingerprint: hashes the first 4KB, last 4KB, and length.
/// Much cheaper than full SHA256 at 15fps while catching all real frame changes.
private func frameFingerprint(_ data: Data) -> UInt64 {
    var hasher = Hasher()
    hasher.combine(data.count)
    let sampleSize = min(4096, data.count)
    data.prefix(sampleSize).withUnsafeBytes { hasher.combine(bytes: $0) }
    if data.count > sampleSize {
        data.suffix(sampleSize).withUnsafeBytes { hasher.combine(bytes: $0) }
    }
    return UInt64(bitPattern: Int64(hasher.finalize()))
}

class FrameStreamer: NSObject, SCStreamOutput, SCStreamDelegate {
    let ciContext = CIContext()
    let quality: CGFloat
    private let lock = NSLock()
    private var lastFrameHash: UInt64 = 0

    init(quality: CGFloat = 0.65) {
        self.quality = quality
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid else { return }
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        guard let cgImage = ciContext.createCGImage(ciImage, from: ciImage.extent) else { return }

        let bitmapRep = NSBitmapImageRep(cgImage: cgImage)
        guard let jpegData = bitmapRep.representation(using: .jpeg, properties: [.compressionFactor: quality]) else { return }

        // Dedup: hash first 4KB + last 4KB + length for a fast content fingerprint.
        // Full SHA256 is too slow at 15fps; this catches all real changes.
        lock.lock()
        let hash = frameFingerprint(jpegData)
        let isDupe = hash == lastFrameHash
        if !isDupe { lastFrameHash = hash }
        lock.unlock()

        if isDupe { return }

        writeFrame(jpegData)
    }

    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        log("Stream stopped: \(error)")
    }
}

// Keep strong references
var activeStream: SCStream?
var activeStreamer: FrameStreamer?

func startCapture(window: SCWindow, fps: Int = 15) async throws {
    let config = SCStreamConfiguration()
    // Scale down for streaming — half retina is plenty
    config.width = Int(window.frame.width)
    config.height = Int(window.frame.height)
    config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
    config.queueDepth = 3
    config.showsCursor = false
    config.captureResolution = .best

    let filter = SCContentFilter(desktopIndependentWindow: window)
    let streamer = FrameStreamer()
    let stream = SCStream(filter: filter, configuration: config, delegate: streamer)

    activeStream = stream
    activeStreamer = streamer

    let queue = DispatchQueue(label: "com.simcaster.capture", qos: .userInteractive)
    try stream.addStreamOutput(streamer, type: .screen, sampleHandlerQueue: queue)
    try await stream.startCapture()
    log("Capture started for \"\(window.title ?? "unknown")\" at \(fps) fps")
}

// MARK: - Input Injection

func injectTap(nx: Double, ny: Double, windowFrame: CGRect) {
    let screenX = windowFrame.origin.x + nx * windowFrame.width
    let screenY = windowFrame.origin.y + ny * windowFrame.height
    let point = CGPoint(x: screenX, y: screenY)

    if let simApp = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == "com.apple.iphonesimulator" }) {
        simApp.activate()
        usleep(200_000)
    }

    CGWarpMouseCursorPosition(point)
    usleep(50_000)

    let source = CGEventSource(stateID: .hidSystemState)
    guard let mouseDown = CGEvent(mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left),
          let mouseUp = CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left)
    else { return }

    mouseDown.post(tap: .cghidEventTap)
    usleep(80_000)
    mouseUp.post(tap: .cghidEventTap)
    log("Tap at normalized (\(nx), \(ny)) → screen (\(Int(point.x)), \(Int(point.y)))")
}

func injectSwipe(nx1: Double, ny1: Double, nx2: Double, ny2: Double, durationMs: Int, windowFrame: CGRect) {
    let startX = windowFrame.origin.x + nx1 * windowFrame.width
    let startY = windowFrame.origin.y + ny1 * windowFrame.height
    let endX = windowFrame.origin.x + nx2 * windowFrame.width
    let endY = windowFrame.origin.y + ny2 * windowFrame.height
    let start = CGPoint(x: startX, y: startY)
    let end = CGPoint(x: endX, y: endY)

    if let simApp = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == "com.apple.iphonesimulator" }) {
        simApp.activate()
        usleep(200_000)
    }

    CGWarpMouseCursorPosition(start)
    usleep(50_000)

    let source = CGEventSource(stateID: .hidSystemState)
    guard let mouseDown = CGEvent(mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: start, mouseButton: .left) else { return }
    mouseDown.post(tap: .cghidEventTap)

    let steps = max(10, durationMs / 8)
    let stepDelay = UInt32(durationMs * 1000 / steps)
    for i in 1...steps {
        let t = Double(i) / Double(steps)
        let x = startX + t * (endX - startX)
        let y = startY + t * (endY - startY)
        let pt = CGPoint(x: x, y: y)
        CGWarpMouseCursorPosition(pt)
        if let drag = CGEvent(mouseEventSource: source, mouseType: .leftMouseDragged, mouseCursorPosition: pt, mouseButton: .left) {
            drag.post(tap: .cghidEventTap)
        }
        usleep(stepDelay)
    }

    guard let mouseUp = CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: end, mouseButton: .left) else { return }
    mouseUp.post(tap: .cghidEventTap)
    log("Swipe (\(nx1),\(ny1))→(\(nx2),\(ny2)) \(durationMs)ms")
}

func injectPinch(nx: Double, ny: Double, scale: Double, durationMs: Int, windowFrame: CGRect) {
    // Simulator pinch: Option+drag from center outward (zoom in) or inward (zoom out)
    // The Simulator mirrors the cursor around the center when Option is held
    let centerX = windowFrame.origin.x + nx * windowFrame.width
    let centerY = windowFrame.origin.y + ny * windowFrame.height

    // Start near center, drag outward based on scale
    // scale > 1 = zoom in (drag outward), scale < 1 = zoom out (drag inward)
    let radius = 30.0  // starting distance from center in points
    let endRadius = radius * scale

    let startPt = CGPoint(x: centerX, y: centerY - radius)
    let endPt = CGPoint(x: centerX, y: centerY - endRadius)

    if let simApp = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == "com.apple.iphonesimulator" }) {
        simApp.activate()
        usleep(200_000)
    }

    CGWarpMouseCursorPosition(startPt)
    usleep(50_000)

    let source = CGEventSource(stateID: .hidSystemState)

    // Press Option key
    guard let optDown = CGEvent(keyboardEventSource: source, virtualKey: 0x3A, keyDown: true) else { return }
    optDown.flags = .maskAlternate
    optDown.post(tap: .cghidEventTap)
    usleep(50_000)

    // Mouse down with Option held
    guard let mouseDown = CGEvent(mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: startPt, mouseButton: .left) else { return }
    mouseDown.flags = .maskAlternate
    mouseDown.post(tap: .cghidEventTap)

    // Drag
    let steps = max(10, durationMs / 8)
    let stepDelay = UInt32(durationMs * 1000 / steps)
    for i in 1...steps {
        let t = Double(i) / Double(steps)
        let y = startPt.y + t * (endPt.y - startPt.y)
        let pt = CGPoint(x: centerX, y: y)
        CGWarpMouseCursorPosition(pt)
        if let drag = CGEvent(mouseEventSource: source, mouseType: .leftMouseDragged, mouseCursorPosition: pt, mouseButton: .left) {
            drag.flags = .maskAlternate
            drag.post(tap: .cghidEventTap)
        }
        usleep(stepDelay)
    }

    // Mouse up
    guard let mouseUp = CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: endPt, mouseButton: .left) else { return }
    mouseUp.flags = .maskAlternate
    mouseUp.post(tap: .cghidEventTap)
    usleep(50_000)

    // Release Option key
    guard let optUp = CGEvent(keyboardEventSource: source, virtualKey: 0x3A, keyDown: false) else { return }
    optUp.post(tap: .cghidEventTap)

    log("Pinch at (\(nx),\(ny)) scale=\(String(format: "%.2f", scale)) \(durationMs)ms")
}

// Mac virtual keycode lookup
let charToKeyCode: [Character: (UInt16, Bool)] = [
    "a": (0x00, false), "b": (0x0B, false), "c": (0x08, false), "d": (0x02, false),
    "e": (0x0E, false), "f": (0x03, false), "g": (0x05, false), "h": (0x04, false),
    "i": (0x22, false), "j": (0x26, false), "k": (0x28, false), "l": (0x25, false),
    "m": (0x2E, false), "n": (0x2D, false), "o": (0x1F, false), "p": (0x23, false),
    "q": (0x0C, false), "r": (0x0F, false), "s": (0x01, false), "t": (0x11, false),
    "u": (0x20, false), "v": (0x09, false), "w": (0x0D, false), "x": (0x07, false),
    "y": (0x10, false), "z": (0x06, false),
    "A": (0x00, true), "B": (0x0B, true), "C": (0x08, true), "D": (0x02, true),
    "E": (0x0E, true), "F": (0x03, true), "G": (0x05, true), "H": (0x04, true),
    "I": (0x22, true), "J": (0x26, true), "K": (0x28, true), "L": (0x25, true),
    "M": (0x2E, true), "N": (0x2D, true), "O": (0x1F, true), "P": (0x23, true),
    "Q": (0x0C, true), "R": (0x0F, true), "S": (0x01, true), "T": (0x11, true),
    "U": (0x20, true), "V": (0x09, true), "W": (0x0D, true), "X": (0x07, true),
    "Y": (0x10, true), "Z": (0x06, true),
    "0": (0x1D, false), "1": (0x12, false), "2": (0x13, false), "3": (0x14, false),
    "4": (0x15, false), "5": (0x17, false), "6": (0x16, false), "7": (0x1A, false),
    "8": (0x1C, false), "9": (0x19, false),
    " ": (0x31, false), ".": (0x2F, false), ",": (0x2B, false), "/": (0x2C, false),
    ";": (0x29, false), "'": (0x27, false), "-": (0x1B, false), "=": (0x18, false),
    "[": (0x21, false), "]": (0x1E, false), "\\": (0x2A, false), "`": (0x32, false),
    "!": (0x12, true), "@": (0x13, true), "#": (0x14, true), "$": (0x15, true),
    "%": (0x17, true), "^": (0x16, true), "&": (0x1A, true), "*": (0x1C, true),
    "(": (0x19, true), ")": (0x1D, true), "_": (0x1B, true), "+": (0x18, true),
    "{": (0x21, true), "}": (0x1E, true), "|": (0x2A, true), "~": (0x32, true),
    ":": (0x29, true), "\"": (0x27, true), "<": (0x2B, true), ">": (0x2F, true),
    "?": (0x2C, true),
]

func injectKeys(chars: String) {
    if let simApp = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == "com.apple.iphonesimulator" }) {
        simApp.activate()
        usleep(100_000)
    }

    let source = CGEventSource(stateID: .hidSystemState)
    for char in chars {
        guard let (keyCode, shift) = charToKeyCode[char] else {
            log("No keycode for: \(char)")
            continue
        }
        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        else { continue }
        if shift {
            keyDown.flags = .maskShift
            keyUp.flags = .maskShift
        }
        keyDown.post(tap: .cghidEventTap)
        usleep(30_000)
        keyUp.post(tap: .cghidEventTap)
        usleep(50_000)
    }
    log("Keys injected: \"\(chars)\"")
}

func injectBackspace(count: Int) {
    if let simApp = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == "com.apple.iphonesimulator" }) {
        simApp.activate()
        usleep(100_000)
    }

    let source = CGEventSource(stateID: .hidSystemState)
    for _ in 0..<count {
        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x33, keyDown: true),  // Delete/Backspace
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0x33, keyDown: false)
        else { continue }
        keyDown.post(tap: .cghidEventTap)
        usleep(20_000)
        keyUp.post(tap: .cghidEventTap)
        usleep(30_000)
    }
    log("Backspace x\(count)")
}

func injectEnter() {
    if let simApp = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == "com.apple.iphonesimulator" }) {
        simApp.activate()
        usleep(100_000)
    }

    let source = CGEventSource(stateID: .hidSystemState)
    guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x24, keyDown: true),  // Return
          let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0x24, keyDown: false)
    else { return }
    keyDown.post(tap: .cghidEventTap)
    usleep(20_000)
    keyUp.post(tap: .cghidEventTap)
    log("Enter injected")
}

func injectType(text: String) {
    // Set the Mac host pasteboard
    let pb = NSPasteboard.general
    pb.clearContents()
    pb.setString(text, forType: .string)

    // Activate Simulator and Cmd+V to paste from host clipboard
    if let simApp = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == "com.apple.iphonesimulator" }) {
        simApp.activate()
        usleep(300_000)
    }

    let source = CGEventSource(stateID: .hidSystemState)
    guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true),
          let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false)
    else { return }
    keyDown.flags = .maskCommand
    keyUp.flags = .maskCommand
    keyDown.post(tap: .cghidEventTap)
    usleep(50_000)
    keyUp.post(tap: .cghidEventTap)
    log("Type injected: \"\(text)\" (pbcopy + Cmd+V)")
}

func injectPaste() {
    if let simApp = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == "com.apple.iphonesimulator" }) {
        simApp.activate()
        usleep(200_000)
    }

    let source = CGEventSource(stateID: .hidSystemState)
    // Cmd+V
    guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true),  // V key
          let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false)
    else { return }
    keyDown.flags = .maskCommand
    keyUp.flags = .maskCommand
    keyDown.post(tap: .cghidEventTap)
    usleep(50_000)
    keyUp.post(tap: .cghidEventTap)
    log("Paste injected (Cmd+V)")
}

func injectButton(_ button: String) {
    if let simApp = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == "com.apple.iphonesimulator" }) {
        simApp.activate()
        usleep(200_000)
    }

    let source = CGEventSource(stateID: .hidSystemState)
    let keyCode: UInt16
    var flags: CGEventFlags

    switch button {
    case "home":
        keyCode = 0x04  // H
        flags = [.maskCommand, .maskShift]
    case "lock":
        keyCode = 0x25  // L
        flags = [.maskCommand]
    case "shake":
        keyCode = 0x06  // Z
        flags = [.maskCommand, .maskControl]
    default:
        log("Unknown button: \(button)")
        return
    }

    guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
          let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
    else { return }
    keyDown.flags = flags
    keyUp.flags = flags
    keyDown.post(tap: .cghidEventTap)
    usleep(50_000)
    keyUp.post(tap: .cghidEventTap)
    log("Button injected: \(button)")
}

// MARK: - Window Frame Tracker

/// Periodically re-queries the Simulator window frame so that touch
/// coordinates stay accurate after the window is moved or resized.
class WindowFrameTracker {
    private let lock = NSLock()
    private var _frame: CGRect
    private let deviceName: String?

    init(frame: CGRect, deviceName: String?) {
        self._frame = frame
        self.deviceName = deviceName
        startPolling()
    }

    var frame: CGRect {
        lock.lock()
        defer { lock.unlock() }
        return _frame
    }

    func update(frame: CGRect) {
        lock.lock()
        _frame = frame
        lock.unlock()
    }

    private func startPolling() {
        let name = deviceName
        let tracker = self
        Task.detached {
            while true {
                try? await Task.sleep(for: .seconds(2))
                if let window = try? await findSimulatorWindow(matching: name) {
                    tracker.update(frame: window.frame)
                }
            }
        }
    }
}

// MARK: - Command Reader (file-based)

struct InputCommand: Codable {
    var type: String // "tap", "swipe", "type", "paste", "shake", "stop"
    var x: Double?
    var y: Double?
    var x2: Double?
    var y2: Double?
    var duration: Int?  // ms, for swipe
    var text: String?   // for type command
    var chars: String?  // for keys command
    var count: Int?     // for backspace command
    var scale: Double?  // for pinch command
}

func readCommands(frameTracker: WindowFrameTracker) {
    log("Command reader started (polling \(commandDir)), accessibility: \(AXIsProcessTrusted())")
    try? FileManager.default.createDirectory(atPath: commandDir, withIntermediateDirectories: true)
    DispatchQueue.global(qos: .userInitiated).async {
        while true {
            usleep(30_000) // 30ms poll

            guard let files = try? FileManager.default.contentsOfDirectory(atPath: commandDir)
                .filter({ $0.hasSuffix(".cmd") })
                .sorted()
            else { continue }
            if files.isEmpty { continue }

            for file in files {
                let path = "\(commandDir)/\(file)"
                guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)), !data.isEmpty else {
                    try? FileManager.default.removeItem(atPath: path)
                    continue
                }
                try? FileManager.default.removeItem(atPath: path)

                guard let text = String(data: data, encoding: .utf8) else { continue }
                log("Command received: \(text.trimmingCharacters(in: .whitespacesAndNewlines))")

                // Read current frame for each batch — tracks window moves/resizes
                let windowFrame = frameTracker.frame

                for jsonLine in text.split(separator: "\n") {
                    guard let jsonData = jsonLine.data(using: .utf8),
                          let cmd = try? JSONDecoder().decode(InputCommand.self, from: jsonData)
                    else {
                        log("Failed to parse command: \(jsonLine)")
                        continue
                    }

                    switch cmd.type {
                    case "tap":
                        if let x = cmd.x, let y = cmd.y {
                            injectTap(nx: x, ny: y, windowFrame: windowFrame)
                        }
                    case "swipe":
                        if let x1 = cmd.x, let y1 = cmd.y, let x2 = cmd.x2, let y2 = cmd.y2 {
                            injectSwipe(nx1: x1, ny1: y1, nx2: x2, ny2: y2, durationMs: cmd.duration ?? 300, windowFrame: windowFrame)
                        }
                    case "type":
                        if let text = cmd.text {
                            injectType(text: text)
                        }
                    case "keys":
                        if let chars = cmd.chars {
                            injectKeys(chars: chars)
                        }
                    case "backspace":
                        injectBackspace(count: cmd.count ?? 1)
                    case "enter":
                        injectEnter()
                    case "pinch":
                        if let x = cmd.x, let y = cmd.y, let scale = cmd.scale {
                            injectPinch(nx: x, ny: y, scale: scale, durationMs: cmd.duration ?? 300, windowFrame: windowFrame)
                        }
                    case "paste":
                        injectPaste()
                    case "button":
                        if let btn = cmd.text {
                            injectButton(btn)
                        }
                    case "stop":
                        log("Stop command received")
                        exit(0)
                    default:
                        log("Unknown command: \(cmd.type)")
                    }
                }
            }
        }
    }
}

// MARK: - Main

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        var deviceName: String? = nil
        let argsFile = "/tmp/simcaster_capture_args.json"
        if let data = FileManager.default.contents(atPath: argsFile),
           let args = try? JSONSerialization.jsonObject(with: data) as? [String: String] {
            deviceName = args["deviceName"]
            if let sid = args["sessionId"] { activeSessionId = sid }
            try? FileManager.default.removeItem(atPath: argsFile)
        }

        Task {
            do {
                // Ensure frame output directory exists
                try FileManager.default.createDirectory(atPath: frameDir, withIntermediateDirectories: true)

                // Trigger TCC prompt for screen capture by enumerating content first
                log("Checking screen capture permission...")
                _ = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                log("Permission OK")

                guard let window = try await findSimulatorWindow(matching: deviceName) else {
                    log("ERROR: No simulator window found")
                    exit(1)
                }
                log("Found window: \"\(window.title ?? "")\" \(Int(window.frame.width))x\(Int(window.frame.height))")

                let tracker = WindowFrameTracker(frame: window.frame, deviceName: deviceName)
                readCommands(frameTracker: tracker)
                try await startCapture(window: window)

                // Keep alive — frames are written by the stream callback
            } catch {
                log("ERROR: \(error)")
                // Don't exit immediately — give time for TCC prompt to show
                log("If you see a permission prompt, grant it and relaunch.")
                try? await Task.sleep(for: .seconds(30))
                exit(1)
            }
        }
    }
}

let delegate = AppDelegate()
let app = NSApplication.shared
app.delegate = delegate
app.run()
