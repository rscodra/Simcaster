import Dispatch
import Foundation
import Hummingbird
import HummingbirdWebSocket
import SimcasterCore

// MARK: - Config

let daemonHost = ProcessInfo.processInfo.environment["SIMCASTER_HOST"] ?? "0.0.0.0"
let daemonPort = Int(ProcessInfo.processInfo.environment["SIMCASTER_PORT"] ?? "4821") ?? 4821
let lanIP = getLanIP() ?? "127.0.0.1"

let effectiveToken: String = {
    if let t = ProcessInfo.processInfo.environment["SIMCASTER_TOKEN"], !t.isEmpty {
        return t
    }
    // Fall back to token file
    let tokenPath = NSHomeDirectory() + "/.simcaster/token"
    if let fileToken = try? String(contentsOfFile: tokenPath, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), !fileToken.isEmpty {
        return fileToken
    }
    return String(UUID().uuidString.prefix(12)).lowercased()
}()

let sessionStore = SessionStore()
let captureManager = CaptureManager()

// MARK: - Router

let router = Router(context: BasicWebSocketRequestContext.self)
router.middlewares.add(AuthMiddleware(token: effectiveToken, sessionStore: sessionStore))

// MARK: - Health & Devices

router.get("api/health") { _, _ in
    jsonResponse(HealthResponse(ok: true, daemonRunning: true))
}

router.get("api/devices") { _, _ in
    do {
        let result = try listDevices()
        return jsonResponse(DevicesResponse(ok: true, devices: result.devices))
    } catch {
        return jsonResponse(ErrorResponse(errorCode: "SIMCTL_FAILED", message: "\(error)"), status: .internalServerError)
    }
}

router.post("api/boot") { request, _ in
    let body = try await request.body.collect(upTo: 1024 * 16)
    let bootReq = try JSONDecoder().decode(BootRequest.self, from: body)
    let udid = bootReq.udid

    let result = try listDevices()
    guard let device = result.devices.first(where: { $0.udid == udid }) else {
        return jsonResponse(
            ErrorResponse(errorCode: "DEVICE_NOT_FOUND", message: "No device with UDID \(udid)"),
            status: .notFound
        )
    }

    if device.state == "Booted" {
        return jsonResponse(BootResponse(ok: true, udid: udid, name: device.name, state: "Booted", message: "Already booted"))
    }

    do {
        let bootResult = try runSimctl(["boot", udid])
        if bootResult.status != 0 {
            let stderr = String(data: bootResult.stderr, encoding: .utf8) ?? "unknown error"
            return jsonResponse(
                BootResponse(ok: false, udid: udid, name: device.name, state: device.state, message: stderr, errorCode: "BOOT_FAILED"),
                status: .internalServerError
            )
        }
    } catch {
        return jsonResponse(
            ErrorResponse(errorCode: "BOOT_FAILED", message: "\(error)"),
            status: .internalServerError
        )
    }

    let deadline = Date().addingTimeInterval(30)
    var finalState = "Booting"
    while Date() < deadline {
        try? await Task.sleep(for: .seconds(1))
        if let updated = try? listDevices().devices.first(where: { $0.udid == udid }), updated.state == "Booted" {
            finalState = "Booted"
            break
        }
    }

    return jsonResponse(BootResponse(ok: true, udid: udid, name: device.name, state: finalState))
}

// MARK: - Sessions

struct CreateSessionRequest: Codable {
    var udid: String
    var bundleId: String?
}

struct CreateSessionResponse: Codable {
    var ok: Bool
    var session: Session?
    var errorCode: String?
    var message: String?
}

router.get("api/sessions") { _, _ in
    jsonResponse(SessionsResponse(ok: true, sessions: sessionStore.sessions))
}

