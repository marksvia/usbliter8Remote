import Foundation

protocol RestoreServicing: Sendable {
    func erase(
        device: DetectedDevice,
        progress: @Sendable @escaping (RestoreStep) -> Void
    ) async throws
}

enum RestoreError: LocalizedError {
    case missingSupport
    case missingBootAsset
    case missingTool(String)
    case deviceNotPwndfu
    case commandFailed(step: RestoreStep, message: String)
    case recoveryTimeout
    case usbControlFailed(String)
    case needsRepwn(step: RestoreStep, message: String)

    var errorDescription: String? {
        switch self {
        case .missingSupport:
            return "Device not supported"
        case .missingBootAsset:
            return "Local BootAssets are missing. Add and encrypt your own iBEC resources before building."
        case let .missingTool(name):
            return "Missing tool \(name)"
        case .deviceNotPwndfu:
            return "Please put the device into PWNDFU"
        case let .commandFailed(_, message):
            return message.isEmpty ? "Command failed" : message
        case .recoveryTimeout:
            return "Timed out waiting for recovery mode"
        case let .usbControlFailed(message):
            return message
        case .needsRepwn:
            return "Please re-pwn"
        }
    }

    var failedStep: RestoreStep? {
        switch self {
        case let .needsRepwn(step, _):
            return step
        case .missingBootAsset, .missingTool, .deviceNotPwndfu:
            return .confirmPwndfu
        case let .commandFailed(step, _):
            return step
        case .usbControlFailed:
            return .sendErase
        case .recoveryTimeout:
            return .sendErase
        case .missingSupport:
            return .parseDevice
        }
    }
}

struct RestoreService: RestoreServicing {
    private let bootAssets = BootAssetStore()

    func erase(
        device: DetectedDevice,
        progress: @Sendable @escaping (RestoreStep) -> Void
    ) async throws {
        guard let support = device.support else {
            throw RestoreError.missingSupport
        }

        guard device.mode == .pwndfu else {
            throw RestoreError.deviceNotPwndfu
        }

        progress(.parseDevice)
        progress(.confirmPwndfu)

        let ibec = try bootAssets.decryptedPatchedIBEC(for: support.ibecCodename)
        defer { ibec.removeTemporaryFile() }
        let irecoveryURL = try AppResourceLocator.requiredToolURL(named: "irecovery")
        let usbliter8ctlURL = try AppResourceLocator.requiredToolURL(named: "usbliter8ctl")

        progress(.sendErase)
        do {
            try await CommandRunner.run(
                usbliter8ctlURL,
                arguments: ["boot", ibec.url.path],
                failedStep: .sendErase,
                environment: AppResourceLocator.pythonToolEnvironment()
            )
        } catch RestoreError.commandFailed(_, let output) where Usbliter8BootOutput.needsRepwn(output) {
            throw RestoreError.needsRepwn(step: .sendErase, message: output)
        }

        try await waitForRecovery(irecoveryURL: irecoveryURL)

        progress(.erasing)
        for command in ["setenv oblit-inprogress 5", "setenv auto-boot true", "saveenv", "reboot"] {
            try await CommandRunner.run(irecoveryURL, arguments: ["-c", command], allowFailureFor: command == "reboot", failedStep: .erasing)
        }

        progress(.completed)
    }

    private func waitForRecovery(irecoveryURL: URL) async throws {
        for _ in 0..<60 {
            let result = try? await CommandRunner.capture(irecoveryURL, arguments: ["-m"])
            if result?.localizedCaseInsensitiveContains("Recovery") == true {
                return
            }
            try await Task.sleep(nanoseconds: 1_000_000_000)
        }
        throw RestoreError.recoveryTimeout
    }
}

private enum CommandRunner {
    static func run(
        _ executableURL: URL,
        arguments: [String],
        allowFailureFor allowFailure: Bool = false,
        failedStep: RestoreStep,
        environment: [String: String]? = nil
    ) async throws {
        let result = try await execute(executableURL, arguments: arguments, environment: environment)
        if result.status != 0 && !allowFailure {
            throw RestoreError.commandFailed(step: failedStep, message: result.output)
        }
    }

    static func capture(_ executableURL: URL, arguments: [String]) async throws -> String {
        try await execute(executableURL, arguments: arguments, environment: nil).output
    }

    private static func execute(_ executableURL: URL, arguments: [String], environment: [String: String]?) async throws -> (status: Int32, output: String) {
        try await Task.detached {
            let process = Process()
            let pipe = Pipe()
            process.executableURL = executableURL
            process.arguments = arguments
            if let environment {
                process.environment = environment
            }
            process.standardOutput = pipe
            process.standardError = pipe

            try process.run()
            process.waitUntilExit()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
        }.value
    }
}

enum Usbliter8BootOutput {
    static func needsRepwn(_ output: String) -> Bool {
        let lowercased = output.lowercased()
        let hasPipeError = lowercased.contains("pipe error") || lowercased.contains("libusb_error_pipe")
        let hasUSBError = lowercased.contains("usb.core.usberror") || lowercased.contains("usberror")
        let hasNativeBootFailure = lowercased.contains("usberror:")
            && (lowercased.contains("dfu_dnload failed") || lowercased.contains("custom_boot failed"))
        return hasNativeBootFailure || (hasPipeError && (hasUSBError || lowercased.contains("errno 32") || lowercased.contains("[errno 32]")))
    }
}
