import ArgumentParser
import Foundation
import SimcasterCore

let daemonBase = ProcessInfo.processInfo.environment["SIMCASTER_URL"] ?? "http://127.0.0.1:4821"
let daemonToken: String? = {
    if let t = ProcessInfo.processInfo.environment["SIMCASTER_TOKEN"], !t.isEmpty {
        return t
    }
    let tokenPath = NSHomeDirectory() + "/.simcaster/token"
    if let fileToken = try? String(contentsOfFile: tokenPath, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), !fileToken.isEmpty {
        return fileToken
    }
    return nil
}()

@main
struct SimcasterCTL: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "simcasterctl",
        abstract: "CLI for Simcaster daemon",
        subcommands: [Health.self, Devices.self, Boot.self, Sessions.self, Watch.self, Init.self, Setup.self]
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

struct Setup: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Set up permissions and start the daemon")

    func run() throws {
        let fm = FileManager.default
        let home = NSHomeDirectory()
        let installDir = ProcessInfo.processInfo.environment["SIMCASTER_HOME"] ?? "\(home)/.simcaster"
        let helperApp = "\(installDir)/Spike/CaptureSpike.app"
        let helperBinary = "\(helperApp)/Contents/MacOS/CaptureSpike"

        // Check capture helper exists
        guard fm.fileExists(atPath: helperBinary) else {
            printError("Capture helper not found at \(helperApp)")
            printError("Run the install script first:")
            printError("  curl -fsSL https://raw.githubusercontent.com/rscodra/Simcaster/main/install.sh | bash")
            throw ExitCode.failure
        }

        print("")
        print("  Simcaster Setup")
        print("  ===============")
        print("")
        print("  The capture helper needs two macOS permissions:")
        print("    1. Screen Recording  — to capture the Simulator window")
        print("    2. Accessibility     — to inject touch and keyboard input")
        print("")
        print("  I'll launch the capture helper now to trigger the permission prompts.")
        print("  Grant both permissions in System Settings when prompted.")
        print("")
        print("  IMPORTANT: After granting each permission, you may need to")
        print("  quit and reopen the capture helper for it to take effect.")
        print("  This setup command handles that automatically.")
        print("")
        print("  Press Enter to continue...")

        _ = readLine()

        // Step 1: Launch capture helper to trigger Screen Recording prompt
        print("  [1/3] Launching capture helper for Screen Recording permission...")
        print("        A permission dialog should appear — click 'Open System Settings'")
        print("        and enable CaptureSpike under Screen Recording.")
        print("")

        let process1 = Process()
        process1.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process1.arguments = ["-a", helperApp, "--args", "--permission-check"]
        try process1.run()
        process1.waitUntilExit()

        // Give time for the app to launch and trigger the prompt
        Thread.sleep(forTimeInterval: 3)

        print("  Have you granted Screen Recording permission? (y/n) ", terminator: "")
        let screenAnswer = readLine()?.lowercased() ?? ""

        if screenAnswer == "y" || screenAnswer == "yes" {
            // Kill and relaunch to pick up the new permission
            print("  Restarting capture helper to apply Screen Recording permission...")
            let kill1 = Process()
            kill1.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
            kill1.arguments = ["-f", "CaptureSpike"]
            try? kill1.run()
            kill1.waitUntilExit()
            Thread.sleep(forTimeInterval: 1)
        }

        // Step 2: Accessibility — open the settings pane directly
        print("")
        print("  [2/3] Accessibility permission...")
        print("        Opening System Settings — find CaptureSpike and enable it.")

        let openSettings = Process()
        openSettings.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        openSettings.arguments = ["x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"]
        try? openSettings.run()
        openSettings.waitUntilExit()

        print("")
        print("  Have you granted Accessibility permission? (y/n) ", terminator: "")
        let accessAnswer = readLine()?.lowercased() ?? ""

        if accessAnswer == "y" || accessAnswer == "yes" {
            // Kill and relaunch so it picks up the new permission
            print("  Restarting capture helper to apply Accessibility permission...")
            let killAccess = Process()
            killAccess.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
            killAccess.arguments = ["-f", "CaptureSpike"]
            try? killAccess.run()
            killAccess.waitUntilExit()
            Thread.sleep(forTimeInterval: 1)

            // Relaunch
            let relaunchProc = Process()
            relaunchProc.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            relaunchProc.arguments = ["-a", helperApp, "--args", "--launched-by-daemon"]
            try? relaunchProc.run()
            relaunchProc.waitUntilExit()
            Thread.sleep(forTimeInterval: 2)

            // Verify by sending a harmless test command and checking it gets consumed
            let cmdDir = "/tmp/simcaster_cmds"
            try? fm.createDirectory(atPath: cmdDir, withIntermediateDirectories: true)
            let testCmdPath = "\(cmdDir)/accessibility_test.cmd"
            // Send a "noop" button press that won't affect anything visible
            try? Data("{\"type\":\"button\",\"button\":\"shake\"}\n".utf8).write(to: URL(fileURLWithPath: testCmdPath), options: .atomic)

            // Wait briefly and check if the command file was consumed
            Thread.sleep(forTimeInterval: 2)
            if fm.fileExists(atPath: testCmdPath) {
                // Command file still there — helper couldn't process it (likely no Accessibility)
                try? fm.removeItem(atPath: testCmdPath)
                print("")
                print("  ⚠ Accessibility doesn't seem to be active yet.")
                print("    Touch input may not work. Try these steps:")
                print("    1. Open System Settings > Privacy & Security > Accessibility")
                print("    2. Remove CaptureSpike if listed, then re-add it")
                print("    3. Re-run 'simcasterctl setup'")
            } else {
                print("  Accessibility is working!")
            }
        } else {
            print("")
            print("  You can grant it later — screen capture will work but")
            print("  touch input won't be forwarded to the Simulator.")
        }

        // Kill any leftover capture helper from permission check
        let killFinal = Process()
        killFinal.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        killFinal.arguments = ["-f", "CaptureSpike"]
        try? killFinal.run()
        killFinal.waitUntilExit()
        Thread.sleep(forTimeInterval: 1)

        // Step 3: Verify by doing a quick capture test
        print("")
        print("  [3/3] Verifying permissions...")

        // Write a temp args file for the test
        let testArgs: [String: String] = ["sessionId": "setup_test", "deviceName": ""]
        let testArgsData = try JSONSerialization.data(withJSONObject: testArgs)
        try testArgsData.write(to: URL(fileURLWithPath: "/tmp/simcaster_capture_args.json"))
        try fm.createDirectory(atPath: "/tmp/simcaster_frames", withIntermediateDirectories: true)

        // Launch and check if it produces a frame
        let verifyProc = Process()
        verifyProc.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        verifyProc.arguments = ["-a", helperApp, "--args", "--launched-by-daemon"]
        try verifyProc.run()
        verifyProc.waitUntilExit()

        // Wait for a frame
        var frameFound = false
        let framePath = "/tmp/simcaster_frames/setup_test.jpg"
        for _ in 0..<20 {
            Thread.sleep(forTimeInterval: 0.5)
            if fm.fileExists(atPath: framePath) {
                frameFound = true
                break
            }
        }

        // Clean up test frame
        try? fm.removeItem(atPath: framePath)
        let killTest = Process()
        killTest.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        killTest.arguments = ["-f", "CaptureSpike"]
        try? killTest.run()
        killTest.waitUntilExit()

        print("")
        if frameFound {
            print("  Screen capture is working!")
        } else {
            print("  Screen capture test failed.")
            print("  This could mean:")
            print("    - No Simulator window is open (open one with: open -a Simulator)")
            print("    - Screen Recording permission wasn't granted yet")
            print("    - The permission needs a logout/login to take effect")
            print("")
            print("  You can re-run 'simcasterctl setup' after fixing the issue.")
        }

        print("")
        if frameFound {
            print("  Would you like to add Simcaster to an iOS project now?")
            print("  Enter the path to your project (or press Enter to skip): ", terminator: "")
            if let projectPath = readLine(), !projectPath.isEmpty {
                let expandedPath = NSString(string: projectPath).expandingTildeInPath
                let absPath = expandedPath.hasPrefix("/") ? expandedPath : fm.currentDirectoryPath + "/" + expandedPath
                if fm.fileExists(atPath: absPath) {
                    // Run init for the project
                    do {
                        let initCmd = try Init.parse(["--path", absPath])
                        try initCmd.run()
                        print("")
                        print("  You're all set! Open that project in Claude Code and ask")
                        print("  it to \"build and preview the app\" — it handles the rest.")
                    } catch {
                        print("  Failed to init project: \(error)")
                        print("  You can run it manually: simcasterctl init --path \(absPath)")
                    }
                } else {
                    print("  Directory not found: \(absPath)")
                    print("  You can run it later: cd ~/YourApp && simcasterctl init")
                }
            } else {
                print("  No problem. When you're ready:")
                print("")
                print("    cd ~/YourApp")
                print("    simcasterctl init")
                print("")
                print("  Then open the project in Claude Code and ask it to")
                print("  \"build and preview the app\" — it handles the rest.")
            }
        } else {
            print("  You can still add Simcaster to a project:")
            print("")
            print("    cd ~/YourApp")
            print("    simcasterctl init")
        }
        print("")
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

        If `simcasterd` is not found, install Simcaster:
        ```bash
        curl -fsSL https://raw.githubusercontent.com/rscodra/Simcaster/main/install.sh | bash
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

        # Create a viewer session
        simcasterctl watch --udid <UDID>
        ```

        The watch command prints a local URL. For remote access, start a Cloudflare tunnel and give the user the tunnel URL instead:
        ```bash
        # Start tunnel if not already running (check with: pgrep cloudflared)
        cloudflared tunnel --url http://localhost:4821 &>/tmp/cloudflared.log &
        sleep 3
        # Extract the tunnel URL from the log
        grep -o 'https://[^ ]*\\.trycloudflare\\.com' /tmp/cloudflared.log | head -1
        ```
        Replace the host in the viewer URL with the tunnel URL. Always prefer giving the user the tunnel URL over the local IP.

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
