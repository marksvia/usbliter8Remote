#!/usr/bin/env swift
import CryptoKit
import Foundation
import Security

let service = "com.yx.deviceutility.boot-assets.v2"
let layerCount = 4
let keyByteCount = 32
let formatVersion = 2

enum ToolError: LocalizedError {
    case usage
    case keychain(OSStatus)
    case missingKey(Int)
    case invalidKey(Int)
    case invalidAssetName(String)
    case invalidBackup(String)
    case outputExists(String)
    case dataProtectionUnavailable

    var errorDescription: String? {
        switch self {
        case .usage: return "usage: boot_asset_crypto.swift init-keys | export-keys OUTPUT.txt | import-keys INPUT.txt | purge-legacy-keys | encrypt INPUT OUTPUT CODENAME | verify ASSET_DIR"
        case let .keychain(status): return "Keychain error: \(status)"
        case let .missingKey(layer): return "Missing local key layer \(layer); run init-keys first"
        case let .invalidKey(layer): return "Invalid local key layer \(layer)"
        case let .invalidAssetName(name): return "Expected CODENAME.ibec.enc, got \(name)"
        case let .invalidBackup(message): return "Invalid key backup: \(message)"
        case let .outputExists(path): return "Backup output already exists: \(path)"
        case .dataProtectionUnavailable: return "Data Protection Keychain is unavailable for this unsigned/ad-hoc tool; standard macOS Keychain remains active"
        }
    }
}


struct KeyBackup: Codable {
    struct Layer: Codable {
        let layer: Int
        let keyBase64: String
    }

    let format: String
    let version: Int
    let keychainService: String
    let createdAt: String
    let layers: [Layer]
    let checksumSHA256: String
}

func backupChecksum(_ keys: [Data]) -> String {
    let joined = keys.reduce(into: Data()) { $0.append($1) }
    return SHA256.hash(data: joined).map { String(format: "%02x", $0) }.joined()
}

func exportKeys(to output: URL) throws {
    guard !FileManager.default.fileExists(atPath: output.path) else {
        throw ToolError.outputExists(output.path)
    }
    let keys = try (1...layerCount).map(readKey)
    let backup = KeyBackup(
        format: "YXDeviceUtilityBootAssetKeys",
        version: formatVersion,
        keychainService: service,
        createdAt: ISO8601DateFormatter().string(from: Date()),
        layers: zip(1...layerCount, keys).map { KeyBackup.Layer(layer: $0.0, keyBase64: $0.1.base64EncodedString()) },
        checksumSHA256: backupChecksum(keys)
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    let data = try encoder.encode(backup)
    try data.write(to: output, options: [.atomic, .completeFileProtection])
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: output.path)
}

func keyIdentity(_ layer: Int, dataProtection: Bool) -> [String: Any] {
    var identity: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecAttrAccount as String: account(layer)
    ]
    if dataProtection {
        identity[kSecUseDataProtectionKeychain as String] = true
    }
    return identity
}

func storeKeyInDomain(_ data: Data, layer: Int, dataProtection: Bool) -> OSStatus {
    let identity = keyIdentity(layer, dataProtection: dataProtection)
    let update: [String: Any] = [
        kSecValueData as String: data,
        kSecAttrLabel as String: "YX Device Utility boot asset key layer \(layer)"
    ]
    let status = SecItemUpdate(identity as CFDictionary, update as CFDictionary)
    if status != errSecItemNotFound { return status }

    var add = identity
    update.forEach { add[$0.key] = $0.value }
    add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
    return SecItemAdd(add as CFDictionary, nil)
}

