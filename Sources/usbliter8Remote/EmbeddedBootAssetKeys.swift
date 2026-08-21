import CryptoKit
import Foundation

enum EmbeddedBootAssetKeys {
    static func keyData(for layer: Int) -> Data {
        precondition((1...BootAssetEncryption.layerCount).contains(layer))
        var output = [UInt8](repeating: 0, count: BootAssetEncryption.keyByteCount)
        for fragment in 0..<5 {
            let bytes = fragment < 3
                ? BootAssetKeyFragmentsA.decoded(layer: layer, fragment: fragment)
                : BootAssetKeyFragmentsB.decoded(layer: layer, fragment: fragment)
            for index in output.indices { output[index] ^= bytes[index] }
        }
        return Data(output)
    }
}

enum BootAssetFragmentCodec {
    static func decode(_ encoded: [UInt8], layer: Int, fragment: Int) -> [UInt8] {
        encoded.enumerated().map { index, byte in
            byte ^ mask(layer: layer, fragment: fragment, index: index)
        }
    }

    private static func mask(layer: Int, fragment: Int, index: Int) -> UInt8 {
        var value = UInt8(truncatingIfNeeded: 0xA7 + layer * 0x31 + fragment * 0x47 + index * 0x1D)
        value ^= UInt8(truncatingIfNeeded: (index * (layer + fragment + 3)) >> 1)
        let shift = (index + fragment) % 7
        guard shift != 0 else { return value }
        return (value << UInt8(shift)) | (value >> UInt8(8 - shift))
    }
}
