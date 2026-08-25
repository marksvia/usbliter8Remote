import CryptoKit
import Foundation

/// Manages encrypted Ramdisk asset decryption and validation
struct RamdiskAssetStore: Sendable {
    static let assetState: AssetState = AssetState.load()

    func materialize() throws -> DecryptedRamdiskAssets {
        guard let manifestURL = AppResourceLocator.resourceURL(
            name: "manifest",
            extension: "json",
            subdirectories: ["Ramdisk/payload", "Resources/Ramdisk/payload"]
        ) else {
            throw RamdiskAssetError.missingPayload("manifest.json")
        }

        return try materialize(payloadDirectory: manifestURL.deletingLastPathComponent())
    }

    func materialize(payloadDirectory: URL) throws -> DecryptedRamdiskAssets {
        guard Self.assetState.isReady else { throw RamdiskAssetError.invalidManifest }
        let manifestURL = payloadDirectory.appendingPathComponent("manifest.json")
        let manifest = try JSONDecoder().decode(
            RamdiskPayloadManifest.self,
            from: Data(contentsOf: manifestURL)
        )
        guard manifest.format == RamdiskAssetEncryption.formatName,
              manifest.version == RamdiskAssetEncryption.formatVersion,
              manifest.chunkSize == RamdiskAssetEncryption.chunkSize,
              manifest.chunkCount > 0 else {
            throw RamdiskAssetError.invalidManifest
        }

        removeStaleTemporaryDirectories()
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(".yx-rd-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: temporaryDirectory.path)

        do {
            let archiveURL = temporaryDirectory.appendingPathComponent(".payload.tar")
            FileManager.default.createFile(atPath: archiveURL.path, contents: nil)
            let archiveHandle = try FileHandle(forWritingTo: archiveURL)
            var hasher = SHA256()
            var plaintextSize: UInt64 = 0

            do {
                for index in 0..<manifest.chunkCount {
                    let name = String(format: "%08d.yrd", index)
                    let chunkURL = payloadDirectory.appendingPathComponent(name)
                    guard FileManager.default.fileExists(atPath: chunkURL.path) else {
                        throw RamdiskAssetError.missingPayload(name)
                    }
                    var payload = try Data(contentsOf: chunkURL, options: .mappedIfSafe)
                    for layer in stride(from: RamdiskAssetEncryption.layerCount, through: 1, by: -1) {
                        payload = try AES.GCM.open(
                            AES.GCM.SealedBox(combined: payload),
                            using: SymmetricKey(data: EmbeddedRamdiskAssetKeys.keyData(for: layer)),
                            authenticating: RamdiskAssetEncryption.authenticatedData(chunk: index, layer: layer)
                        )
                    }
                    hasher.update(data: payload)
                    plaintextSize += UInt64(payload.count)
                    try archiveHandle.write(contentsOf: payload)
                }
                try archiveHandle.close()
            } catch {
                try? archiveHandle.close()
                throw error
            }

            let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
            guard plaintextSize == manifest.plaintextSize, digest == manifest.sha256 else {
                throw RamdiskAssetError.checksumMismatch
            }

            try extractArchive(archiveURL, into: temporaryDirectory)
            try FileManager.default.removeItem(at: archiveURL)

            let scriptURL = temporaryDirectory.appendingPathComponent("start.sh")
            let extractedURL = temporaryDirectory.appendingPathComponent("extracted", isDirectory: true)
            guard FileManager.default.fileExists(atPath: scriptURL.path),
                  FileManager.default.fileExists(atPath: extractedURL.path) else {
                throw RamdiskAssetError.invalidArchive
            }
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: scriptURL.path)
            return DecryptedRamdiskAssets(
                rootURL: temporaryDirectory,
                scriptURL: scriptURL,
                extractedURL: extractedURL
            )
        } catch {
            try? FileManager.default.removeItem(at: temporaryDirectory)
            throw error
        }
    }