func storeKey(_ data: Data, layer: Int) throws {
    guard data.count == keyByteCount else { throw ToolError.invalidBackup("layer \(layer) is not 32 bytes") }
    let protectedStatus = storeKeyInDomain(data, layer: layer, dataProtection: true)
    if protectedStatus == errSecSuccess { return }
    if protectedStatus != errSecMissingEntitlement {
        throw ToolError.keychain(protectedStatus)
    }

    let compatibleStatus = storeKeyInDomain(data, layer: layer, dataProtection: false)
    guard compatibleStatus == errSecSuccess else { throw ToolError.keychain(compatibleStatus) }
}

func backupData(from input: URL) throws -> Data {
    let data = try Data(contentsOf: input)
    if (try? JSONDecoder().decode(KeyBackup.self, from: data)) != nil {
        return data
    }
    guard let text = String(data: data, encoding: .utf8),
          let opening = text.range(of: "```json"),
          let contentStart = text[opening.upperBound...].firstIndex(of: "\n"),
          let closing = text.range(of: "```", range: contentStart..<text.endIndex) else {
        throw ToolError.invalidBackup("JSON document or fenced JSON key block not found")
    }
    return Data(text[text.index(after: contentStart)..<closing.lowerBound].utf8)
}

func importKeys(from input: URL) throws {
    let backup = try JSONDecoder().decode(KeyBackup.self, from: backupData(from: input))
    guard backup.format == "YXDeviceUtilityBootAssetKeys" else { throw ToolError.invalidBackup("format mismatch") }
    guard backup.version == formatVersion else { throw ToolError.invalidBackup("version mismatch") }
    guard backup.keychainService == service else { throw ToolError.invalidBackup("service mismatch") }
    guard backup.layers.count == layerCount else { throw ToolError.invalidBackup("expected \(layerCount) layers") }
    let ordered = backup.layers.sorted { $0.layer < $1.layer }
    guard ordered.map(\.layer) == Array(1...layerCount) else { throw ToolError.invalidBackup("layer indexes mismatch") }
    let keys = try ordered.map { layer -> Data in
        guard let data = Data(base64Encoded: layer.keyBase64) else { throw ToolError.invalidBackup("invalid Base64 at layer \(layer.layer)") }
        guard data.count == keyByteCount else { throw ToolError.invalidBackup("invalid key size at layer \(layer.layer)") }
        return data
    }
    guard backupChecksum(keys) == backup.checksumSHA256.lowercased() else { throw ToolError.invalidBackup("checksum mismatch") }
    for (index, key) in keys.enumerated() { try storeKey(key, layer: index + 1) }
}

func account(_ layer: Int) -> String { "boot-asset-layer-\(layer)" }
func aad(_ codename: String, _ layer: Int) -> Data {
    Data("YXBA|v\(formatVersion)|\(codename)|layer:\(layer)".utf8)
}

func copyKey(_ layer: Int, dataProtection: Bool) -> (OSStatus, Data?) {
    var query = keyIdentity(layer, dataProtection: dataProtection)
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    return (status, result as? Data)
}

func readKey(_ layer: Int) throws -> Data {
    let protected = copyKey(layer, dataProtection: true)
    if protected.0 == errSecSuccess, let data = protected.1 {
        guard data.count == keyByteCount else { throw ToolError.invalidKey(layer) }
        return data
    }
    guard protected.0 == errSecItemNotFound || protected.0 == errSecMissingEntitlement else {
        throw ToolError.keychain(protected.0)
    }

    let compatible = copyKey(layer, dataProtection: false)
    if compatible.0 == errSecItemNotFound { throw ToolError.missingKey(layer) }
    guard compatible.0 == errSecSuccess, let data = compatible.1 else { throw ToolError.keychain(compatible.0) }
    guard data.count == keyByteCount else { throw ToolError.invalidKey(layer) }
    return data
}

func createKeyIfNeeded(_ layer: Int) throws -> Data {
    if let existing = try? readKey(layer) { return existing }
    var data = Data(count: keyByteCount)
    let randomStatus = data.withUnsafeMutableBytes {
        SecRandomCopyBytes(kSecRandomDefault, keyByteCount, $0.baseAddress!)
    }
    guard randomStatus == errSecSuccess else { throw ToolError.keychain(randomStatus) }
    try storeKey(data, layer: layer)
    return data
}

