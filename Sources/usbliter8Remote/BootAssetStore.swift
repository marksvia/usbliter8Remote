import CryptoKit
import Foundation

struct BootAssetStore: Sendable {
    func decryptedPatchedIBEC(for codename: String) throws -> DecryptedBootAsset {
        let encryptedURL = try encryptedAssetURL(for: codename)
        var payload = try Data(contentsOf: encryptedURL, options: .mappedIfSafe)

        // Encryption order is 1 -> 4. Decryption must unwind in reverse order.
        for layer in stride(from: BootAssetEncryption.layerCount, through: 1, by: -1) {
            let keyData = EmbeddedBootAssetKeys.keyData(for: layer)
            let sealedBox = try AES.GCM.SealedBox(combined: payload)
            payload = try AES.GCM.open(
                sealedBox,
                using: SymmetricKey(data: keyData),
                authenticating: BootAssetEncryption.authenticatedData(codename: codename, layer: layer)
            )
        }

        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(".yx-ba-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: temporaryDirectory.path)

        let outputURL = temporaryDirectory.appendingPathComponent(".\(UUID().uuidString)")
        try payload.write(to: outputURL, options: [.atomic, .completeFileProtection])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: outputURL.path)
        return DecryptedBootAsset(url: outputURL, temporaryDirectory: temporaryDirectory)
    }

    private func encryptedAssetURL(for codename: String) throws -> URL {
        guard let url = AppResourceLocator.resourceURL(
            name: "\(codename).ibec",
            extension: "enc",
            subdirectories: ["BootAssets", "Resources/BootAssets"]
        ) else {
            throw RestoreError.missingBootAsset
        }
        return url
    }
}

enum BootAssetEncryption {
    static let formatVersion = 2
    static let layerCount = 4
    static let keyByteCount = 32

    static func authenticatedData(codename: String, layer: Int) -> Data {
        Data("YXBA|v\(formatVersion)|\(codename)|layer:\(layer)".utf8)
    }
}

struct DecryptedBootAsset: Sendable {
    let url: URL
    let temporaryDirectory: URL

    func removeTemporaryFile() {
        try? FileManager.default.removeItem(at: temporaryDirectory)
    }
}