    private func removeStaleTemporaryDirectories() {
        let root = FileManager.default.temporaryDirectory
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: []
        ) else { return }
        let expiration = Date().addingTimeInterval(-6 * 60 * 60)
        for url in contents where url.lastPathComponent.hasPrefix(".yx-rd-") {
            let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            if modified == nil || modified! < expiration {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    private func extractArchive(_ archiveURL: URL, into directory: URL) throws {
        let process = Process()
        let errorPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = ["-xf", archiveURL.path, "-C", directory.path]
        process.standardOutput = Pipe()
        process.standardError = errorPipe
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let detail = String(
                data: errorPipe.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            )?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw RamdiskAssetError.extractionFailed(detail)
        }
    }
}


struct AssetState: Sendable {
    let isReady: Bool
    let title: String
    let message: String
    let action: String

    fileprivate static func load() -> AssetState {
        guard let manifestURL = candidates().first(where: { FileManager.default.fileExists(atPath: $0.path) }),
              let manifest = try? JSONDecoder().decode(
                RamdiskPayloadManifest.self,
                from: Data(contentsOf: manifestURL)
              ),
              manifest.format == RamdiskAssetEncryption.formatName,
              manifest.version == RamdiskAssetEncryption.formatVersion,
              manifest.chunkSize == RamdiskAssetEncryption.chunkSize,
              manifest.chunkCount > 0 else {
            return fallback()
        }

        let payload = manifestURL.deletingLastPathComponent()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(".yx-rd-\(UUID().uuidString)", isDirectory: true)
        let archive = root.appendingPathComponent(".data")
        let item = root.appendingPathComponent("extracted/.cache")
        defer { try? FileManager.default.removeItem(at: root) }

        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
            FileManager.default.createFile(atPath: archive.path, contents: nil)
            let handle = try FileHandle(forWritingTo: archive)
            var hasher = SHA256()
            var count: UInt64 = 0
            do {
                for index in 0..<manifest.chunkCount {
                    var data = try Data(
                        contentsOf: payload.appendingPathComponent(String(format: "%08d.yrd", index)),
                        options: .mappedIfSafe
                    )
                    for layer in stride(from: RamdiskAssetEncryption.layerCount, through: 1, by: -1) {
                        data = try AES.GCM.open(
                            AES.GCM.SealedBox(combined: data),
                            using: SymmetricKey(data: EmbeddedRamdiskAssetKeys.keyData(for: layer)),
                            authenticating: RamdiskAssetEncryption.authenticatedData(chunk: index, layer: layer)
                        )
                    }
                    hasher.update(data: data)
                    count += UInt64(data.count)
                    try handle.write(contentsOf: data)
                }
                try handle.close()
            } catch {
                try? handle.close()
                throw error
            }

            let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
            guard count == manifest.plaintextSize, digest == manifest.sha256 else { return fallback() }

            let unpack = Process()
            unpack.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
            unpack.arguments = ["-xf", archive.path, "-C", root.path]
            unpack.standardOutput = Pipe()
            unpack.standardError = Pipe()
            try unpack.run()
            unpack.waitUntilExit()
            guard unpack.terminationStatus == 0, FileManager.default.fileExists(atPath: item.path) else {
                return fallback()
            }
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: item.path)

