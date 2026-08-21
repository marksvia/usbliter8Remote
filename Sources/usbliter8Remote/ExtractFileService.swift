import Foundation

struct ExtractFileResult: Sendable {
    let outputDirectoryURL: URL
    let zipURL: URL?
}

struct ExtractFileService: Sendable {
    func extractOld(
        deviceIdentifier: String,
        output: @Sendable @escaping (String) -> Void
    ) async throws -> ExtractFileResult {
        guard let manifestURL = AppResourceLocator.resourceURL(
            name: "manifest",
            extension: "json",
            subdirectories: ["ExtractFile/payload", "Resources/ExtractFile/payload"]
        ) else {
            throw ExtractFileError.missingResource("payload/manifest.json")
        }

        guard let iproxyURL = AppResourceLocator.toolURL(named: "iproxy") else {
            throw ExtractFileError.missingResource("iproxy")
        }
        guard let desktopURL = FileManager.default.urls(
            for: .desktopDirectory,
            in: .userDomainMask
        ).first else {
            throw ExtractFileError.desktopUnavailable
        }

        try FileManager.default.createDirectory(at: desktopURL, withIntermediateDirectories: true)
        let identifier = Self.sanitizedIdentifier(deviceIdentifier)
        guard !identifier.isEmpty else { throw ExtractFileError.missingDeviceIdentifier }
        let runID = Self.makeRunID()
        let outputName = "Backup_Tickets_\(identifier)_\(runID)"
        let outputDirectory = desktopURL.appendingPathComponent(outputName, isDirectory: true)

        output("Decrypting extractFile resources…")
        let payloadDirectory = manifestURL.deletingLastPathComponent()
        let assets = try await Task.detached(priority: .userInitiated) {
            try RamdiskAssetStore().materialize(payloadDirectory: payloadDirectory)
        }.value
        defer { assets.removeTemporaryFiles() }

        for required in [
            assets.extractedURL.appendingPathComponent("remote_mount_old.sh"),
            assets.extractedURL.appendingPathComponent("disabled.plist"),
            assets.extractedURL.appendingPathComponent("com.apple.purplebuddy.plist")
        ] where !FileManager.default.fileExists(atPath: required.path) {
            throw ExtractFileError.missingResource(required.lastPathComponent)
        }

        let workRoot = assets.rootURL.appendingPathComponent(".extract-work", isDirectory: true)
        try FileManager.default.createDirectory(at: workRoot, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: workRoot.path)

        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        environment["LC_ALL"] = "C"
        environment["LANG"] = "C"
        environment["ROOT"] = assets.rootURL.path
        environment["TEST"] = assets.rootURL.path
        environment["TOOLS_DIR"] = assets.extractedURL.path
        environment["APP_IPROXY"] = iproxyURL.path
        environment["OUT_ROOT"] = desktopURL.path
        environment["OUT_DIR"] = outputDirectory.path
        environment["LOG_FILE"] = outputDirectory.appendingPathComponent("give.log").path
        environment["RUN_ID"] = runID
        environment["DEVICE_ECID"] = identifier
        environment["RUN_BOOT"] = "0"
        environment["START_IPROXY"] = "1"
        environment["SSH_HOST"] = "localhost"
        environment["SSH_PORT"] = "2222"
        environment["SSH_USER"] = "root"
        environment["SSH_PASS"] = "alpine"
        environment["YX_MOUNT_MODE"] = "optimized"
        environment["EXTRACT_TEMP_DIR"] = workRoot.path
        environment["TMPDIR"] = workRoot.path

        output("extractFile resources decrypted and integrity verified")
        output("Extracting files from SSH Ramdisk in -old mode")
        try await runProcess(
            executable: URL(fileURLWithPath: "/bin/bash"),
            arguments: [assets.scriptURL.path, "-old"],
            currentDirectory: assets.rootURL,
            environment: environment,
            output: output
        )

        let zipURL = try FileManager.default.contentsOfDirectory(
            at: desktopURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ).first {
            $0.pathExtension.lowercased() == "zip"
                && $0.lastPathComponent.hasPrefix("Backup_Tickets_")
                && $0.lastPathComponent.contains(runID)
        }
        return ExtractFileResult(outputDirectoryURL: outputDirectory, zipURL: zipURL)
    }

    private static func sanitizedIdentifier(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_") )
        let scalars = value.uppercased().unicodeScalars.filter { allowed.contains($0) }
        return String(String.UnicodeScalarView(scalars)).prefix(64).description
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
            let state = ExtractFileProcessState(output: output)

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
                if terminatedProcess.terminationStatus == 0 {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: ExtractFileError.commandFailed(
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

private final class ExtractFileProcessState: @unchecked Sendable {
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
        return ExtractFileService.cleanTerminalText(collectedOutput)
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
            let clean = ExtractFileService.cleanTerminalText(line)
            if !clean.isEmpty { output(clean) }
        }
    }
}

enum ExtractFileError: LocalizedError {
    case missingResource(String)
    case desktopUnavailable
    case missingDeviceIdentifier
    case commandFailed(status: Int32, output: String)

    var errorDescription: String? {
        switch self {
        case let .missingResource(name):
            return "Missing extractFile resource: \(name)"
        case .desktopUnavailable:
            return "The current user's Desktop directory was not found"
        case .missingDeviceIdentifier:
            return "Could not obtain the device ECID, UDID, or serial number"
        case let .commandFailed(status, output):
            let lastLine = output
                .split(whereSeparator: \.isNewline)
                .map(String.init)
                .last(where: { !$0.isEmpty }) ?? "give-noramdisk.sh execution failed"
            return "File extraction failed (\(status)):\(lastLine)"
        }
    }
}
