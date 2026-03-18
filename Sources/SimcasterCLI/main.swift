import ArgumentParser
import Foundation
import SimcasterCore

let daemonBase = ProcessInfo.processInfo.environment["SIMCASTER_URL"] ?? "http://127.0.0.1:4821"
let daemonToken = ProcessInfo.processInfo.environment["SIMCASTER_TOKEN"]

@main
struct SimcasterCTL: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "simcasterctl",
        abstract: "CLI for Simcaster daemon",
        subcommands: [Health.self, Devices.self, Boot.self, Sessions.self, Watch.self]
    )
}

func daemonRequest(_ path: String, method: String = "GET", body: Data? = nil) async throws -> (Data, HTTPURLResponse) {
    var request = URLRequest(url: URL(string: "\(daemonBase)/\(path)")!)
    request.httpMethod = method
    if let token = daemonToken {
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    }
    if let body {
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    }
    let (data, response) = try await URLSession.shared.data(for: request)
    guard let http = response as? HTTPURLResponse else {
        throw ExitCode.failure
    }
    return (data, http)
}

func printError(_ message: String) {
    FileHandle.standardError.write(Data("\(message)\n".utf8))
}

struct Health: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Check daemon health")

    @Flag(name: .long, help: "Output as JSON")
    var json: Bool = false

    func run() async throws {
        do {
            let (data, http) = try await daemonRequest("api/health")
            if json {
                print(String(data: data, encoding: .utf8) ?? "{}")
            } else {
                let health = try JSONDecoder().decode(HealthResponse.self, from: data)
                print("Daemon running: \(health.daemonRunning)")
                print("Status: \(health.ok ? "OK" : "ERROR")")
            }
            if http.statusCode != 200 { throw ExitCode.failure }
        } catch let error as ExitCode {
            throw error
        } catch {
            printError("Could not connect to daemon at \(daemonBase)")
            printError("Is simcasterd running?")
            throw ExitCode.failure
        }
    }
}

struct Devices: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "List available simulators")

    @Flag(name: .long, help: "Output as JSON")
    var json: Bool = false

    func run() async throws {
        do {
            let (data, _) = try await daemonRequest("api/devices")
            if json {
                print(String(data: data, encoding: .utf8) ?? "{}")
            } else {
                let result = try JSONDecoder().decode(DevicesResponse.self, from: data)
                if result.devices.isEmpty {
                    print("No available simulators found.")
                } else {
                    for device in result.devices {
                        let state = device.state == "Booted" ? " (Booted)" : ""
                        print("\(device.name)  \(device.runtime)  \(device.udid)\(state)")
                    }
                }
            }
        } catch let error as ExitCode {
            throw error
        } catch {
            printError("Could not connect to daemon at \(daemonBase)")
            printError("Is simcasterd running?")
            throw ExitCode.failure
        }
    }
}

struct Boot: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Boot a simulator by UDID")

    @Option(name: .long, help: "Simulator UDID")
    var udid: String

    @Flag(name: .long, help: "Output as JSON")
    var json: Bool = false

    func run() async throws {
        do {
            let body = try JSONEncoder().encode(BootRequest(udid: udid))
            let (data, http) = try await daemonRequest("api/boot", method: "POST", body: body)
            if json {
                print(String(data: data, encoding: .utf8) ?? "{}")
            } else {
                let result = try JSONDecoder().decode(BootResponse.self, from: data)
                if result.ok {
                    print("\(result.name) (\(result.udid)): \(result.state)")
                    if let msg = result.message { print(msg) }
                } else {
                    printError("Boot failed: \(result.message ?? "unknown error")")
                    throw ExitCode.failure
                }
            }
            if http.statusCode >= 400 { throw ExitCode.failure }
        } catch let error as ExitCode {
            throw error
        } catch {
            printError("Could not connect to daemon at \(daemonBase)")
            printError("Is simcasterd running?")
            throw ExitCode.failure
        }
    }
}

struct Watch: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Create a viewer session for a booted simulator")

    @Option(name: .long, help: "Simulator UDID")
    var udid: String

    @Flag(name: .long, help: "Output as JSON")
    var json: Bool = false

    func run() async throws {
        do {
            let reqBody = try JSONEncoder().encode(["udid": udid])
            let (data, http) = try await daemonRequest("api/sessions", method: "POST", body: reqBody)
            if json {
                print(String(data: data, encoding: .utf8) ?? "{}")
            } else {
                struct Resp: Codable { var ok: Bool; var session: Session?; var message: String? }
                let result = try JSONDecoder().decode(Resp.self, from: data)
                if let s = result.session {
                    print("Session: \(s.id)")
                    print("Device:  \(s.deviceName)")
                    print("State:   \(s.state)")
                    if let url = s.viewerUrl { print("Viewer:  \(url)") }
                    if let msg = result.message { print(msg) }
                } else {
                    printError("Failed to create session")
                    throw ExitCode.failure
                }
            }
            if http.statusCode >= 400 { throw ExitCode.failure }
        } catch let error as ExitCode {
            throw error
        } catch {
            printError("Could not connect to daemon at \(daemonBase)")
            printError("Is simcasterd running?")
            throw ExitCode.failure
        }
    }
}

struct Sessions: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "List active sessions")

    @Flag(name: .long, help: "Output as JSON")
    var json: Bool = false

    func run() async throws {
        do {
            let (data, _) = try await daemonRequest("api/sessions")
            if json {
                print(String(data: data, encoding: .utf8) ?? "{}")
            } else {
                let result = try JSONDecoder().decode(SessionsResponse.self, from: data)
                if result.sessions.isEmpty {
                    print("No active sessions.")
                } else {
                    for s in result.sessions {
                        print("\(s.id)  \(s.deviceName)  \(s.state)  \(s.viewerUrl ?? "")")
                    }
                }
            }
        } catch let error as ExitCode {
            throw error
        } catch {
            printError("Could not connect to daemon at \(daemonBase)")
            printError("Is simcasterd running?")
            throw ExitCode.failure
        }
    }
}
