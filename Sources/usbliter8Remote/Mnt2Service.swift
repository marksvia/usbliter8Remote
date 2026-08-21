import Foundation

struct Mnt2Service: Sendable {
    func mountOld(output: @Sendable @escaping (String) -> Void) async throws {
        guard let manifestURL = AppResourceLocator.resourceURL(
            name: "manifest",
            extension: "json",
            subdirectories: ["Mnt2/payload", "Resources/Mnt2/payload"]
        ) else {
            throw Mnt2Error.missingResource("payload/manifest.json")
        }

        guard let iproxyURL = AppResourceLocator.toolURL(named: "iproxy") else {
            throw Mnt2Error.missingResource("iproxy")
        }

        output("Decrypting mnt2 resources…")
        let payloadDirectory = manifestURL.deletingLastPathComponent()
        let assets = try await Task.detached(priority: .userInitiated) {
            try RamdiskAssetStore().materialize(payloadDirectory: payloadDirectory)
        }.value
        defer { assets.removeTemporaryFiles() }

        let mountHelper = assets.extractedURL.appendingPathComponent("remote_mount_old.sh")
        guard FileManager.default.fileExists(atPath: mountHelper.path) else {
            throw Mnt2Error.missingResource("remote_mount_old.sh")
        }

        let workRoot = assets.rootURL.appendingPathComponent(".mnt2-work", isDirectory: true)
        try FileManager.default.createDirectory(at: workRoot, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: workRoot.path)

        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        environment["LC_ALL"] = "C"
        environment["LANG"] = "C"
        environment["ROOT"] = assets.rootURL.path
        environment["TOOLS_DIR"] = assets.extractedURL.path
        environment["APP_IPROXY"] = iproxyURL.path
        environment["MNT2_TEMP_DIR"] = workRoot.path
        environment["TMPDIR"] = workRoot.path
        environment["SSH_HOST"] = "localhost"
        environment["SSH_PORT"] = "2222"
        environment["SSH_USER"] = "root"
        environment["SSH_PASS"] = "alpine"
        environment["START_IPROXY"] = "1"

        output("mnt2 resources decrypted and integrity verified")
        output("Mounting /mnt2 using -old mode")
        try await runProcess(
            executable: URL(fileURLWithPath: "/bin/bash"),
            arguments: [assets.scriptURL.path, "-old"],
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
            let state = Mnt2ProcessState(output: output)

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
                    continuation.resume(throwing: Mnt2Error.commandFailed(
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

private final class Mnt2ProcessState: @unchecked Sendable {
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
        return Mnt2Service.cleanTerminalText(collectedOutput)
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
            let clean = Mnt2Service.cleanTerminalText(line)
            if !clean.isEmpty { output(clean) }
        }
    }
}

enum Mnt2Error: LocalizedError {
    case missingResource(String)
    case commandFailed(status: Int32, output: String)

    var errorDescription: String? {
        switch self {
        case let .missingResource(name):
            return "Missing mnt2 resource: \(name)"
        case let .commandFailed(status, output):
            let lastLine = output
                .split(whereSeparator: \.isNewline)
                .map(String.init)
                .last(where: { !$0.isEmpty }) ?? "mnt2.sh execution failed"
            return "mnt2 mount failed (\(status)):\(lastLine)"
        }
    }
}
