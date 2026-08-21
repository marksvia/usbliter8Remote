import Foundation

struct RamdiskObliterationService: Sendable {
    func erase(output: @Sendable @escaping (String) -> Void) async throws {
        try await Task.detached(priority: .userInitiated) {
            try eraseSynchronously(output: output)
        }.value
    }

    private func eraseSynchronously(output: @Sendable @escaping (String) -> Void) throws {
        guard let iproxyURL = AppResourceLocator.toolURL(named: "iproxy") else {
            throw RamdiskObliterationError.missingResource("iproxy")
        }

        guard FileManager.default.fileExists(atPath: "/usr/bin/expect") else {
            throw RamdiskObliterationError.missingResource("/usr/bin/expect")
        }

        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(".yx-oblit-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: temporaryRoot.path)
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        var iproxyProcess: Process?
        if !Self.isPortListening(2222) {
            output("Starting USB SSH forwarding…")
            let process = Process()
            process.executableURL = iproxyURL
            process.arguments = ["2222", "22"]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            iproxyProcess = process
            Thread.sleep(forTimeInterval: 1)
        } else {
            output("Reusing the current Ramdisk SSH forwarding")
        }
        defer {
            if let process = iproxyProcess, process.isRunning {
                process.terminate()
                process.waitUntilExit()
            }
        }

        output("Connecting to Ramdisk SSH…")
        var connected = false
        for _ in 0..<30 {
            let probe = try runSSH(
                command: "echo __YX_SSH_READY__",
                temporaryRoot: temporaryRoot,
                timeout: 8
            )
            if probe.output.contains("__YX_SSH_READY__") {
                connected = true
                break
            }
            Thread.sleep(forTimeInterval: 2)
        }
        guard connected else { throw RamdiskObliterationError.sshUnavailable }

        output("Ramdisk SSH Connected")
        output("Writing the obliteration NVRAM value twice and triggering device execution…")
        let command = "/usr/sbin/nvram oblit-inprogress=5 && /usr/sbin/nvram oblit-inprogress=5 && echo __YX_OBLIT_APPLIED__ && kill 1"
        let result = try runSSH(command: command, temporaryRoot: temporaryRoot, timeout: 30)
        let cleanOutput = Self.cleanTerminalText(result.output)
        let lowerOutput = cleanOutput.lowercased()
        let hasCommandError = lowerOutput.contains("command not found")
            || lowerOutput.contains("permission denied")
            || lowerOutput.contains("no such file")
        let didApplyObliteration = cleanOutput.contains("__YX_OBLIT_APPLIED__")
        let acceptedStatus = result.status == 0 || result.status == 255
        guard didApplyObliteration, !hasCommandError, acceptedStatus else {
            throw RamdiskObliterationError.commandFailed(status: result.status, output: cleanOutput)
        }
        output("The obliteration NVRAM value was written twice; the device is processing it")
    }

    private func runSSH(
        command: String,
        temporaryRoot: URL,
        timeout: Int
    ) throws -> (status: Int32, output: String) {
        let scriptURL = temporaryRoot.appendingPathComponent("ssh-\(UUID().uuidString).expect")
        let escapedCommand = Self.escapeForTcl(command)
        let script = """
        #!/usr/bin/expect -f
        log_user 1
        set timeout \(timeout)
        spawn /usr/bin/ssh -p 2222 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8 -o ServerAliveInterval=5 -o ServerAliveCountMax=2 -o LogLevel=ERROR root@localhost "\(escapedCommand)"
        expect {
          -re "(?i)password:" { send "alpine\\r"; exp_continue }
          timeout { exit 124 }
          eof
        }
        catch wait result
        exit [lindex $result 3]
        """
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: scriptURL.path)
        defer { try? FileManager.default.removeItem(at: scriptURL) }

        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/expect")
        process.arguments = [scriptURL.path]
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }

    private static func isPortListening(_ port: Int) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        process.arguments = ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    private static func escapeForTcl(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "$", with: "\\$")
            .replacingOccurrences(of: "[", with: "\\[")
            .replacingOccurrences(of: "]", with: "\\]")
    }

    private static func cleanTerminalText(_ value: String) -> String {
        value
            .replacingOccurrences(of: #"\u{001B}\[[0-9;]*[A-Za-z]"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum RamdiskObliterationError: LocalizedError {
    case missingResource(String)
    case sshUnavailable
    case commandFailed(status: Int32, output: String)

    var errorDescription: String? {
        switch self {
        case let .missingResource(name):
            return "Missing Ramdisk obliteration resource: \(name)"
        case .sshUnavailable:
            return "Could not connect to Ramdisk SSH. Keep the device connected by USB."
        case let .commandFailed(status, output):
            let lastLine = output
                .split(whereSeparator: \.isNewline)
                .map(String.init)
                .last(where: { !$0.isEmpty }) ?? "SSH command failed"
            return "Ramdisk obliteration command failed (\(status)):\(lastLine)"
        }
    }
}
