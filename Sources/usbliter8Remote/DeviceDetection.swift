import Foundation
import IOKit
import IOKit.usb

enum DeviceMode: String, Sendable {
    case normal
    case recovery
    case dfu
    case pwndfu
    case ramdisk

    var displayText: String {
        switch self {
        case .normal: return "Normal Mode"
        case .recovery: return "Recovery Mode"
        case .dfu: return "DFU Mode"
        case .pwndfu: return "PWNDFU Mode"
        case .ramdisk: return "Ramdisk Mode"
        }
    }
}

struct DeviceSupport: Equatable, Sendable {
    let cpid: String
    let bdid: Int
    let displayName: String
    let ibecCodename: String
}

struct DetectedDevice: Equatable, Sendable {
    let displayName: String
    let cpid: String?
    let bdid: Int?
    let ecid: String?
    let udid: String?
    let serialNumber: String?
    let mode: DeviceMode
    let support: DeviceSupport?

    var isSupported: Bool { support != nil || mode == .ramdisk }
    var isPwndfu: Bool { mode == .pwndfu }
    var isRamdisk: Bool { mode == .ramdisk }
}

enum DeviceSupportCatalog {
    static let supportedDevices: [DeviceSupport] = [
        .init(cpid: "0x8020", bdid: 0x0A, displayName: "iPhone XS Max", ibecCodename: "d331"),
        .init(cpid: "0x8020", bdid: 0x0C, displayName: "iPhone XR", ibecCodename: "n841"),
        .init(cpid: "0x8020", bdid: 0x0E, displayName: "iPhone XS", ibecCodename: "d321"),
        .init(cpid: "0x8020", bdid: 0x1A, displayName: "iPhone XS Max", ibecCodename: "d331p"),
        .init(cpid: "0x8020", bdid: 0x14, displayName: "iPad mini 5", ibecCodename: "j210"),
        .init(cpid: "0x8020", bdid: 0x16, displayName: "iPad mini 5", ibecCodename: "j210"),
        .init(cpid: "0x8020", bdid: 0x1C, displayName: "iPad Air 3", ibecCodename: "j217"),
        .init(cpid: "0x8020", bdid: 0x1E, displayName: "iPad Air 3", ibecCodename: "j217"),
        .init(cpid: "0x8020", bdid: 0x24, displayName: "iPad 8", ibecCodename: "ipad11b"),
        .init(cpid: "0x8020", bdid: 0x26, displayName: "iPad 8", ibecCodename: "ipad11b"),
        .init(cpid: "0x8030", bdid: 0x02, displayName: "iPhone 11 Pro Max", ibecCodename: "d431"),
        .init(cpid: "0x8030", bdid: 0x04, displayName: "iPhone 11", ibecCodename: "n104"),
        .init(cpid: "0x8030", bdid: 0x06, displayName: "iPhone 11 Pro", ibecCodename: "d421"),
        .init(cpid: "0x8030", bdid: 0x10, displayName: "iPhone SE 2", ibecCodename: "d79")
    ]

    private static let normalModeSupport: [String: DeviceSupport] = [
        "iPhone11,2": supportedDevices[2],
        "iPhone11,4": supportedDevices[0],
        "iPhone11,6": supportedDevices[3],
        "iPhone11,8": supportedDevices[1],
        "iPad11,1": supportedDevices[4],
        "iPad11,2": supportedDevices[5],
        "iPad11,3": supportedDevices[6],
        "iPad11,4": supportedDevices[7],
        "iPad11,6": supportedDevices[8],
        "iPad11,7": supportedDevices[9],
        "iPhone12,1": supportedDevices[11],
        "iPhone12,3": supportedDevices[12],
        "iPhone12,5": supportedDevices[10],
        "iPhone12,8": supportedDevices[13]
    ]

    static func support(cpid: String?, bdid: Int?) -> DeviceSupport? {
        guard let cpid = cpid, let bdid = bdid else { return nil }
        return supportedDevices.first {
            $0.cpid.caseInsensitiveCompare(cpid) == .orderedSame && $0.bdid == bdid
        }
    }

    static func support(productType: String?) -> DeviceSupport? {
        guard let productType = productType else { return nil }
        return normalModeSupport[productType]
    }
}

