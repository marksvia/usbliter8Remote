#!/usr/bin/env swift
import CryptoKit
import Foundation

private let formatName = "YXDeviceUtilityRamdiskPayload"
private let keyFormatName = "YXDeviceUtilityRamdiskKeys"
private let formatVersion = 1
private let layerCount = 4
private let chunkSize = 4 * 1024 * 1024
private let keyBegin = "<!-- RAMDISK_KEYS_JSON_BEGIN -->"
private let keyEnd = "<!-- RAMDISK_KEYS_JSON_END -->"

struct KeyBackup: Decodable {
    struct Layer: Decodable { let layer: Int; let keyBase64: String }
    let format: String
    let version: Int
    let layers: [Layer]
}

struct PayloadManifest: Codable {
    let format: String
    let version: Int
    let chunkSize: Int
    let chunkCount: Int
    let plaintextSize: UInt64
    let sha256: String
    let entries: [String]
}

enum CryptoToolError: LocalizedError {
    case usage
    case invalidKeyDocument
    case invalidKey(Int)
    case invalidManifest
    case commandFailed(String)
    case checksumMismatch

    var errorDescription: String? {
        switch self {
        case .usage:
            return "Usage: ramdisk_asset_crypto.swift encrypt <Ramdisk source> <payload output> <key.md> | verify <payload> <key.md>"
        case .invalidKeyDocument: return "Ramdisk key block is missing or invalid"
        case let .invalidKey(layer): return "Invalid Ramdisk key for layer \(layer)"
        case .invalidManifest: return "Invalid Ramdisk payload manifest"
        case let .commandFailed(message): return message
        case .checksumMismatch: return "Decrypted Ramdisk payload checksum mismatch"
        }
    }
}

func keys(from markdownURL: URL) throws -> [Data] {
    let markdown = try String(contentsOf: markdownURL, encoding: .utf8)
    guard let begin = markdown.range(of: keyBegin),
          let end = markdown.range(of: keyEnd),
          begin.upperBound <= end.lowerBound else { throw CryptoToolError.invalidKeyDocument }
    let jsonText = markdown[begin.upperBound..<end.lowerBound]
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .replacingOccurrences(of: "```json", with: "")
        .replacingOccurrences(of: "```", with: "")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    let backup = try JSONDecoder().decode(KeyBackup.self, from: Data(jsonText.utf8))
    guard backup.format == keyFormatName, backup.version == formatVersion else {
        throw CryptoToolError.invalidKeyDocument
    }
    let indexed = Dictionary(uniqueKeysWithValues: backup.layers.map { ($0.layer, $0.keyBase64) })
    return try (1...layerCount).map { layer in
        guard let encoded = indexed[layer], let data = Data(base64Encoded: encoded), data.count == 32 else {
            throw CryptoToolError.invalidKey(layer)
        }
        return data
    }
}

func aad(chunk: Int, layer: Int) -> Data {
    Data("YXRD|v\(formatVersion)|payload.tar|chunk:\(chunk)|layer:\(layer)".utf8)
}

func encryptChunk(_ plaintext: Data, index: Int, keys: [Data]) throws -> Data {
    var payload = plaintext
    for layer in 1...layerCount {
        let sealed = try AES.GCM.seal(
            payload,
            using: SymmetricKey(data: keys[layer - 1]),
            authenticating: aad(chunk: index, layer: layer)
        )
        guard let combined = sealed.combined else { throw CocoaError(.coderInvalidValue) }
        payload = combined
    }
    return payload
}

func decryptChunk(_ ciphertext: Data, index: Int, keys: [Data]) throws -> Data {
    var payload = ciphertext
    for layer in stride(from: layerCount, through: 1, by: -1) {
        payload = try AES.GCM.open(
            AES.GCM.SealedBox(combined: payload),
            using: SymmetricKey(data: keys[layer - 1]),
            authenticating: aad(chunk: index, layer: layer)
        )
    }
    return payload
}

