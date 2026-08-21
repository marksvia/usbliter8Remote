import Foundation

struct HelloNoChangeService: Sendable {
    static func normalizedECID(_ value: String) -> String? {
        let trimmed = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "0x", with: "", options: .caseInsensitive)
            .uppercased()
        guard !trimmed.isEmpty,
              trimmed.count <= 16,
              trimmed.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "0123456789ABCDEF").contains($0) }) else {
            return nil
        }
        return trimmed.count >= 16
            ? trimmed
            : String(repeating: "0", count: 16 - trimmed.count) + trimmed
    }

    func run(
        ecid: String,
        output: @Sendable @escaping (String) -> Void
    ) async throws {
        guard let normalizedECID = Self.normalizedECID(ecid) else {
            throw HelloNoChangeError.invalidECID
        }
        guard let manifestURL = AppResourceLocator.resourceURL(
            name: "manifest",
            extension: "json",
            subdirectories: ["HelloNoChange/payload", "Resources/HelloNoChange/payload"]
        ) else {
            throw HelloNoChangeError.missingResource("payload/manifest.json")
        }

        guard let iproxyURL = AppResourceLocator.toolURL(named: "iproxy") else {
            throw HelloNoChangeError.missingResource("iproxy")
        }

        output("Decrypting helloNoChange resources…")
        let assets = try await Task.detached(priority: .userInitiated) {
            try RamdiskAssetStore().materialize(payloadDirectory: manifestURL.deletingLastPathComponent())
        }.value
        defer { assets.removeTemporaryFiles() }

        let toolsDirectory = assets.extractedURL.appendingPathComponent("tools", isDirectory: true)
        let resourcesDirectory = assets.extractedURL.appendingPathComponent("resources", isDirectory: true)
        let phpLauncher = toolsDirectory.appendingPathComponent("php-cli")
        let required = [
            assets.extractedURL.appendingPathComponent("sn.php"),
            assets.extractedURL.appendingPathComponent("nosn-nochange.php"),
            assets.extractedURL.appendingPathComponent("analysis/mobilegestalt_offsets/find_cpid_offset.py"),
            resourcesDirectory.appendingPathComponent("disabled.plist"),
            resourcesDirectory.appendingPathComponent("com.apple.purplebuddy.plist"),
            resourcesDirectory.appendingPathComponent("com.apple.commcenter.device_specific_nobackup.plist"),
            phpLauncher,
            toolsDirectory.appendingPathComponent("php-packages/SHA256SUMS"),
            toolsDirectory.appendingPathComponent("php-packages/php-8.4.23-cli-macos-aarch64.tar.gz"),
            toolsDirectory.appendingPathComponent("php-packages/php-8.4.23-cli-macos-x86_64.tar.gz")
        ]
        for url in required where !FileManager.default.fileExists(atPath: url.path) {
            throw HelloNoChangeError.missingResource(url.lastPathComponent)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: phpLauncher.path)

        let workRoot = assets.rootURL.appendingPathComponent(".hello-work", isDirectory: true)
        let payloadRoot = workRoot.appendingPathComponent("payloads", isDirectory: true)
        try FileManager.default.createDirectory(at: payloadRoot, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: workRoot.path)

        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        environment["LC_ALL"] = "C"
        environment["LANG"] = "C"
        environment["HELLO_BASE_DIR"] = assets.extractedURL.path
        environment["TOOLS_DIR"] = toolsDirectory.path
        environment["RES_DIR"] = resourcesDirectory.path
        environment["PAYLOAD_ROOT"] = payloadRoot.path
        environment["WORK_ROOT"] = workRoot.path
        environment["APP_IPROXY"] = iproxyURL.path
        environment["PHP_BIN"] = phpLauncher.path
        environment["PHP_NO_DOCKER"] = "1"
        environment["RUN_BOOT"] = "0"
        environment["SKIP_MOUNT"] = "1"
        environment["START_IPROXY"] = "1"
        environment["SSH_HOST"] = "localhost"
        environment["SSH_PORT"] = "2222"
        environment["SSH_USER"] = "root"
        environment["SSH_PASS"] = "alpine"
        environment["HELLO_TEMP_DIR"] = workRoot.path
        environment["TMPDIR"] = workRoot.path

        output("helloNoChange resources decrypted and integrity verified")
        output("Device is already in Ramdisk with /mnt2 mounted; skipping startup and mount")
        try await runProcess(
            executable: URL(fileURLWithPath: "/bin/bash"),
            arguments: [
                assets.scriptURL.path,
                "--skip-mount",
                "-nodocker",
                "--ecid", normalizedECID
            ],
            currentDirectory: assets.rootURL,
            environment: environment,
            output: output
        )
    }

    private func runProcess(
        executable: URL,
        arguments: [String],
        currentDirectory: URL,
        environment: [String: String],
        output: @Sendable @escaping (String) -> Void
    ) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let process = Process()
            let pipe = Pipe()
            let state = HelloNoChangeProcessState(output: output)
            process.executableURL = executable
            process.arguments = arguments
            process.currentDirectoryURL = currentDirectory
            process.environment = environment
            process.standardOutput = pipe
            process.standardError = pipe

            pipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty, let chunk = String(data: data, encoding: .utf8) else { return }
                state.append(chunk)
            }
            process.terminationHandler = { terminatedProcess in
                pipe.fileHandleForReading.readabilityHandler = nil
                let tail = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                state.finish(tail: tail)
                guard state.claimCompletion() else { return }
                if terminatedProcess.terminationStatus == 0 {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: HelloNoChangeError.commandFailed(
                        status: terminatedProcess.terminationStatus,
                        output: state.allOutput
                    ))
                }
            }
            do {
                try process.run()
            } catch {
                pipe.fileHandleForReading.readabilityHandler = nil
                guard state.claimCompletion() else { return }
                continuation.resume(throwing: error)
            }
        }
    }

    fileprivate static func cleanTerminalText(_ value: String) -> String {
        value
            .replacingOccurrences(of: #"\u{001B}\[[0-9;]*[A-Za-z]"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private final class HelloNoChangeProcessState: @unchecked Sendable {
    private let lock = NSLock()
    private let output: @Sendable (String) -> Void
    private var bufferedText = ""
    private var collectedOutput = ""
    private var completionClaimed = false

    init(output: @Sendable @escaping (String) -> Void) { self.output = output }

    func append(_ chunk: String) {
        var lines: [String] = []
        lock.lock()
        bufferedText += chunk
        collectedOutput += chunk
        while let newline = bufferedText.firstIndex(of: "\n") {
            lines.append(String(bufferedText[..<newline]))
            bufferedText.removeSubrange(...newline)
        }
        lock.unlock()
        emit(lines)
    }

    func finish(tail: String) {
        var finalLine = ""
        lock.lock()
        bufferedText += tail
        collectedOutput += tail
        finalLine = bufferedText
        bufferedText = ""
        lock.unlock()
        emit([finalLine])
    }

    var allOutput: String {
        lock.lock(); defer { lock.unlock() }
        return HelloNoChangeService.cleanTerminalText(collectedOutput)
    }

    func claimCompletion() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !completionClaimed else { return false }
        completionClaimed = true
        return true
    }

    private func emit(_ lines: [String]) {
        for line in lines {
            let clean = HelloNoChangeService.cleanTerminalText(line)
            if !clean.isEmpty { output(clean) }
        }
    }
}

enum HelloNoChangeError: LocalizedError {
    case invalidECID
    case missingResource(String)
    case commandFailed(status: Int32, output: String)

    var errorDescription: String? {
        switch self {
        case .invalidECID: return "A valid device ECID was not found"
        case let .missingResource(name): return "Missing helloNoChange resource: \(name)"
        case let .commandFailed(status, output):
            let lastLine = output.split(whereSeparator: \.isNewline).map(String.init).last(where: { !$0.isEmpty })
                ?? "hello-nochange.sh execution failed"
            return "helloNoChange failed (\(status)):\(lastLine)"
        }
    }
}
