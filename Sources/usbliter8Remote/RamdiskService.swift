import Foundation

struct RamdiskService: Sendable {
    static func isValidIOSVersion(_ value: String) -> Bool {
        value.range(of: #"^[0-9]{1,2}(\.[0-9]{1,3}){0,2}$"#, options: .regularExpression) != nil
    }

    func start(
        iosVersion: String,
        output: @Sendable @escaping (String) -> Void
    ) async throws {
        let normalizedVersion = iosVersion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isValidIOSVersion(normalizedVersion) else {
            throw RamdiskError.invalidVersion
        }
        guard let manifestURL = AppResourceLocator.resourceURL(
            name: "manifest",
            extension: "json",
            subdirectories: ["Ramdisk/payload", "Resources/Ramdisk/payload"]
        ) else {
            throw RamdiskError.missingResource("payload/manifest.json")
        }
        guard let usbliter8ctlURL = AppResourceLocator.toolURL(named: "usbliter8ctl") else {
            throw RamdiskError.missingResource("usbliter8ctl")
        }
        guard let img4toolURL = AppResourceLocator.toolURL(named: "img4tool") else {
            throw RamdiskError.missingResource("img4tool")
        }

        let bundledRamdiskRoot = manifestURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let toolsDirectory = bundledRamdiskRoot.appendingPathComponent("tools", isDirectory: true)
        for required in [
            toolsDirectory.appendingPathComponent("27.im4m"),
            toolsDirectory.appendingPathComponent("iboot_mapping.json"),
            toolsDirectory.appendingPathComponent("irecovery"),
            toolsDirectory.appendingPathComponent("gaster")
        ] where !FileManager.default.fileExists(atPath: required.path) {
            throw RamdiskError.missingResource(required.lastPathComponent)
        }

        removeLegacyPersistentCache()
        output("Decrypting Ramdisk resources…")
        let assets = try await Task.detached(priority: .userInitiated) {
            try RamdiskAssetStore().materialize()
        }.value
        defer { assets.removeTemporaryFiles() }
        output("Ramdisk resources decrypted and integrity verified")

        let workRoot = assets.rootURL.appendingPathComponent(".ramdisk-work", isDirectory: true)
        try FileManager.default.createDirectory(at: workRoot, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: workRoot.path)
        var environment = AppResourceLocator.pythonToolEnvironment()
        environment["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
        environment["PYTHONUNBUFFERED"] = "1"
        environment["LC_ALL"] = "C"
        environment["LANG"] = "C"
        environment["ROOT"] = assets.rootURL.path
        environment["EXTRACTED_ROOT"] = assets.extractedURL.path
        environment["TOOLS_DIR"] = toolsDirectory.path
        environment["WORK_ROOT"] = workRoot.path
        environment["TARGET_IOS_CACHE"] = workRoot.appendingPathComponent("target_ios_by_ecid.tsv").path
        environment["DYNAMIC_SEP_ROOT"] = workRoot.appendingPathComponent("dynamic_sep", isDirectory: true).path
        environment["IMG4_CACHE"] = workRoot.appendingPathComponent("img4", isDirectory: true).path
        environment["USBLITER8"] = usbliter8ctlURL.path
        environment["IMG4TOOL"] = img4toolURL.path

        try await runProcess(
            executable: URL(fileURLWithPath: "/bin/bash"),
            arguments: [assets.scriptURL.path, "-v", normalizedVersion],
            currentDirectory: assets.rootURL,
            environment: environment,
            output: output
        )
    }

    private func removeLegacyPersistentCache() {
        guard let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else { return }
        let legacyDirectory = applicationSupport
            .appendingPathComponent("YXDeviceUtility", isDirectory: true)
            .appendingPathComponent("RamdiskWork", isDirectory: true)
        try? FileManager.default.removeItem(at: legacyDirectory)
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
            let state = RamdiskProcessState(output: output)

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
                let tail = String(
                    data: pipe.fileHandleForReading.readDataToEndOfFile(),
                    encoding: .utf8
                ) ?? ""
                state.finish(tail: tail)

                guard state.claimCompletion() else { return }
                let status = terminatedProcess.terminationStatus
                if status == 0 {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: RamdiskError.commandFailed(
                        status: status,
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

private final class RamdiskProcessState: @unchecked Sendable {
    private let lock = NSLock()
    private let output: @Sendable (String) -> Void
    private var bufferedText = ""
    private var collectedOutput = ""
    private var completionClaimed = false

    init(output: @Sendable @escaping (String) -> Void) {
        self.output = output
    }

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
        if !tail.isEmpty {
            bufferedText += tail
            collectedOutput += tail
        }
        finalLine = bufferedText
        bufferedText = ""
        lock.unlock()
        emit([finalLine])
    }

    var allOutput: String {
        lock.lock()
        defer { lock.unlock() }
        return RamdiskService.cleanTerminalText(collectedOutput)
    }

    func claimCompletion() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !completionClaimed else { return false }
        completionClaimed = true
        return true
    }

    private func emit(_ lines: [String]) {
        for line in lines {
            let clean = RamdiskService.cleanTerminalText(line)
            if !clean.isEmpty { output(clean) }
        }
    }
}

enum RamdiskError: LocalizedError {
    case invalidVersion
    case missingResource(String)
    case commandFailed(status: Int32, output: String)

    var errorDescription: String? {
        switch self {
        case .invalidVersion:
            return "Invalid iOS version format"
        case let .missingResource(name):
            return "Missing Ramdisk resource: \(name)"
        case let .commandFailed(status, output):
            let lastLine = output
                .split(whereSeparator: \.isNewline)
                .map(String.init)
                .last(where: { !$0.isEmpty }) ?? "start.sh execution failed"
            return "Ramdisk startup failed (\(status)):\(lastLine)"
        }
    }
}