func run(_ executable: String, _ arguments: [String]) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    let errorPipe = Pipe()
    process.standardError = errorPipe
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        let message = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        throw CryptoToolError.commandFailed(message.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

func hexDigest(_ digest: SHA256.Digest) -> String {
    digest.map { String(format: "%02x", $0) }.joined()
}

func createArchive(sourceRoot: URL, output: URL) throws {
    let required = ["start.sh", "extracted"]
    for item in required where !FileManager.default.fileExists(atPath: sourceRoot.appendingPathComponent(item).path) {
        throw CryptoToolError.commandFailed("Missing Ramdisk source item: \(item)")
    }
    try run("/usr/bin/tar", [
        "-cf", output.path,
        "--exclude=.DS_Store",
        "-C", sourceRoot.path,
        "start.sh", "extracted"
    ])
}

func encryptTree(sourceRoot: URL, outputRoot: URL, keyURL: URL) throws {
    let encryptionKeys = try keys(from: keyURL)
    let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("yx-rd-pack-\(UUID().uuidString).tar")
    defer { try? FileManager.default.removeItem(at: temporary) }
    try createArchive(sourceRoot: sourceRoot, output: temporary)

    try? FileManager.default.removeItem(at: outputRoot)
    try FileManager.default.createDirectory(at: outputRoot, withIntermediateDirectories: true)
    let input = try FileHandle(forReadingFrom: temporary)
    defer { try? input.close() }

    var index = 0
    var plaintextSize: UInt64 = 0
    var hasher = SHA256()
    while true {
        let data = try input.read(upToCount: chunkSize) ?? Data()
        if data.isEmpty { break }
        hasher.update(data: data)
        plaintextSize += UInt64(data.count)
        let encrypted = try encryptChunk(data, index: index, keys: encryptionKeys)
        let name = String(format: "%08d.yrd", index)
        try encrypted.write(to: outputRoot.appendingPathComponent(name), options: .atomic)
        index += 1
        if index % 50 == 0 { print("encrypted chunks=\(index)") }
    }

    let manifest = PayloadManifest(
        format: formatName,
        version: formatVersion,
        chunkSize: chunkSize,
        chunkCount: index,
        plaintextSize: plaintextSize,
        sha256: hexDigest(hasher.finalize()),
        entries: ["start.sh", "extracted"]
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(manifest).write(to: outputRoot.appendingPathComponent("manifest.json"), options: .atomic)
    print("encrypted payload chunks=\(index) plaintext=\(plaintextSize) sha256=\(manifest.sha256)")
}

func verifyPayload(payloadRoot: URL, keyURL: URL) throws {
    let encryptionKeys = try keys(from: keyURL)
    let manifestData = try Data(contentsOf: payloadRoot.appendingPathComponent("manifest.json"))
    let manifest = try JSONDecoder().decode(PayloadManifest.self, from: manifestData)
    guard manifest.format == formatName, manifest.version == formatVersion, manifest.chunkCount > 0 else {
        throw CryptoToolError.invalidManifest
    }
    var hasher = SHA256()
    var plaintextSize: UInt64 = 0
    for index in 0..<manifest.chunkCount {
        let name = String(format: "%08d.yrd", index)
        let encrypted = try Data(contentsOf: payloadRoot.appendingPathComponent(name), options: .mappedIfSafe)
        let plaintext = try decryptChunk(encrypted, index: index, keys: encryptionKeys)
        hasher.update(data: plaintext)
        plaintextSize += UInt64(plaintext.count)
        if index % 50 == 0 { print("verified chunks=\(index + 1)") }
    }
    guard plaintextSize == manifest.plaintextSize,
          hexDigest(hasher.finalize()) == manifest.sha256 else { throw CryptoToolError.checksumMismatch }
    print("verified chunks=\(manifest.chunkCount) plaintext=\(plaintextSize) sha256=\(manifest.sha256)")
}

do {
    let arguments = CommandLine.arguments
    guard arguments.count == 5 || arguments.count == 4 else { throw CryptoToolError.usage }
    switch arguments[1] {
    case "encrypt":
        guard arguments.count == 5 else { throw CryptoToolError.usage }
        try encryptTree(
            sourceRoot: URL(fileURLWithPath: arguments[2], isDirectory: true),
            outputRoot: URL(fileURLWithPath: arguments[3], isDirectory: true),
            keyURL: URL(fileURLWithPath: arguments[4])
        )
    case "verify":
        guard arguments.count == 4 else { throw CryptoToolError.usage }
        try verifyPayload(
            payloadRoot: URL(fileURLWithPath: arguments[2], isDirectory: true),
            keyURL: URL(fileURLWithPath: arguments[3])
        )
    default:
        throw CryptoToolError.usage
    }
} catch {
    FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
    exit(1)
}
