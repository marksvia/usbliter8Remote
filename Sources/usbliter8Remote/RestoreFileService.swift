import Foundation

struct RestoreFileService: Sendable {
    static func normalizedIdentifier(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_") )
        let scalars = value.uppercased().unicodeScalars.filter { allowed.contains($0) }
        return String(String.UnicodeScalarView(scalars)).prefix(64).description
    }

    static func matchesBackupDirectory(_ url: URL, deviceIdentifier: String) -> Bool {
        let identifier = normalizedIdentifier(deviceIdentifier)
        return !identifier.isEmpty
            && url.lastPathComponent.hasPrefix("Backup_Tickets_\(identifier)_")
            && FileManager.default.fileExists(atPath: url.path)
    }

    static func latestBackupDirectory(deviceIdentifier: String) -> URL? {
        guard let desktopURL = FileManager.default.urls(
            for: .desktopDirectory,
            in: .userDomainMask
        ).first else { return nil }
        let identifier = normalizedIdentifier(deviceIdentifier)
        guard !identifier.isEmpty else { return nil }
        let prefix = "Backup_Tickets_\(identifier)_"
        let candidates = (try? FileManager.default.contentsOfDirectory(
            at: desktopURL,
            includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        return candidates
            .filter {
                let values = try? $0.resourceValues(forKeys: [.isDirectoryKey])
                return values?.isDirectory == true && $0.lastPathComponent.hasPrefix(prefix)
            }
            .sorted {
                let left = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                let right = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                return left > right
            }
            .first
    }

    func restoreOld(
        inputDirectory: URL,
        deviceIdentifier: String,
        output: @Sendable @escaping (String) -> Void
    ) async throws {
        let identifier = Self.normalizedIdentifier(deviceIdentifier)
        guard !identifier.isEmpty else { throw RestoreFileError.missingDeviceIdentifier }
        guard Self.matchesBackupDirectory(inputDirectory, deviceIdentifier: identifier) else {
            throw RestoreFileError.wrongBackupDirectory
        }
        guard let manifestURL = AppResourceLocator.resourceURL(
            name: "manifest",
            extension: "json",
            subdirectories: ["RestoreFile/payload", "Resources/RestoreFile/payload"]
        ) else {
            throw RestoreFileError.missingResource("payload/manifest.json")
        }

        guard let iproxyURL = AppResourceLocator.toolURL(named: "iproxy") else {
            throw RestoreFileError.missingResource("iproxy")
        }

        output("Decrypting restoreFile resources…")
        let assets = try await Task.detached(priority: .userInitiated) {
            try RamdiskAssetStore().materialize(payloadDirectory: manifestURL.deletingLastPathComponent())
        }.value
        defer { assets.removeTemporaryFiles() }

        for required in [
            assets.extractedURL.appendingPathComponent("remote_mount_old.sh"),
            assets.extractedURL.appendingPathComponent("disabled.plist"),
            assets.extractedURL.appendingPathComponent("com.apple.purplebuddy.plist")
        ] where !FileManager.default.fileExists(atPath: required.path) {
            throw RestoreFileError.missingResource(required.lastPathComponent)
        }

        let workRoot = assets.rootURL.appendingPathComponent(".restore-work", isDirectory: true)
        let runID = Self.makeRunID()
        let workDirectory = workRoot.appendingPathComponent(runID, isDirectory: true)
        try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: workRoot.path)

        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        environment["LC_ALL"] = "C"
        environment["LANG"] = "C"
        environment["ROOT"] = assets.rootURL.path
        environment["TEST"] = assets.rootURL.path
        environment["TOOLS_DIR"] = assets.extractedURL.path
        environment["APP_IPROXY"] = iproxyURL.path
        environment["GIVE_ROOT"] = inputDirectory.deletingLastPathComponent().path
        environment["RUN_ID"] = runID
        environment["WORK_ROOT"] = workRoot.path
        environment["WORK_DIR"] = workDirectory.path
        environment["LOG_FILE"] = workDirectory.appendingPathComponent("restore.log").path
        environment["SUMMARY_FILE"] = workDirectory.appendingPathComponent("summary.txt").path
        environment["RUN_BOOT"] = "0"
        environment["START_IPROXY"] = "1"
        environment["SSH_HOST"] = "localhost"
        environment["SSH_PORT"] = "2222"
        environment["SSH_USER"] = "root"
        environment["SSH_PASS"] = "alpine"
        environment["DEVICE_ECID"] = identifier
        environment["YX_SAFE_OBLIT"] = "1"
        environment["RESTORE_TEMP_DIR"] = workRoot.path
        environment["TMPDIR"] = workRoot.path

        output("restoreFile resources decrypted and integrity verified")
        output("Using backup directory: \(inputDirectory.lastPathComponent)")
        output("Restoring files in -old mode")
        try await runProcess(
            executable: URL(fileURLWithPath: "/bin/bash"),
            arguments: [assets.scriptURL.path, "-old", inputDirectory.path],
            currentDirectory: assets.rootURL,
            environment: environment,
            output: output
        )
    }

    private static func makeRunID() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        return "\(formatter.string(from: Date()))_\(UUID().uuidString.prefix(8))"
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
            let state = RestoreFileProcessState(output: output)
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
                    continuation.resume(throwing: RestoreFileError.commandFailed(
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

private final class RestoreFileProcessState: @unchecked Sendable {
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
        return RestoreFileService.cleanTerminalText(collectedOutput)
    }

    func claimCompletion() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !completionClaimed else { return false }
        completionClaimed = true
        return true
    }

    private func emit(_ lines: [String]) {
        for line in lines {
            let clean = RestoreFileService.cleanTerminalText(line)
            if !clean.isEmpty { output(clean) }
        }
    }
}

enum RestoreFileError: LocalizedError {
    case missingResource(String)
    case missingDeviceIdentifier
    case wrongBackupDirectory
    case commandFailed(status: Int32, output: String)

    var errorDescription: String? {
        switch self {
        case let .missingResource(name): return "Missing restoreFile resource: \(name)"
        case .missingDeviceIdentifier: return "Could not obtain the device ECID, UDID, or serial number"
        case .wrongBackupDirectory: return "No extraction directory matching the current device identity was found"
        case let .commandFailed(status, output):
            let lastLine = output.split(whereSeparator: \.isNewline).map(String.init).last(where: { !$0.isEmpty })
                ?? "restore-noramdisk.sh execution failed"
            return "File restore failed (\(status)):\(lastLine)"
        }
    }
}
