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
        subcommands: [Health.self, Devices.self, Boot.self, Sessions.self, Watch.self, Init.self]
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

struct Init: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Generate CLAUDE.md with Simcaster instructions for the current project")

    @Option(name: .long, help: "Path to project directory (default: current directory)")
    var path: String = "."

    func run() throws {
        let fm = FileManager.default
        let projectDir = (path as NSString).standardizingPath
        let absDir = projectDir.hasPrefix("/") ? projectDir : fm.currentDirectoryPath + "/" + projectDir

        // Detect xcodeproj
        let contents = (try? fm.contentsOfDirectory(atPath: absDir)) ?? []
        let xcodeproj = contents.first(where: { $0.hasSuffix(".xcodeproj") })

        // Try to extract scheme and bundle ID from project
        var scheme = "<YOUR_SCHEME>"
        var bundleId = "<YOUR_BUNDLE_ID>"
        var projectFlag = ""

        if let proj = xcodeproj {
            let projName = (proj as NSString).deletingPathExtension
            scheme = projName
            projectFlag = "-project \(proj) "

            // Try reading pbxproj for bundle ID
            let pbxPath = "\(absDir)/\(proj)/project.pbxproj"
            if let pbxData = fm.contents(atPath: pbxPath),
               let pbxString = String(data: pbxData, encoding: .utf8) {
                // Look for PRODUCT_BUNDLE_IDENTIFIER
                let lines = pbxString.components(separatedBy: "\n")
                for line in lines {
                    if line.contains("PRODUCT_BUNDLE_IDENTIFIER") {
                        let parts = line.components(separatedBy: "=")
                        if parts.count >= 2 {
                            let raw = parts[1].trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ";", with: "").replacingOccurrences(of: "\"", with: "")
                            if !raw.isEmpty && !raw.contains("$(") {
                                bundleId = raw
                                break
                            }
                        }
                    }
                }
            }
        } else {
            // Check for Package.swift (SPM project)
            if contents.contains("Package.swift") {
                projectFlag = ""
            }
        }

        let claudeMd = """
        ## iOS Simulator Preview

        This project uses [Simcaster](https://github.com/rscodra/Simcaster) for remote Simulator preview. When asked to build and preview the app, follow this workflow.

        ### Check Simcaster is running

        ```bash
        curl -s "http://127.0.0.1:4821/api/health?token=$SIMCASTER_TOKEN"
        ```

        If the daemon isn't running, start it:
        ```bash
        export SIMCASTER_TOKEN="${SIMCASTER_TOKEN:-$(LC_ALL=C tr -dc 'a-z0-9' </dev/urandom | head -c 24)}"
        simcasterd &
        ```

        If `simcasterd` is not found, install Simcaster (takes 2-3 minutes — builds from source, do NOT set a timeout shorter than 5 minutes):
        ```bash
        curl -fsSL https://raw.githubusercontent.com/rscodra/Simcaster/main/install.sh | bash
        source ~/.zshrc
        ```

        ### Build & Preview

        ```bash
        # Boot a simulator (pick latest iPhone unless specified)
        simcasterctl devices
        simcasterctl boot --udid <UDID>
        open -a Simulator

        # Build the app
        xcodebuild \(projectFlag)-scheme \(scheme) -destination 'platform=iOS Simulator,id=<UDID>' build 2>&1 | tail -20

        # Install and launch
        xcrun simctl install <UDID> ~/Library/Developer/Xcode/DerivedData/\(scheme)-*/Build/Products/Debug-iphonesimulator/\(scheme).app
        xcrun simctl launch <UDID> \(bundleId)

        # Create a viewer session — give the user the URL it prints
        simcasterctl watch --udid <UDID>
        ```

        ### Rebuild After Changes

        ```bash
        xcodebuild \(projectFlag)-scheme \(scheme) -destination 'platform=iOS Simulator,id=<UDID>' build 2>&1 | tail -20
        xcrun simctl install <UDID> ~/Library/Developer/Xcode/DerivedData/\(scheme)-*/Build/Products/Debug-iphonesimulator/\(scheme).app
        xcrun simctl terminate <UDID> \(bundleId) && xcrun simctl launch <UDID> \(bundleId)
        ```

        The viewer auto-reconnects — no need to create a new session.

        ### Troubleshooting

        ```bash
        # Restart a stuck session
        curl -X POST "http://127.0.0.1:4821/api/sessions/<session-id>/stop?token=$SIMCASTER_TOKEN"
        simcasterctl watch --udid <UDID>

        # Full restart
        pkill simcasterd; pkill CaptureSpike
        simcasterd &
        ```
        """

        let claudeMdPath = "\(absDir)/CLAUDE.md"
        if fm.fileExists(atPath: claudeMdPath) {
            // Append to existing
            let existing = (try? String(contentsOfFile: claudeMdPath, encoding: .utf8)) ?? ""
            if existing.contains("Simcaster") {
                printError("CLAUDE.md already contains Simcaster instructions. Skipping.")
                return
            }
            try (existing + "\n\n" + claudeMd).write(toFile: claudeMdPath, atomically: true, encoding: .utf8)
            print("Appended Simcaster instructions to existing CLAUDE.md")
        } else {
            try claudeMd.write(toFile: claudeMdPath, atomically: true, encoding: .utf8)
            print("Created CLAUDE.md with Simcaster instructions")
        }

        print("")
        if scheme != "<YOUR_SCHEME>" {
            print("Detected scheme: \(scheme)")
        }
        if bundleId != "<YOUR_BUNDLE_ID>" {
            print("Detected bundle ID: \(bundleId)")
        }
        if scheme == "<YOUR_SCHEME>" || bundleId == "<YOUR_BUNDLE_ID>" {
            print("Some values could not be auto-detected. Edit CLAUDE.md to fill in the placeholders.")
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
