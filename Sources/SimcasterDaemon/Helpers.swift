import Foundation
import Hummingbird
import SimcasterCore

// MARK: - simctl

func runSimctl(_ arguments: [String]) throws -> (status: Int32, stdout: Data, stderr: Data) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
    process.arguments = ["simctl"] + arguments
    let outPipe = Pipe()
    let errPipe = Pipe()
    process.standardOutput = outPipe
    process.standardError = errPipe
    try process.run()
    process.waitUntilExit()
    return (process.terminationStatus, outPipe.fileHandleForReading.readDataToEndOfFile(), errPipe.fileHandleForReading.readDataToEndOfFile())
}

struct SimctlOutput: Decodable {
    struct SimctlDevice: Decodable {
        var udid: String
        var name: String
        var state: String
        var isAvailable: Bool
    }
    var devices: [String: [SimctlDevice]]
}

func listDevices() throws -> (devices: [Device], raw: SimctlOutput) {
    let result = try runSimctl(["list", "devices", "available", "-j"])
    guard result.status == 0 else { throw SimcasterError.simctlFailed("list devices") }
    let simctl = try JSONDecoder().decode(SimctlOutput.self, from: result.stdout)
    var devices: [Device] = []
    for (runtimeKey, runtimeDevices) in simctl.devices {
        let runtime = runtimeKey
            .replacingOccurrences(of: "com.apple.CoreSimulator.SimRuntime.", with: "")
            .replacingOccurrences(of: "-", with: ".")
            .replacingOccurrences(of: "..", with: " ")
        let cleanRuntime = runtime.replacingOccurrences(
            of: #"(\w+)\.(\d+)"#, with: "$1 $2", options: .regularExpression
        )
        for d in runtimeDevices {
            devices.append(Device(udid: d.udid, name: d.name, runtime: cleanRuntime, state: d.state, isAvailable: d.isAvailable))
        }
    }
    devices.sort { $0.name < $1.name }
    return (devices, simctl)
}

enum SimcasterError: Error {
    case simctlFailed(String)
    case deviceNotFound(String)
}

// MARK: - JSON Response

func jsonResponse<T: Encodable>(_ value: T, status: HTTPResponse.Status = .ok) -> Response {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    do {
        let data = try encoder.encode(value)
        return Response(
            status: status,
            headers: [.contentType: "application/json"],
            body: .init(byteBuffer: ByteBuffer(data: data))
        )
    } catch {
        return Response(
            status: .internalServerError,
            headers: [.contentType: "application/json"],
            body: .init(byteBuffer: ByteBuffer(string: "{\"ok\":false,\"errorCode\":\"ENCODE_FAILED\",\"message\":\"Internal encoding error\"}"))
        )
    }
}

// MARK: - Networking

func getLanIP() -> String? {
    var ifaddr: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
    defer { freeifaddrs(ifaddr) }
    for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
        let addr = ptr.pointee
        guard addr.ifa_addr.pointee.sa_family == UInt8(AF_INET) else { continue }
        let name = String(cString: addr.ifa_name)
        guard name.hasPrefix("en") else { continue }
        var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        if getnameinfo(addr.ifa_addr, socklen_t(addr.ifa_addr.pointee.sa_len),
                       &hostname, socklen_t(hostname.count), nil, 0, NI_NUMERICHOST) == 0 {
            let ip = String(cString: hostname)
            if ip.hasPrefix("192.") || ip.hasPrefix("10.") || ip.hasPrefix("172.") { return ip }
        }
    }
    return nil
}

// MARK: - String Escaping

func htmlEscape(_ s: String) -> String {
    s.replacingOccurrences(of: "&", with: "&amp;")
     .replacingOccurrences(of: "<", with: "&lt;")
     .replacingOccurrences(of: ">", with: "&gt;")
     .replacingOccurrences(of: "\"", with: "&quot;")
     .replacingOccurrences(of: "'", with: "&#39;")
}

func jsEscape(_ s: String) -> String {
    s.replacingOccurrences(of: "\\", with: "\\\\")
     .replacingOccurrences(of: "\"", with: "\\\"")
     .replacingOccurrences(of: "\n", with: "\\n")
     .replacingOccurrences(of: "\r", with: "\\r")
}