router.post("api/sessions") { request, _ in
    let body = try await request.body.collect(upTo: 1024 * 16)
    let req = try JSONDecoder().decode(CreateSessionRequest.self, from: body)

    let result = try listDevices()
    guard let device = result.devices.first(where: { $0.udid == req.udid }) else {
        return jsonResponse(
            CreateSessionResponse(ok: false, errorCode: "DEVICE_NOT_FOUND", message: "No device with UDID \(req.udid)"),
            status: .notFound
        )
    }
    guard device.state == "Booted" else {
        return jsonResponse(
            CreateSessionResponse(ok: false, errorCode: "DEVICE_NOT_BOOTED", message: "\(device.name) is \(device.state), not Booted"),
            status: .badRequest
        )
    }

    if let existing = sessionStore.sessions.first(where: { $0.udid == req.udid && $0.state != "stopped" }) {
        return jsonResponse(CreateSessionResponse(ok: true, session: existing, message: "Reusing existing session"))
    }

    let sessionId = "sess_\(UUID().uuidString.prefix(8).lowercased())"
    let viewerToken = "vt_\(UUID().uuidString.prefix(16).lowercased())"
    let formatter = ISO8601DateFormatter()
    var session = Session(
        id: sessionId,
        udid: req.udid,
        deviceName: device.name,
        bundleId: req.bundleId,
        state: "created",
        viewerUrl: "http://\(lanIP):\(daemonPort)/sessions/\(sessionId)?token=\(viewerToken)",
        viewerToken: viewerToken,
        createdAt: formatter.string(from: Date())
    )

    do {
        try captureManager.startCapture(sessionId: sessionId, deviceName: device.name)
        session.state = "streaming"
    } catch {
        session.state = "created"
        session.lastError = "Capture start failed: \(error)"
    }

    sessionStore.add(session)
    return jsonResponse(CreateSessionResponse(ok: true, session: session))
}

router.get("api/sessions/:id") { _, context in
    let id = context.parameters.get("id") ?? ""
    guard let session = sessionStore.get(id) else {
        return jsonResponse(ErrorResponse(errorCode: "SESSION_NOT_FOUND", message: "No session \(id)"), status: .notFound)
    }
    return jsonResponse(CreateSessionResponse(ok: true, session: session))
}

router.post("api/sessions/:id/stop") { _, context in
    let id = context.parameters.get("id") ?? ""
    guard sessionStore.get(id) != nil else {
        return jsonResponse(ErrorResponse(errorCode: "SESSION_NOT_FOUND", message: "No session \(id)"), status: .notFound)
    }
    captureManager.stopCapture(sessionId: id)
    sessionStore.update(id) { $0.state = "stopped" }
    return jsonResponse(CreateSessionResponse(ok: true, session: sessionStore.get(id)))
}

// MARK: - Frame

router.get("api/sessions/:id/frame") { _, context in
    let id = context.parameters.get("id") ?? ""
    guard sessionStore.get(id) != nil else {
        return Response(status: .notFound)
    }
    guard let frame = captureManager.getFrame(id) else {
        return Response(status: .noContent)
    }
    return Response(
        status: .ok,
        headers: [
            .contentType: "image/jpeg",
            .cacheControl: "no-cache, no-store",
        ],
        body: .init(byteBuffer: ByteBuffer(data: frame))
    )
}

// MARK: - Input

struct TapRequest: Codable {
    var x: Double
    var y: Double
}

struct SwipeRequest: Codable {
    var x1: Double
    var y1: Double
    var x2: Double
    var y2: Double
    var duration: Int?
}

struct ButtonRequest: Codable {
    var button: String
}

struct TypeRequest: Codable {
    var text: String
}

struct PinchRequest: Codable {
    var x: Double
    var y: Double
    var scale: Double
    var duration: Int?
}

struct KeyRequest: Codable {
    var chars: String?
    var backspaces: Int?
    var enter: Bool?
}