struct DFUSerialInfo: Equatable, Sendable {
    let cpid: String?
    let bdid: Int?
    let ecid: String?
    let serialNumber: String?
    let isPwndfu: Bool
}

enum DFUSerialParser {
    static func parse(_ serial: String) -> DFUSerialInfo {
        let fields = Dictionary(
            uniqueKeysWithValues: serial
                .split(separator: " ")
                .compactMap { part -> (String, String)? in
                    let pieces = part.split(separator: ":", maxSplits: 1)
                    guard pieces.count == 2 else { return nil }
                    return (String(pieces[0]), String(pieces[1]))
                }
        )

        let cpid = fields["CPID"].map { "0x\($0.uppercased())" }
        let bdid = fields["BDID"].flatMap { Int($0, radix: 16) }
        let ecid = fields["ECID"]
        let serialNumber = fields["SRNM"]?
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        let isPwndfu = serial.contains("PWND:[")

        return .init(cpid: cpid, bdid: bdid, ecid: ecid, serialNumber: serialNumber, isPwndfu: isPwndfu)
    }
}

enum ECIDFormatter {
    static func displayString(from rawValue: String?) -> String? {
        guard let rawValue = rawValue else { return nil }
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let decimal = UInt64(trimmed) {
            return String(format: "%016llX", decimal)
        }

        let hex = trimmed
            .replacingOccurrences(of: "0x", with: "", options: .caseInsensitive)
            .uppercased()
        guard !hex.isEmpty else { return nil }
        return hex.count >= 16 ? hex : String(repeating: "0", count: 16 - hex.count) + hex
    }
}

protocol DeviceMonitoring: Sendable {
    func devices() -> AsyncStream<DetectedDevice?>
}

struct DeviceMonitor: DeviceMonitoring {
    private let ramdiskDetector = RamdiskConnectionDetector()

