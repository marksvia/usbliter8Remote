import Foundation

enum EmbeddedRamdiskAssetKeys {
    static func keyData(for layer: Int) -> Data {
        precondition((1...RamdiskAssetEncryption.layerCount).contains(layer))
        var output = [UInt8](repeating: 0, count: RamdiskAssetEncryption.keyByteCount)
        for fragment in 0..<5 {
            let bytes = fragment < 3
                ? RamdiskAssetKeyFragmentsA.decoded(layer: layer, fragment: fragment)
                : RamdiskAssetKeyFragmentsB.decoded(layer: layer, fragment: fragment)
            for index in output.indices { output[index] ^= bytes[index] }
        }
        return Data(output)
    }
}

enum RamdiskAssetFragmentCodec {
    static func decode(_ encoded: [UInt8], layer: Int, fragment: Int) -> [UInt8] {
        encoded.enumerated().map { index, byte in
            byte ^ mask(layer: layer, fragment: fragment, index: index)
        }
    }

    private static func mask(layer: Int, fragment: Int, index: Int) -> UInt8 {
        var value = UInt8(truncatingIfNeeded: 0x6D + layer * 0x29 + fragment * 0x53 + index * 0x17)
        value ^= UInt8(truncatingIfNeeded: (index * (layer + fragment + 5)) >> 1)
        let shift = (index + layer + fragment) % 7
        guard shift != 0 else { return value }
        return (value << UInt8(shift)) | (value >> UInt8(8 - shift))
    }
}