router.post("api/sessions/:id/tap") { request, context in
    let id = context.parameters.get("id") ?? ""
    guard sessionStore.get(id) != nil else {
        return jsonResponse(ErrorResponse(errorCode: "SESSION_NOT_FOUND", message: "No session \(id)"), status: .notFound)
    }
    let body = try await request.body.collect(upTo: 1024)
    let tap = try JSONDecoder().decode(TapRequest.self, from: body)
    let cmdStr = "{\"type\":\"tap\",\"x\":\(tap.x),\"y\":\(tap.y)}"
    captureManager.sendCommand(sessionId: id, command: Data(cmdStr.utf8))
    return jsonResponse(["ok": true])
}

router.post("api/sessions/:id/swipe") { request, context in
    let id = context.parameters.get("id") ?? ""
    guard sessionStore.get(id) != nil else {
        return jsonResponse(ErrorResponse(errorCode: "SESSION_NOT_FOUND", message: "No session \(id)"), status: .notFound)
    }
    let body = try await request.body.collect(upTo: 1024)
    let swipe = try JSONDecoder().decode(SwipeRequest.self, from: body)
    let dur = swipe.duration ?? 300
    let cmdStr = "{\"type\":\"swipe\",\"x\":\(swipe.x1),\"y\":\(swipe.y1),\"x2\":\(swipe.x2),\"y2\":\(swipe.y2),\"duration\":\(dur)}"
    captureManager.sendCommand(sessionId: id, command: Data(cmdStr.utf8))
    return jsonResponse(["ok": true])
}

router.post("api/sessions/:id/button") { request, context in
    let id = context.parameters.get("id") ?? ""
    guard sessionStore.get(id) != nil else {
        return jsonResponse(ErrorResponse(errorCode: "SESSION_NOT_FOUND", message: "No session \(id)"), status: .notFound)
    }
    let body = try await request.body.collect(upTo: 1024)
    let req = try JSONDecoder().decode(ButtonRequest.self, from: body)

    let validButtons = ["home", "lock", "shake"]
    guard validButtons.contains(req.button) else {
        return jsonResponse(ErrorResponse(errorCode: "UNKNOWN_BUTTON", message: "Unknown button: \(req.button)"), status: .badRequest)
    }
    let cmdStr = "{\"type\":\"button\",\"text\":\"\(req.button)\"}"
    captureManager.sendCommand(sessionId: id, command: Data(cmdStr.utf8))
    return jsonResponse(["ok": true])
}

router.post("api/sessions/:id/type") { request, context in
    let id = context.parameters.get("id") ?? ""
    guard sessionStore.get(id) != nil else {
        return jsonResponse(ErrorResponse(errorCode: "SESSION_NOT_FOUND", message: "No session \(id)"), status: .notFound)
    }
    let body = try await request.body.collect(upTo: 1024 * 16)
    let req = try JSONDecoder().decode(TypeRequest.self, from: body)

    struct TypeCommand: Codable { var type = "type"; var text: String }
    let cmd = TypeCommand(text: req.text)
    let cmdData = try JSONEncoder().encode(cmd)
    captureManager.sendCommand(sessionId: id, command: cmdData)
    return jsonResponse(["ok": true])
}

router.post("api/sessions/:id/pinch") { request, context in
    let id = context.parameters.get("id") ?? ""
    guard sessionStore.get(id) != nil else {
        return jsonResponse(ErrorResponse(errorCode: "SESSION_NOT_FOUND", message: "No session \(id)"), status: .notFound)
    }
    let body = try await request.body.collect(upTo: 1024)
    let pinch = try JSONDecoder().decode(PinchRequest.self, from: body)
    let dur = pinch.duration ?? 300
    let cmdStr = "{\"type\":\"pinch\",\"x\":\(pinch.x),\"y\":\(pinch.y),\"scale\":\(pinch.scale),\"duration\":\(dur)}"
    captureManager.sendCommand(sessionId: id, command: Data(cmdStr.utf8))
    return jsonResponse(["ok": true])
}