    func devices() -> AsyncStream<DetectedDevice?> {
        AsyncStream { continuation in
            let task = Task.detached {
                while !Task.isCancelled {
                    continuation.yield(await detectOnce())
                    try? await Task.sleep(nanoseconds: 500_000_000)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func detectOnce() async -> DetectedDevice? {
        let detected = MobileDeviceToolReader.detectNormalModeDevice()
            ?? USBDeviceScanner.detectAppleDevice()
        if let detected, detected.mode != .normal {
            return detected
        }
        return await ramdiskDetector.detect(fallback: detected) ?? detected
    }
}


private actor RamdiskConnectionDetector {
    private var iproxyProcess: Process?
    private var lastProbeDate = Date.distantPast
    private var lastProbeSucceeded = false

    func detect(fallback: DetectedDevice?) -> DetectedDevice? {
        let now = Date()
        if now.timeIntervalSince(lastProbeDate) < 2 {
            return lastProbeSucceeded ? makeDevice(fallback: fallback) : nil
        }
        lastProbeDate = now
        lastProbeSucceeded = probeSSH()
        return lastProbeSucceeded ? makeDevice(fallback: fallback) : nil
    }

    private func makeDevice(fallback: DetectedDevice?) -> DetectedDevice {
        .init(
            displayName: fallback?.support?.displayName ?? fallback?.displayName ?? "Apple SSH Ramdisk",
            cpid: fallback?.cpid,
            bdid: fallback?.bdid,
            ecid: fallback?.ecid,
            udid: fallback?.udid,
            serialNumber: fallback?.serialNumber,
            mode: .ramdisk,
            support: fallback?.support
        )
    }

    private func probeSSH() -> Bool {
        guard FileManager.default.fileExists(atPath: "/usr/bin/expect"),
              let iproxyURL = AppResourceLocator.toolURL(named: "iproxy") else { return false }

        if !Self.isPortListening(2222) {
            if let process = iproxyProcess, process.isRunning {
                process.terminate()
                process.waitUntilExit()
            }
            let process = Process()
            process.executableURL = iproxyURL
            process.arguments = ["2222", "22"]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
                iproxyProcess = process
                Thread.sleep(forTimeInterval: 0.35)
            } catch {
                iproxyProcess = nil
                return false
            }
        }

        let scriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(".yx-ramdisk-probe-\(UUID().uuidString).expect")
        let script = """
        #!/usr/bin/expect -f
        log_user 0
        set timeout 2
        spawn /usr/bin/ssh -p 2222 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=2 -o LogLevel=ERROR root@localhost "echo __YX_RAMDISK_READY__"
        expect {
          -re "(?i)password:" { send "alpine\\r"; exp_continue }
          "__YX_RAMDISK_READY__" { exit 0 }
          timeout { exit 124 }
          eof
        }
        catch wait result
        exit [lindex $result 3]
        """
        do {
            try script.write(to: scriptURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: scriptURL.path)
            defer { try? FileManager.default.removeItem(at: scriptURL) }

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/expect")
            process.arguments = [scriptURL.path]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            try? FileManager.default.removeItem(at: scriptURL)
            return false
        }
    }

    private static func isPortListening(_ port: Int) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        process.arguments = ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }
}

@MainActor
final class DeviceStateViewModel: ObservableObject {
    @Published private(set) var device: DetectedDevice?
    private let monitor: DeviceMonitoring

    init(monitor: DeviceMonitoring = DeviceMonitor()) {
        self.monitor = monitor
    }

    func startMonitoring() async {
        for await detected in monitor.devices() {
            if detected != device {
                device = detected
            }
        }
    }
}

private enum USBDeviceScanner {
    private static let appleVendorID = 0x05AC
    private static let dfuProductID = 0x1227
    private static let recoveryProductIDs: Set<Int> = [0x1280, 0x1281, 0x1282, 0x1283]
    private static let mobileProductIDs: Set<Int> = [
        0x1290, 0x1291, 0x1292, 0x1293, 0x1294, 0x1295, 0x1296, 0x1297,
        0x12A0, 0x12A1, 0x12A2, 0x12A3, 0x12A4, 0x12A5, 0x12A6, 0x12A7,
        0x12A8, 0x12A9, 0x12AA, 0x12AB
    ]
    private static let ignoredProductNames = [
        "kanziswd", "brisket", "pico", "usb hub", "keyboard", "mouse", "trackpad"
    ]

    static func detectAppleDevice() -> DetectedDevice? {
        let matching = IOServiceMatching(kIOUSBDeviceClassName)
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else {
            return nil
        }
        defer { IOObjectRelease(iterator) }

        var best: Candidate?
        while true {
            let service = IOIteratorNext(iterator)
            if service == 0 { break }
            defer { IOObjectRelease(service) }

            guard integerProperty("idVendor", service: service) == appleVendorID else { continue }

            let productID = integerProperty("idProduct", service: service)
            let productName = stringProperty("USB Product Name", service: service)
                ?? stringProperty("Product Name", service: service)
                ?? ""
            let serial = stringProperty("USB Serial Number", service: service)
                ?? stringProperty("Serial Number", service: service)
                ?? ""

            let device: DetectedDevice
            let priority: Int
            if productID == dfuProductID {
                device = dfuDevice(from: serial)
                priority = device.isPwndfu ? 4 : 3
            } else {
                guard isMobileDevice(productID: productID, productName: productName) else { continue }
                device = normalOrRecoveryDevice(serial: serial, productID: productID, productName: productName)
                priority = device.mode == .recovery ? 2 : 1
            }

            let candidate = Candidate(
                device: device,
                priority: priority,
                sessionID: unsignedIntegerProperty("sessionID", service: service),
                locationID: unsignedIntegerProperty("locationID", service: service),
                registryID: registryEntryID(service)
            )
            if best == nil || candidate.isPreferred(over: best!) { best = candidate }
        }
        return best?.device
    }

    private struct Candidate {
        let device: DetectedDevice
        let priority: Int
        let sessionID: UInt64
        let locationID: UInt64
        let registryID: UInt64

        func isPreferred(over other: Candidate) -> Bool {
            if priority != other.priority { return priority > other.priority }
            if sessionID != other.sessionID { return sessionID > other.sessionID }
            if registryID != other.registryID { return registryID > other.registryID }
            return locationID > other.locationID
        }
    }

    private static func dfuDevice(from serial: String) -> DetectedDevice {
        let info = DFUSerialParser.parse(serial)
        let support = DeviceSupportCatalog.support(cpid: info.cpid, bdid: info.bdid)
        return .init(
            displayName: support?.displayName ?? "Apple DFU Device",
            cpid: info.cpid,
            bdid: info.bdid,
            ecid: ECIDFormatter.displayString(from: info.ecid),
            udid: nil,
            serialNumber: info.serialNumber,
            mode: info.isPwndfu ? .pwndfu : .dfu,
            support: support
        )
    }

    private static func normalOrRecoveryDevice(serial: String, productID: Int?, productName: String) -> DetectedDevice {
        let mode: DeviceMode = productID.map(recoveryProductIDs.contains) == true ? .recovery : .normal
        if mode == .recovery {
            let info = DFUSerialParser.parse(serial)
            let support = DeviceSupportCatalog.support(cpid: info.cpid, bdid: info.bdid)
            return .init(
                displayName: support?.displayName ?? displayName(from: productName),
                cpid: info.cpid,
                bdid: info.bdid,
                ecid: ECIDFormatter.displayString(from: info.ecid),
                udid: nil,
                serialNumber: info.serialNumber,
                mode: .recovery,
                support: support
            )
        }

        return .init(
            displayName: displayName(from: productName),
            cpid: nil,
            bdid: nil,
            ecid: nil,
            udid: serial.isEmpty ? nil : serial,
            serialNumber: nil,
            mode: .normal,
            support: nil
        )
    }

    private static func isMobileDevice(productID: Int?, productName: String) -> Bool {
        let name = productName.lowercased()
        if ignoredProductNames.contains(where: name.contains) { return false }
        if let productID = productID,
           recoveryProductIDs.contains(productID) || mobileProductIDs.contains(productID) { return true }
        return name.contains("iphone") || name.contains("ipad") || name.contains("ipod")
            || name.contains("apple mobile") || name.contains("recovery")
    }

    private static func displayName(from productName: String) -> String {
        let value = productName.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? "Apple Device" : value
    }

    private static func integerProperty(_ key: String, service: io_service_t) -> Int? {
        guard let value = IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? NSNumber else { return nil }
        return value.intValue
    }

    private static func unsignedIntegerProperty(_ key: String, service: io_service_t) -> UInt64 {
        guard let value = IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? NSNumber else { return 0 }
        return value.uint64Value
    }

    private static func registryEntryID(_ service: io_service_t) -> UInt64 {
        var id: UInt64 = 0
        IORegistryEntryGetRegistryEntryID(service, &id)
        return id
    }

    private static func stringProperty(_ key: String, service: io_service_t) -> String? {
        IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? String
    }
}

private enum MobileDeviceToolReader {
    static func detectNormalModeDevice() -> DetectedDevice? {
        guard let ideviceID = findTool(named: "idevice_id"),
              let udid = run(ideviceID, arguments: ["-l"]).firstNonEmptyLine else { return nil }

        let info = readDeviceInfo(udid: udid)
        let productType = info["ProductType"]
        let support = DeviceSupportCatalog.support(productType: productType)
        let displayName = support?.displayName
            ?? nonEmpty(productType)
            ?? nonEmpty(info["DeviceName"])
            ?? "iPhone / iPad"

        return .init(
            displayName: displayName,
            cpid: support?.cpid,
            bdid: support?.bdid,
            ecid: ECIDFormatter.displayString(from: info["UniqueChipID"]),
            udid: info["UniqueDeviceID"] ?? udid,
            serialNumber: info["SerialNumber"],
            mode: .normal,
            support: support
        )
    }

    private static func readDeviceInfo(udid: String) -> [String: String] {
        guard let ideviceInfo = findTool(named: "ideviceinfo") else {
            return ["UniqueDeviceID": udid]
        }
        var values = ["UniqueDeviceID": udid]
        for key in ["DeviceName", "ProductType", "SerialNumber", "UniqueDeviceID", "UniqueChipID"] {
            let value = run(ideviceInfo, arguments: ["-u", udid, "-k", key])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty && !value.lowercased().contains("error:") { values[key] = value }
        }
        return values
    }

    private static func findTool(named name: String) -> String? {
        AppResourceLocator.toolURL(named: name)?.path
    }

    private static func run(_ launchPath: String, arguments: [String]) -> String {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
        } catch { return "" }
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }
}

private extension String {
    var firstNonEmptyLine: String? {
        split(whereSeparator: \.isNewline)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
    }
}
