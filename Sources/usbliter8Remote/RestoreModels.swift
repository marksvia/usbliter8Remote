import Foundation

enum RestoreStep: Int, CaseIterable, Sendable {
    case parseDevice = 1
    case confirmPwndfu
    case sendErase
    case erasing
    case completed

    var title: String {
        switch self {
        case .parseDevice: return "Parse CPID / BDID / PWND"
        case .confirmPwndfu: return "Confirm device is in PWNDFU"
        case .sendErase: return "Send obliteration bootstrap"
        case .erasing: return "Write the obliteration marker and reboot"
        case .completed: return "Device obliteration process started"
        }
    }

    var progress: Double {
        switch self {
        case .parseDevice: return 0.12
        case .confirmPwndfu: return 0.24
        case .sendErase: return 0.50
        case .erasing: return 0.82
        case .completed: return 1.0
        }
    }
}
