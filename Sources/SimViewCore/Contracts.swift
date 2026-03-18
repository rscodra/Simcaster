import Foundation

public struct HealthResponse: Codable, Sendable {
    public var ok: Bool
    public var daemonRunning: Bool

    public init(ok: Bool, daemonRunning: Bool) {
        self.ok = ok
        self.daemonRunning = daemonRunning
    }
}

public struct Device: Codable, Sendable {
    public var udid: String
    public var name: String
    public var runtime: String
    public var state: String
    public var isAvailable: Bool

    public init(udid: String, name: String, runtime: String, state: String, isAvailable: Bool) {
        self.udid = udid
        self.name = name
        self.runtime = runtime
        self.state = state
        self.isAvailable = isAvailable
    }
}

public struct DevicesResponse: Codable, Sendable {
    public var ok: Bool
    public var devices: [Device]

    public init(ok: Bool, devices: [Device]) {
        self.ok = ok
        self.devices = devices
    }
}

public struct BootRequest: Codable, Sendable {
    public var udid: String

    public init(udid: String) {
        self.udid = udid
    }
}

public struct BootResponse: Codable, Sendable {
    public var ok: Bool
    public var udid: String
    public var name: String
    public var state: String
    public var message: String?
    public var errorCode: String?

    public init(ok: Bool, udid: String, name: String, state: String, message: String? = nil, errorCode: String? = nil) {
        self.ok = ok
        self.udid = udid
        self.name = name
        self.state = state
        self.message = message
        self.errorCode = errorCode
    }
}

public struct ErrorResponse: Codable, Sendable {
    public var ok: Bool
    public var errorCode: String
    public var message: String

    public init(ok: Bool = false, errorCode: String, message: String) {
        self.ok = ok
        self.errorCode = errorCode
        self.message = message
    }
}

public struct Session: Codable, Sendable {
    public var id: String
    public var udid: String
    public var deviceName: String
    public var bundleId: String?
    public var state: String
    public var viewerUrl: String?
    public var viewerToken: String?
    public var createdAt: String
    public var lastError: String?

    public init(id: String, udid: String, deviceName: String, bundleId: String? = nil, state: String, viewerUrl: String? = nil, viewerToken: String? = nil, createdAt: String, lastError: String? = nil) {
        self.id = id
        self.udid = udid
        self.deviceName = deviceName
        self.bundleId = bundleId
        self.state = state
        self.viewerUrl = viewerUrl
        self.viewerToken = viewerToken
        self.createdAt = createdAt
        self.lastError = lastError
    }
}

public struct SessionsResponse: Codable, Sendable {
    public var ok: Bool
    public var sessions: [Session]

    public init(ok: Bool, sessions: [Session]) {
        self.ok = ok
        self.sessions = sessions
    }
}