router.post("api/sessions/:id/key") { request, context in
    let id = context.parameters.get("id") ?? ""
    guard sessionStore.get(id) != nil else {
        return jsonResponse(ErrorResponse(errorCode: "SESSION_NOT_FOUND", message: "No session \(id)"), status: .notFound)
    }
    let body = try await request.body.collect(upTo: 1024)
    let req = try JSONDecoder().decode(KeyRequest.self, from: body)

    if let chars = req.chars, !chars.isEmpty {
        let cmd = try JSONEncoder().encode(["type": "keys", "chars": chars])
        captureManager.sendCommand(sessionId: id, command: cmd)
    }
    if let n = req.backspaces, n > 0 {
        let cmdStr = "{\"type\":\"backspace\",\"count\":\(n)}"
        captureManager.sendCommand(sessionId: id, command: Data(cmdStr.utf8))
    }
    if req.enter == true {
        let cmdStr = "{\"type\":\"enter\"}"
        captureManager.sendCommand(sessionId: id, command: Data(cmdStr.utf8))
    }
    return jsonResponse(["ok": true])
}

// MARK: - Viewer

router.get("sessions/:id") { _, context in
    let id = context.parameters.get("id") ?? ""
    guard let session = sessionStore.get(id) else {
        return Response(status: .notFound, body: .init(byteBuffer: ByteBuffer(string: "Session not found")))
    }
    let html = viewerHTML(sessionId: id, deviceName: session.deviceName)
    return Response(
        status: .ok,
        headers: [.contentType: "text/html; charset=utf-8"],
        body: .init(byteBuffer: ByteBuffer(string: html))
    )
}

// MARK: - WebSocket Frame Stream

router.ws("ws/sessions/:id/frames") { inbound, outbound, context in
    let id = context.request.uri.string.split(separator: "/").dropFirst().first(where: { $0.hasPrefix("sess_") }).map(String.init) ?? ""
    guard sessionStore.get(id) != nil else { return }

    // Send the current frame immediately so the client doesn't wait for the next change
    if let currentFrame = captureManager.getFrame(id) {
        try await outbound.write(.binary(ByteBuffer(data: currentFrame)))
    }

    let watcher = FrameWatcher(path: captureManager.framePath(for: id))
    for await frame in watcher.frames() {
        try await outbound.write(.binary(ByteBuffer(data: frame)))
    }
}

// MARK: - Start

let app = Application(
    router: router,
    server: .http1WebSocketUpgrade(webSocketRouter: router),
    configuration: .init(address: .hostname(daemonHost, port: daemonPort))
)

print("simcasterd starting on http://\(daemonHost):\(daemonPort)")
print("Viewer: http://\(lanIP):\(daemonPort)/sessions/<id>")
print("For remote access: brew install cloudflared && cloudflared tunnel --url http://localhost:\(daemonPort)")

// MARK: - Graceful Shutdown

func performCleanup() {
    print("\nsimcasterd shutting down…")

    // Stop all active capture sessions
    for session in sessionStore.sessions where session.state != "stopped" {
        captureManager.stopCapture(sessionId: session.id)
        sessionStore.update(session.id) { $0.state = "stopped" }
    }

    // Remove temp frame/cmd directories
    let fm = FileManager.default
    for dir in ["/tmp/simcaster_frames", "/tmp/simcaster_cmds"] {
        try? fm.removeItem(atPath: dir)
    }

    // Remove stale temp files
    for file in ["/tmp/simcaster_capture_args.json", "/tmp/simcaster_capture.log"] {
        try? fm.removeItem(atPath: file)
    }

    print("simcasterd cleanup complete.")
}

// Ignore default signal handling so DispatchSource can catch them
signal(SIGINT, SIG_IGN)
signal(SIGTERM, SIG_IGN)

let sigintSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
sigintSource.setEventHandler {
    performCleanup()
    exit(0)
}
sigintSource.resume()

let sigtermSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
sigtermSource.setEventHandler {
    performCleanup()
    exit(0)
}
sigtermSource.resume()

try await app.run()