func purgeLegacyKeys() throws {
    for layer in 1...layerCount {
        let protected = copyKey(layer, dataProtection: true)
        guard protected.0 == errSecSuccess, protected.1?.count == keyByteCount else {
            throw ToolError.dataProtectionUnavailable
        }
    }
    for layer in 1...layerCount {
        let status = SecItemDelete(keyIdentity(layer, dataProtection: false) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw ToolError.keychain(status)
        }
    }
}

func encrypt(_ plaintext: Data, codename: String) throws -> Data {
    var payload = plaintext
    for layer in 1...layerCount {
        let key = SymmetricKey(data: try readKey(layer))
        let box = try AES.GCM.seal(payload, using: key, authenticating: aad(codename, layer))
        guard let combined = box.combined else { throw CocoaError(.coderInvalidValue) }
        payload = combined
    }
    return payload
}

func decrypt(_ ciphertext: Data, codename: String) throws -> Data {
    var payload = ciphertext
    for layer in stride(from: layerCount, through: 1, by: -1) {
        let box = try AES.GCM.SealedBox(combined: payload)
        payload = try AES.GCM.open(box, using: SymmetricKey(data: try readKey(layer)), authenticating: aad(codename, layer))
    }
    return payload
}

func codename(from url: URL) throws -> String {
    let suffix = ".ibec.enc"
    guard url.lastPathComponent.hasSuffix(suffix) else { throw ToolError.invalidAssetName(url.lastPathComponent) }
    return String(url.lastPathComponent.dropLast(suffix.count))
}

func fingerprint(_ data: Data) -> String {
    SHA256.hash(data: data).prefix(6).map { String(format: "%02x", $0) }.joined()
}

do {
    let args = CommandLine.arguments
    guard args.count >= 2 else { throw ToolError.usage }
    switch args[1] {
    case "init-keys":
        for layer in 1...layerCount {
            let key = try createKeyIfNeeded(layer)
            print("layer \(layer): ready fingerprint=\(fingerprint(key))")
        }
    case "export-keys":
        guard args.count == 3 else { throw ToolError.usage }
        let output = URL(fileURLWithPath: args[2])
        try exportKeys(to: output)
        print("exported 4 local keys to \(output.path) with mode 0600")
    case "import-keys":
        guard args.count == 3 else { throw ToolError.usage }
        let input = URL(fileURLWithPath: args[2])
        try importKeys(from: input)
        print("imported and verified 4 local keys into this Mac Keychain")
    case "purge-legacy-keys":
        guard args.count == 2 else { throw ToolError.usage }
        try purgeLegacyKeys()
        print("removed legacy compatibility-keychain copies; Data Protection Keychain keys are unchanged")
    case "encrypt":
        guard args.count == 5 else { throw ToolError.usage }
        let input = URL(fileURLWithPath: args[2])
        let output = URL(fileURLWithPath: args[3])
        let codename = args[4]
        let ciphertext = try encrypt(Data(contentsOf: input, options: .mappedIfSafe), codename: codename)
        try ciphertext.write(to: output, options: .atomic)
        print("encrypted \(codename): \(ciphertext.count) bytes")
    case "verify":
        guard args.count == 3 else { throw ToolError.usage }
        let directory = URL(fileURLWithPath: args[2], isDirectory: true)
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasSuffix(".ibec.enc") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        for file in files {
            let name = try codename(from: file)
            let plaintext = try decrypt(Data(contentsOf: file, options: .mappedIfSafe), codename: name)
            print("\(name): verified size=\(plaintext.count) sha256=\(fingerprint(plaintext))")
        }
        print("verified=\(files.count)")
    default:
        throw ToolError.usage
    }
} catch {
    FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
    exit(1)
}