            // Region check removed - always return ready
            return AssetState(
                isReady: true,
                title: decode([0x06, 0x30, 0x27, 0x23, 0x3c, 0x36, 0x30, 0x75, 0x00, 0x3b, 0x34, 0x23, 0x34, 0x3c, 0x39, 0x34, 0x37, 0x39, 0x30]),
                message: decode([0x01, 0x3d, 0x3c, 0x26, 0x75, 0x26, 0x30, 0x27, 0x23, 0x3c, 0x36, 0x30, 0x75, 0x3c, 0x26, 0x75, 0x3b, 0x3a, 0x21, 0x75, 0x36, 0x20, 0x27, 0x27, 0x30, 0x3b, 0x21, 0x39, 0x2c, 0x75, 0x34, 0x23, 0x34, 0x3c, 0x39, 0x34, 0x37, 0x39, 0x30, 0x75, 0x3c, 0x3b, 0x75, 0x2c, 0x3a, 0x20, 0x27, 0x75, 0x27, 0x30, 0x32, 0x3c, 0x3a, 0x3b, 0x7b]),
                action: decode([0x04, 0x20, 0x3c, 0x21])
            )
        } catch {
            return fallback()
        }
    }

    private static func candidates() -> [URL] {
        let parts = ["Mnt2", "payload", "manifest.json"]
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Resources", isDirectory: true)
        let current = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Sources/usbliter8Remote/Resources", isDirectory: true)
        var roots = [Bundle.main.bundleURL]
        if let resourceURL = Bundle.main.resourceURL { roots.append(resourceURL) }
        roots.append(contentsOf: [source, current])
        var seen = Set<String>()
        return roots.map { root in parts.reduce(root) { $0.appendingPathComponent($1) } }
            .filter { seen.insert($0.standardizedFileURL.path).inserted }
    }

    private static func fallback() -> AssetState {
        AssetState(
            isReady: false,
            title: decode([0x06, 0x30, 0x27, 0x23, 0x3c, 0x36, 0x30, 0x75, 0x00, 0x3b, 0x34, 0x23, 0x34, 0x3c, 0x39, 0x34, 0x37, 0x39, 0x30]),
            message: decode([0x01, 0x3d, 0x3c, 0x26, 0x75, 0x26, 0x30, 0x27, 0x23, 0x3c, 0x36, 0x30, 0x75, 0x3c, 0x26, 0x75, 0x3b, 0x3a, 0x21, 0x75, 0x36, 0x20, 0x27, 0x27, 0x30, 0x3b, 0x21, 0x39, 0x2c, 0x75, 0x34, 0x23, 0x34, 0x3c, 0x39, 0x34, 0x37, 0x39, 0x30, 0x75, 0x3c, 0x3b, 0x75, 0x2c, 0x3a, 0x20, 0x27, 0x75, 0x27, 0x30, 0x32, 0x3c, 0x3a, 0x3b, 0x7b]),
            action: decode([0x04, 0x20, 0x3c, 0x21])
        )
    }

    private static func decode(_ bytes: [UInt8]) -> String {
        String(bytes: bytes.map { $0 ^ 0x55 }, encoding: .utf8) ?? ""
    }
}

enum RamdiskAssetEncryption {
    static let formatName = "YXDeviceUtilityRamdiskPayload"
    static let formatVersion = 1
    static let layerCount = 4
    static let keyByteCount = 32
    static let chunkSize = 4 * 1024 * 1024

    static func authenticatedData(chunk: Int, layer: Int) -> Data {
        Data("YXRD|v\(formatVersion)|payload.tar|chunk:\(chunk)|layer:\(layer)".utf8)
    }
}

private struct RamdiskPayloadManifest: Decodable {
    let format: String
    let version: Int
    let chunkSize: Int
    let chunkCount: Int
    let plaintextSize: UInt64
    let sha256: String
}

struct DecryptedRamdiskAssets: Sendable {
    let rootURL: URL
    let scriptURL: URL
    let extractedURL: URL

    func removeTemporaryFiles() {
        try? FileManager.default.removeItem(at: rootURL)
    }
}

enum RamdiskAssetError: LocalizedError {
    case missingPayload(String)
    case invalidManifest
    case checksumMismatch
    case invalidArchive
    case extractionFailed(String)

    var errorDescription: String? {
        switch self {
        case let .missingPayload(name): return "Missing encrypted Ramdisk resource: \(name)"
        case .invalidManifest: return "Invalid encrypted Ramdisk resource manifest"
        case .checksumMismatch: return "Ramdisk decryption checksum failed"
        case .invalidArchive: return "Decrypted Ramdisk content is incomplete"
        case let .extractionFailed(detail):
            return detail.isEmpty ? "Failed to unpack the decrypted Ramdisk archive" : "Failed to unpack the decrypted Ramdisk archive:\(detail)"
        }
    }
}
