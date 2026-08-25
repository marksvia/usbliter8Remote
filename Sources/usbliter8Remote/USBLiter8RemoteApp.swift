import AppKit
import SwiftUI

final class USBLiter8ApplicationDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        applyApplicationIcon()
        makeApplicationForeground()
    }

    private func applyApplicationIcon() {
        guard let iconURL = AppResourceLocator.resourceURL(
            name: "AppIcon",
            extension: "icns",
            subdirectories: ["Branding", "Resources/Branding"]
        ), let icon = NSImage(contentsOf: iconURL) else {
            return
        }
        NSApp.applicationIconImage = icon
    }

    private func makeApplicationForeground() {
        if !NSApp.setActivationPolicy(.regular) {
            DispatchQueue.main.async {
                NSApp.setActivationPolicy(.regular)
                NSApp.activate(ignoringOtherApps: true)
            }
            return
        }
        NSApp.activate(ignoringOtherApps: true)
    }
}

@main
struct USBLiter8RemoteApp: App {
    @NSApplicationDelegateAdaptor(USBLiter8ApplicationDelegate.self) private var applicationDelegate

    init() {
        NSApplication.shared.setActivationPolicy(.regular)
    }

    var body: some Scene {
        WindowGroup("usbliter8 remote") {
            ContentView()
                .frame(minWidth: 1120, minHeight: 720)
        }
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unifiedCompact)
    }
}

struct ContentView: View {
    @StateObject private var deviceState = DeviceStateViewModel()
    @State private var activityText = "Waiting for an operation…"
    @State private var progress: Double = 0.68
    @State private var logs: [LogLine] = [
        .init(time: "--:--:--", text: "Device detection service started", success: true),
        .init(time: "--:--:--", text: "Waiting for an Apple USB device…", success: false)
    ]
    @State private var showEraseConfirmation = false
    @State private var showPostExtractEraseConfirmation = false
    @State private var showPostRestoreRebootConfirmation = false
    @State private var showRamdiskVersionPrompt = false
    @State private var showOperationError = false
    @State private var operationErrorTitle = "Operation Failed"
    @State private var operationErrorMessage = ""
    @State private var showOperationSuccess = false
    @State private var operationSuccessTitle = "Operation Succeeded"
    @State private var operationSuccessMessage = ""
    @State private var showErasePromptAfterSuccess = false
    @State private var isErasing = false
    @State private var isPostExtractErasing = false
    @State private var isRamdiskRunning = false
    @State private var isMountingMnt2 = false
    @State private var isExtractingFiles = false
    @State private var isRestoringFiles = false
    @State private var isRunningHelloNoChange = false
    @State private var isRebooting = false
    @State private var lastDeviceIdentifier: String?
    @State private var lastDeviceECID: String?
    @State private var lastExtractedDirectoryURL: URL?
    @State private var lastExtractedDeviceIdentifier: String?
    @State private var ramdiskIOSVersion = ""
    @FocusState private var isRamdiskVersionFocused: Bool
    private let restoreService = RestoreService()
    private let ramdiskService = RamdiskService()
    private let mnt2Service = Mnt2Service()
    private let extractFileService = ExtractFileService()
    private let restoreFileService = RestoreFileService()
    private let ramdiskObliterationService = RamdiskObliterationService()
    private let helloNoChangeService = HelloNoChangeService()
    private let ramdiskRebootService = RamdiskRebootService()

    private let actions: [ActionItem] = [
        .init(title: "ramdisk", symbol: "externaldrive", kind: .primary),
        .init(title: "mnt2", symbol: "command", kind: .normal),
        .init(title: "extractFile", symbol: "arrow.down.doc", kind: .normal),
        .init(title: "erase device", symbol: "trash", kind: .destructive),
        .init(title: "restoreFile", symbol: "arrow.up.doc", kind: .normal),
        .init(title: "helloNoChange", symbol: "diamond", kind: .normal),
        .init(title: "reboot", symbol: "arrow.clockwise", kind: .reboot)
    ]

    var body: some View {
        ZStack {
            FlowingGradientBackground()

            VStack(spacing: 0) {
                titleBar
                mainArea
                actionDock
            }
            .background(Color.white.opacity(0.035))

            if hasActiveModal {
                activeModalOverlay
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
                    .zIndex(20)
            }
        }
        .animation(.easeOut(duration: 0.18), value: hasActiveModal)
        .preferredColorScheme(.light)
        .task {
            await deviceState.startMonitoring()
        }
        .onChange(of: deviceState.device) { newDevice in
            if let identifier = stableIdentifier(for: newDevice) {
                lastDeviceIdentifier = identifier
            }
            if let ecid = newDevice?.ecid {
                lastDeviceECID = ecid
            }
            guard !isBusy else { return }
            updateDetectionLog(for: newDevice)
        }
    }

    private var hasActiveModal: Bool {
        showOperationError
            || showOperationSuccess
            || showPostExtractEraseConfirmation
            || showEraseConfirmation
            || showPostRestoreRebootConfirmation
            || showRamdiskVersionPrompt
    }

    private var activeModalOverlay: some View {
        ZStack {
            Color.black.opacity(0.16)
                .ignoresSafeArea()

            activeModalCard
        }
    }

    @ViewBuilder
    private var activeModalCard: some View {
        if showOperationError {
            BrandedModalCard(
                symbol: "exclamationmark.triangle.fill",
                eyebrow: "OPERATION FAILED",
                title: operationErrorTitle,
                message: operationErrorMessage,
                accent: AppColors.pink
            ) {
                EmptyView()
            } actions: {
                BrandedModalButton(title: "OK", symbol: "checkmark", style: .primary) {
                    showOperationError = false
                }
            }
        } else if showOperationSuccess {
            BrandedModalCard(
                symbol: "checkmark.circle.fill",
                eyebrow: "SUCCESS",
                title: operationSuccessTitle,
                message: operationSuccessMessage,
                accent: AppColors.green
            ) {
                EmptyView()
            } actions: {
                BrandedModalButton(title: "OK", symbol: "checkmark", style: .primary) {
                    showOperationSuccess = false
                    if showErasePromptAfterSuccess {
                        showErasePromptAfterSuccess = false
                        showPostExtractEraseConfirmation = true
                    }
                }
            }
        } else if showPostExtractEraseConfirmation {
            BrandedModalCard(
                symbol: "externaldrive.badge.checkmark",
                eyebrow: "EXTRACT COMPLETE",
                title: "File Extraction Complete",
                message: "The files were saved to the Desktop. Write the obliteration command now? Choose Keep Ramdisk to leave the device in its current Ramdisk environment.",
                accent: AppColors.pink
            ) {
                EmptyView()
            } actions: {
                HStack(spacing: 11) {
                    BrandedModalButton(title: "Keep Ramdisk", symbol: "externaldrive", style: .secondary) {
                        showPostExtractEraseConfirmation = false
                        activityText = "File extraction complete; keeping the current Ramdisk environment"
                        appendLog("Device was not obliterated; keeping the current Ramdisk environment", success: true)
                    }
                    BrandedModalButton(title: "Erase Device", symbol: "trash", style: .destructive) {
                        showPostExtractEraseConfirmation = false
                        startPostExtractErase()
                    }
                }
            }
        } else if showEraseConfirmation {
            BrandedModalCard(
                symbol: "trash.fill",
                eyebrow: "DESTRUCTIVE ACTION",
                title: "Permanently erase this device?",
                message: "This permanently erases all data on the device. Keep the device connected by USB and in PWNDFU. Do not disconnect it or quit the application after starting.",
                accent: AppColors.pink
            ) {
                EmptyView()
            } actions: {
                HStack(spacing: 11) {
                    BrandedModalButton(title: "Cancel", symbol: "xmark", style: .secondary) {
                        showEraseConfirmation = false
                    }
                    BrandedModalButton(title: "Permanently Erase", symbol: "trash", style: .destructive) {
                        showEraseConfirmation = false
                        startErase()
                    }
                }
            }
        } else if showPostRestoreRebootConfirmation {
            BrandedModalCard(
                symbol: "arrow.triangle.2.circlepath",
                eyebrow: "RESTORE COMPLETE",
                title: "File Restore Complete",
                message: "Device files were restored successfully. You can reboot into iOS or keep working in the current Ramdisk environment.",
                accent: AppColors.green
            ) {
                EmptyView()
            } actions: {
                HStack(spacing: 11) {
                    BrandedModalButton(title: "Keep Ramdisk", symbol: "externaldrive", style: .secondary) {
                        showPostRestoreRebootConfirmation = false
                        activityText = "File restore complete; keeping the current Ramdisk environment"
                        appendLog("Device was not rebooted; keeping the current Ramdisk environment", success: true)
                    }
                    BrandedModalButton(title: "Reboot Device", symbol: "arrow.clockwise", style: .primary) {
                        showPostRestoreRebootConfirmation = false
                        startReboot(showActivateSuccess: true)
                    }
                }
            }
        } else if showRamdiskVersionPrompt {
            BrandedModalCard(
                symbol: "externaldrive.fill",
                eyebrow: "RAMDISK BOOT",
                title: "Start Ramdisk",
                message: "Enter the iOS version currently installed on the device. It will be passed to start.sh as the -v argument.",
                accent: AppColors.green
            ) {
                VStack(alignment: .leading, spacing: 9) {
                    Text("iOS Version")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(AppColors.greenDark)
                    TextField("Example:  16.7.11", text: $ramdiskIOSVersion)
                        .textFieldStyle(.plain)
                        .font(.system(size: 15, weight: .semibold, design: .monospaced))
                        .foregroundColor(AppColors.ink)
                        .padding(.horizontal, 14)
                        .frame(height: 44)
                        .background(Color.white.opacity(0.78))
                        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 13, style: .continuous)
                                .stroke(
                                    RamdiskService.isValidIOSVersion(ramdiskIOSVersion)
                                        ? AppColors.green.opacity(0.55)
                                        : AppColors.ink.opacity(0.10),
                                    lineWidth: 1
                                )
                        )
                        .focused($isRamdiskVersionFocused)
                        .onSubmit {
                            submitRamdiskVersion()
                        }
                    HStack(spacing: 6) {
                        Circle()
                            .fill(AppColors.green)
                            .frame(width: 6, height: 6)
                        Text("Device: \(detectedDevice?.displayName ?? "Apple Device") · PWNDFU Ready")
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundColor(AppColors.greenDark)
                    }
                }
                .padding(.top, 2)
                .onAppear {
                    DispatchQueue.main.async {
                        isRamdiskVersionFocused = true
                    }
                }
            } actions: {
                HStack(spacing: 11) {
                    BrandedModalButton(title: "Cancel", symbol: "xmark", style: .secondary) {
                        showRamdiskVersionPrompt = false
                        isRamdiskVersionFocused = false
                        activityText = "Ramdisk startup cancelled"
                        appendLog("Ramdisk startup cancelled", success: false)
                    }
                    BrandedModalButton(
                        title: "Start Ramdisk",
                        symbol: "play.fill",
                        style: .primary,
                        isEnabled: RamdiskService.isValidIOSVersion(ramdiskIOSVersion)
                    ) {
                        submitRamdiskVersion()
                    }
                }
            }
        }
    }

    private func submitRamdiskVersion() {
        let version = ramdiskIOSVersion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard RamdiskService.isValidIOSVersion(version) else { return }
        ramdiskIOSVersion = version
        showRamdiskVersionPrompt = false
        isRamdiskVersionFocused = false
        startRamdisk()
    }

    private var detectedDevice: DetectedDevice? { deviceState.device }
    private var isConnected: Bool { detectedDevice != nil }
    private var isBusy: Bool { isErasing || isPostExtractErasing || isRamdiskRunning || isMountingMnt2 || isExtractingFiles || isRestoringFiles || isRunningHelloNoChange || isRebooting }

    private var titleBar: some View {
        HStack {
            // Reserve equal space for the native macOS window controls to keep the title centered.
            Color.clear
                .frame(width: 150, height: 1)

            Spacer()
            HStack(spacing: 10) {
                if let imageURL = AppResourceLocator.resourceURL(
                    name: "brand-avatar",
                    extension: "png",
                    subdirectories: ["Branding", "Resources/Branding"]
                ), let image = NSImage(contentsOf: imageURL) {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 42, height: 42)
                        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 11, style: .continuous)
                                .stroke(Color.white.opacity(0.82), lineWidth: 1.5)
                        }
                        .shadow(color: AppColors.ink.opacity(0.12), radius: 4, y: 2)
                }

                Text("usbliter8 remote")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(AppColors.ink)
            }
            Spacer()

            HStack(spacing: 6) {
                Circle()
                    .fill(isConnected ? AppColors.green : Color.gray.opacity(0.55))
                    .frame(width: 6, height: 6)
                Text(detectedDevice?.isRamdisk == true ? "Ramdisk Connected" : (isConnected ? "USB Connected" : "Waiting for Device"))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(isConnected ? AppColors.greenDark : AppColors.secondaryText)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(isConnected ? AppColors.greenPale.opacity(0.95) : Color.white.opacity(0.52))
            .clipShape(Capsule())
            .overlay(Capsule().stroke(AppColors.ink.opacity(0.09), lineWidth: 1))
            .frame(width: 150, alignment: .trailing)
        }
        .padding(.horizontal, 24)
        .frame(height: 64)
        .background(Color.white.opacity(0.36))
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.black.opacity(0.055)).frame(height: 1)
        }
    }

    private var mainArea: some View {
        HStack(alignment: .top, spacing: 22) {
            VStack(spacing: 18) {
                summaryCards
                heroCard
                activityLog
            }
            .frame(maxWidth: .infinity)

            VStack(spacing: 18) {
                connectedDeviceCard
                progressCard
                noticeCard
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 34)
        .padding(.top, 28)
        .padding(.bottom, 18)
    }

    private var heroCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Device Identity")
                        .font(.system(size: 11, weight: .bold))
                        .tracking(1.7)
                        .foregroundColor(AppColors.greenDark.opacity(0.72))
                    Text(isConnected ? "Current device information loaded" : "Connect a device to load its information")
                        .font(.system(size: 11))
                        .foregroundColor(AppColors.tertiaryText)
                }
                Spacer()
                Text(detectedDevice?.mode.displayText ?? "Not Connected")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(isConnected ? AppColors.greenDark : AppColors.secondaryText)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(isConnected ? AppColors.greenPale : Color.white.opacity(0.52))
                    .clipShape(Capsule())
            }

            VStack(spacing: 0) {
                IdentityRow(label: "ECID", value: detectedDevice?.ecid ?? "Unavailable")
                Divider().opacity(0.40)
                IdentityRow(label: "UDID", value: detectedDevice?.udid ?? "Unavailable")
                Divider().opacity(0.40)
                IdentityRow(label: "SN", value: detectedDevice?.serialNumber ?? "Unavailable")
            }
            .padding(.top, 12)
        }
        .padding(22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: 210)
        .background(Color.white.opacity(0.42))
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22).stroke(Color.white.opacity(0.72), lineWidth: 1))
        .softShadow()
    }

    private var summaryCards: some View {
        HStack(spacing: 14) {
            SummaryCard(
                symbol: "iphone",
                tint: AppColors.greenPale,
                label: "Device Model",
                value: detectedDevice?.displayName ?? "No Device Detected",
                status: detectedDevice.map { $0.isSupported ? "Supported" : "Not Supported" } ?? "Waiting for Detection",
                statusColor: detectedDevice?.isSupported == true ? AppColors.greenDark : AppColors.secondaryText
            )
            SummaryCard(
                symbol: "cable.connector",
                tint: AppColors.pinkPale,
                label: "USB Connection",
                value: detectedDevice?.isRamdisk == true ? "Ramdisk Connected" : (isConnected ? "USB Connected" : "USB Not Connected"),
                status: detectedDevice?.mode.displayText ?? "Connect a device",
                statusColor: isConnected ? AppColors.greenDark : AppColors.secondaryText
            )
            SummaryCard(
                symbol: "checkmark.shield",
                tint: AppColors.purplePale,
                label: "PWN Status",
                value: detectedDevice?.isRamdisk == true ? "Ramdisk Connected" : (detectedDevice?.isPwndfu == true ? "PWNDFU Ready" : "PWN Not Active"),
                status: detectedDevice?.isRamdisk == true ? "SSH Ready" : (detectedDevice?.isPwndfu == true ? "PWND:[usbliter8]" : "Waiting for PWNDFU"),
                statusColor: detectedDevice?.isRamdisk == true || detectedDevice?.isPwndfu == true ? AppColors.greenDark : AppColors.secondaryText
            )
        }
    }

    private var activityLog: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack {
                Text("Activity Log")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white.opacity(0.94))
                Spacer()
                Text("Live Output")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.white.opacity(0.55))
            }

            ForEach(logs) { line in
                HStack(spacing: 7) {
                    Text(line.time)
                        .foregroundColor(.white.opacity(0.48))
                    Text(line.success ? "✓" : "—")
                        .foregroundColor(line.success ? AppColors.greenBright : .white.opacity(0.42))
                    Text(line.text)
                        .foregroundColor(line.success ? .white.opacity(0.84) : .white.opacity(0.52))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.system(size: 11, design: .monospaced))
            }
            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(maxWidth: .infinity, minHeight: 172, alignment: .topLeading)
        .background(AppColors.logBackground)
        .clipShape(RoundedRectangle(cornerRadius: 21, style: .continuous))
    }

    private var connectedDeviceCard: some View {
        PanelCard(title: "Live Device Detection") {
            VStack(spacing: 0) {
                DeviceRow(
                    symbol: "iphone",
                    title: detectedDevice?.displayName ?? "No Apple Device Detected",
                    subtitle: detectedDevice.map { "Mode · \($0.mode.displayText)" } ?? "Listening for USB devices",
                    status: isConnected ? "Online" : "Offline"
                )
                Divider().opacity(0.45)
                DeviceRow(
                    symbol: "cpu",
                    title: detectedDevice?.cpid ?? "CPID Unavailable",
                    subtitle: detectedDevice?.bdid.map { String(format: "BDID · 0x%02X", $0) } ?? "BDID Unavailable"
                )
                Divider().opacity(0.45)
                DeviceRow(
                    symbol: "checkmark.shield",
                    title: detectedDevice?.isRamdisk == true ? "Ramdisk Connected" : (detectedDevice?.isSupported == true ? "Current device is supported" : "Support status unconfirmed"),
                    subtitle: detectedDevice?.isRamdisk == true ? "Ramdisk SSH Ready" : (detectedDevice?.isPwndfu == true ? "Device is in PWNDFU" : "Waiting for PWNDFU status")
                )
            }
        }
    }

    private var progressCard: some View {
        PanelCard(title: "Workspace Progress") {
            VStack(alignment: .leading, spacing: 13) {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(activityText)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(AppColors.ink)
                        Text("Environment checks complete")
                            .font(.system(size: 10))
                            .foregroundColor(AppColors.tertiaryText)
                    }
                    Spacer()
                    Text("\(Int(progress * 100))%")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(AppColors.greenDark)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(AppColors.greenPale)
                        .clipShape(Capsule())
                }

                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.black.opacity(0.055))
                        Capsule()
                            .fill(LinearGradient(colors: [AppColors.greenBright, AppColors.pink], startPoint: .leading, endPoint: .trailing))
                            .frame(width: max(0, proxy.size.width * progress))
                    }
                }
                .frame(height: 7)

                HStack {
                    Text("4 of 6 tasks complete")
                    Spacer()
                    Text("Healthy")
                }
                .font(.system(size: 10))
                .foregroundColor(AppColors.secondaryText)
            }
        }
    }

    private var noticeCard: some View {
        HStack {
            VStack(alignment: .leading, spacing: 6) {
                Text("Before You Continue")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(AppColors.ink)
                Text("Keep the device connected and avoid closing the application during an operation.")
                    .font(.system(size: 11))
                    .foregroundColor(AppColors.secondaryText)
            }
            Spacer()
        }
        .padding(18)
        .background(Color.white.opacity(0.42))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(AppColors.pink.opacity(0.2), lineWidth: 1))
    }

    private var actionDock: some View {
        HStack(spacing: 9) {
            ForEach(actions) { item in
                ActionButton(item: item) {
                    if item.title == "ramdisk" {
                        prepareRamdisk()
                    } else if item.title == "mnt2" {
                        startMnt2()
                    } else if item.title == "extractFile" {
                        startExtractFile()
                    } else if item.title == "restoreFile" {
                        startRestoreFile()
                    } else if item.title == "helloNoChange" {
                        startHelloNoChange()
                    } else if item.title == "erase device" {
                        prepareErase()
                    } else if item.title == "reboot" {
                        startReboot()
                    } else {
                        runPreviewAction(item.title)
                    }
                }
                .disabled(isBusy)
                .opacity(isBusy ? 0.55 : 1)
            }
        }
        .padding(14)
        .background(Color.white.opacity(0.46))
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22).stroke(Color.white.opacity(0.82), lineWidth: 1))
        .shadow(color: AppColors.ink.opacity(0.12), radius: 24, x: 0, y: 12)
        .padding(.horizontal, 24)
        .padding(.bottom, 20)
    }

    private func updateDetectionLog(for device: DetectedDevice?) {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        let time = formatter.string(from: Date())

        if let device = device {
            if device.isRamdisk {
                activityText = "Ramdisk Connected"
                logs = [
                    .init(time: time, text: "USB device connected", success: true),
                    .init(time: time, text: "Identified as  \(device.displayName)", success: true),
                    .init(time: time, text: "Ramdisk SSH Connected", success: true),
                    .init(time: time, text: "Device is currently in the Ramdisk environment", success: true)
                ]
            } else {
                activityText = "Device detection complete"
                logs = [
                    .init(time: time, text: "USB device connected", success: true),
                    .init(time: time, text: "Identified as  \(device.displayName)", success: true),
                    .init(time: time, text: device.isSupported ? "Current device is supported" : "Current device is not supported", success: device.isSupported),
                    .init(time: time, text: device.isPwndfu ? "PWNDFU Ready" : "Device is not in PWNDFU", success: device.isPwndfu)
                ]
            }
        } else {
            activityText = "Waiting for Device…"
            logs = [
                .init(time: time, text: "Device detection service is running", success: true),
                .init(time: time, text: "Waiting for an Apple USB device…", success: false)
            ]
        }
    }

    private func prepareRamdisk() {
        guard !isBusy else { return }
        guard let device = detectedDevice else {
            activityText = "Ramdisk not started"
            appendLog("No USB device detected", success: false)
            return
        }
        if device.isRamdisk {
            activityText = "Ramdisk Connected"
            appendLog("Device is already in the Ramdisk SSH environment", success: true)
            return
        }
        guard device.isSupported else {
            activityText = "Ramdisk not started"
            appendLog("Device \(device.displayName) is not in the supported device list", success: false)
            return
        }
        guard device.isPwndfu else {
            activityText = "Ramdisk not started"
            appendLog("Put the device into PWNDFU mode first", success: false)
            return
        }

        activityText = "Waiting for an iOS version"
        appendLog("Ramdisk preflight passed: supported device / PWNDFU", success: true)
        ramdiskIOSVersion = ""
        showRamdiskVersionPrompt = true
    }

    private func startRamdisk() {
        let version = ramdiskIOSVersion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isBusy,
              RamdiskService.isValidIOSVersion(version),
              let device = detectedDevice,
              device.isSupported,
              device.isPwndfu else { return }

        ramdiskIOSVersion = version
        isRamdiskRunning = true
        progress = 0.04
        activityText = "Starting Ramdisk…"
        appendLog("Starting Ramdisk for  \(device.displayName)  with iOS \(version)", success: true)

        Task {
            do {
                try await ramdiskService.start(iosVersion: version) { line in
                    guard ContentView.shouldPublishRamdiskOutput(line) else { return }
                    let displayLine = ContentView.displayLogText(line)
                    Task { @MainActor in
                        updateRamdiskProgress(from: displayLine)
                        appendLog(displayLine, success: true)
                    }
                }
                await MainActor.run {
                    activityText = "Ramdisk startup complete"
                    progress = 1.0
                    appendLog("Ramdisk workflow complete", success: true)
                    isRamdiskRunning = false
                }
            } catch {
                await MainActor.run {
                    activityText = "Ramdisk startup failed"
                    progress = 0
                    operationErrorTitle = "Ramdisk startup failed"
                    operationErrorMessage = error.localizedDescription
                    showOperationError = true
                    appendLog("Ramdisk failed: \(error.localizedDescription)", success: false)
                    isRamdiskRunning = false
                }
            }
        }
    }

    private func stableIdentifier(for device: DetectedDevice?) -> String? {
        guard let device else { return nil }
        return [device.ecid, device.udid, device.serialNumber]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
    }

    private func startHelloNoChange() {
        guard !isBusy else { return }
        guard let ecid = detectedDevice?.ecid ?? lastDeviceECID,
              HelloNoChangeService.normalizedECID(ecid) != nil else {
            activityText = "helloNoChange not started"
            appendLog("A valid device ECID was not found", success: false)
            return
        }
        lastDeviceECID = ecid
        isRunningHelloNoChange = true
        progress = 0.05
        activityText = "Preparing helloNoChange…"
        appendLog("Device is already in Ramdisk with /mnt2 mounted", success: true)

        Task {
            do {
                try await helloNoChangeService.run(ecid: ecid) { line in
                    guard ContentView.shouldPublishHelloNoChangeOutput(line) else { return }
                    let displayLine = ContentView.displayLogText(line)
                    Task { @MainActor in
                        updateHelloNoChangeProgress(from: displayLine)
                        appendLog(displayLine, success: true)
                    }
                }
                await MainActor.run {
                    activityText = "helloNoChange complete; device is rebooting"
                    progress = 1.0
                    appendLog("helloNoChange workflow complete", success: true)
                    isRunningHelloNoChange = false
                    operationSuccessTitle = "activate success"
                    operationSuccessMessage = "helloNoChange workflow complete; the device is rebooting."
                    showOperationSuccess = true
                }
            } catch {
                await MainActor.run {
                    activityText = "helloNoChange failed"
                    progress = 0
                    operationErrorTitle = "helloNoChange Failed"
                    operationErrorMessage = error.localizedDescription
                    showOperationError = true
                    appendLog("helloNoChange failed: \(error.localizedDescription)", success: false)
                    isRunningHelloNoChange = false
                }
            }
        }
    }

    private func updateHelloNoChangeProgress(from line: String) {
        let value = line.lowercased()
        if value.contains("reboot device") || value.contains("replay complete") {
            progress = max(progress, 0.96)
            activityText = "Finalizing and rebooting the device…"
        } else if value.contains("strict final verification") || value.contains("mobilegestalt unchanged") {
            progress = max(progress, 0.86)
            activityText = "Verifying the write result…"
        } else if value.contains("restore bypass payload") || value.contains("stage 3/3") {
            progress = max(progress, 0.68)
            activityText = "Writing device files…"
        } else if value.contains("stage 1/3") || value.contains("stage 2/3") || value.contains("fresh ticket") {
            progress = max(progress, 0.44)
            activityText = "Generating device tickets…"
        } else if value.contains("ssh connected") || value.contains("native identity") {
            progress = max(progress, 0.25)
            activityText = "Reading the native device identity…"
        } else if value.contains("decrypt") {
            progress = max(progress, 0.10)
        }
    }

    private func startReboot(showActivateSuccess: Bool = false) {
        guard !isBusy else { return }
        isRebooting = true
        progress = 0.08
        activityText = "Connecting to Ramdisk SSH…"
        appendLog("Sending the device reboot command", success: true)

        Task {
            do {
                try await ramdiskRebootService.reboot { line in
                    let displayLine = ContentView.displayLogText(line)
                    Task { @MainActor in
                        if displayLine.contains("SSH Connected") {
                            progress = max(progress, 0.45)
                            activityText = "Ramdisk SSH Connected"
                        } else if displayLine.contains("Sending device reboot") {
                            progress = max(progress, 0.78)
                            activityText = "Sending the device reboot command…"
                        } else if displayLine.contains("Device is rebooting") {
                            progress = 1.0
                        }
                        appendLog(displayLine, success: true)
                    }
                }
                await MainActor.run {
                    activityText = "Device is rebooting"
                    progress = 1.0
                    appendLog("Reboot command sent", success: true)
                    isRebooting = false
                    if showActivateSuccess {
                        operationSuccessTitle = "activate success"
                        operationSuccessMessage = "Device files were restored successfully and the reboot command was sent."
                        showOperationSuccess = true
                    }
                }
            } catch {
                await MainActor.run {
                    activityText = "Device reboot failed"
                    progress = 0
                    operationErrorTitle = "Device reboot failed"
                    operationErrorMessage = error.localizedDescription
                    showOperationError = true
                    appendLog("Device reboot failed: \(error.localizedDescription)", success: false)
                    isRebooting = false
                }
            }
        }
    }

    private func startPostExtractErase() {
        guard !isBusy else { return }
        isPostExtractErasing = true
        progress = 0.08
        activityText = "Connecting to Ramdisk SSH…"
        appendLog("Sending the device obliteration command", success: true)

        Task {
            do {
                try await ramdiskObliterationService.erase { line in
                    let displayLine = ContentView.displayLogText(line)
                    Task { @MainActor in
                        if displayLine.contains("SSH Connected") {
                            progress = max(progress, 0.40)
                        } else if displayLine.contains("Writing obliteration state") {
                            progress = max(progress, 0.72)
                        } else if displayLine.contains("Rebooting") {
                            progress = 1.0
                        }
                        appendLog(displayLine, success: true)
                    }
                }
                await MainActor.run {
                    activityText = "Device obliteration is in progress"
                    progress = 1.0
                    appendLog("Obliteration command sent; the device is entering the obliteration process", success: true)
                    operationSuccessTitle = "Obliteration Succeeded"
                    operationSuccessMessage = "The obliteration command was written successfully; the device is processing it."
                    showOperationSuccess = true
                    isPostExtractErasing = false
                }
            } catch {
                await MainActor.run {
                    activityText = "Device obliteration command failed"
                    progress = 0
                    operationErrorTitle = "Device obliteration failed"
                    operationErrorMessage = error.localizedDescription
                    showOperationError = true
                    appendLog("Device obliteration failed: \(error.localizedDescription)", success: false)
                    isPostExtractErasing = false
                }
            }
        }
    }

    private func startRestoreFile() {
        guard !isBusy else { return }
        guard let deviceIdentifier = stableIdentifier(for: detectedDevice) ?? lastDeviceIdentifier else {
            activityText = "File restore not started"
            appendLog("Could not obtain the device ECID, UDID, or serial number", success: false)
            return
        }
        let rememberedDirectory: URL? = {
            guard lastExtractedDeviceIdentifier == deviceIdentifier,
                  let url = lastExtractedDirectoryURL,
                  RestoreFileService.matchesBackupDirectory(url, deviceIdentifier: deviceIdentifier) else { return nil }
            return url
        }()
        guard let inputDirectory = rememberedDirectory
                ?? RestoreFileService.latestBackupDirectory(deviceIdentifier: deviceIdentifier) else {
            activityText = "File restore not started"
            appendLog("No Backup_Tickets extraction directory for the current device was found on the Desktop", success: false)
            return
        }

        isRestoringFiles = true
        progress = 0.05
        activityText = "Preparing to restore files…"
        appendLog("Using \(inputDirectory.lastPathComponent),default -old mode", success: true)

        Task {
            do {
                try await restoreFileService.restoreOld(
                    inputDirectory: inputDirectory,
                    deviceIdentifier: deviceIdentifier
                ) { line in
                    guard ContentView.shouldPublishRestoreFileOutput(line) else { return }
                    let displayLine = ContentView.displayLogText(line)
                    Task { @MainActor in
                        updateRestoreFileProgress(from: displayLine)
                        appendLog(displayLine, success: true)
                    }
                }
                await MainActor.run {
                    activityText = "File Restore Complete"
                    progress = 1.0
                    appendLog("Files restored for the current device", success: true)
                    isRestoringFiles = false
                    showPostRestoreRebootConfirmation = true
                }
            } catch {
                await MainActor.run {
                    activityText = "File restore failed"
                    progress = 0
                    operationErrorTitle = "restoreFile restore failed"
                    operationErrorMessage = error.localizedDescription
                    showOperationError = true
                    appendLog("restoreFile failed: \(error.localizedDescription)", success: false)
                    isRestoringFiles = false
                }
            }
        }
    }

    private func updateRestoreFileProgress(from line: String) {
        let value = line.lowercased()
        if value.contains("final restore") || value.contains("restore complete") {
            progress = max(progress, 0.94)
            activityText = "Verifying the restore result…"
        } else if value.contains("restore ") || value.contains("upload") {
            progress = max(progress, 0.68)
            activityText = "Writing device files…"
        } else if value.contains("/mnt2") || value.contains("mount") {
            progress = max(progress, 0.44)
            activityText = "Checking /mnt2…"
        } else if value.contains("ssh connected") {
            progress = max(progress, 0.28)
            activityText = "Ramdisk SSH Connected"
        } else if value.contains("decrypt") {
            progress = max(progress, 0.10)
        }
    }

    private func startExtractFile() {
        guard !isBusy else { return }
        guard let deviceIdentifier = stableIdentifier(for: detectedDevice) ?? lastDeviceIdentifier else {
            activityText = "File extraction not started"
            appendLog("Could not obtain the device ECID, UDID, or serial number, so a device-specific export package cannot be created", success: false)
            return
        }
        lastDeviceIdentifier = deviceIdentifier
        isExtractingFiles = true
        progress = 0.05
        activityText = "Connecting to Ramdisk SSH…"
        appendLog("Extracting files in -old mode; results will be saved to the Desktop", success: true)

        Task {
            do {
                let result = try await extractFileService.extractOld(deviceIdentifier: deviceIdentifier) { line in
                    guard ContentView.shouldPublishExtractFileOutput(line) else { return }
                    let displayLine = ContentView.displayLogText(line)
                    Task { @MainActor in
                        updateExtractFileProgress(from: displayLine)
                        appendLog(displayLine, success: true)
                    }
                }
                await MainActor.run {
                    activityText = "File extraction complete; saved to the Desktop"
                    progress = 1.0
                    lastExtractedDirectoryURL = result.outputDirectoryURL
                    lastExtractedDeviceIdentifier = deviceIdentifier
                    let savedURL = result.zipURL ?? result.outputDirectoryURL
                    if let zipURL = result.zipURL {
                        appendLog("Desktop file: \(zipURL.lastPathComponent)", success: true)
                    } else {
                        appendLog("Desktop directory: \(result.outputDirectoryURL.lastPathComponent)", success: true)
                    }
                    operationSuccessTitle = "extractFile success"
                    operationSuccessMessage = "Files saved to:\n\(savedURL.path)"
                    showErasePromptAfterSuccess = true
                    isExtractingFiles = false
                    showOperationSuccess = true
                }
            } catch {
                await MainActor.run {
                    activityText = "File extraction failed"
                    progress = 0
                    operationErrorTitle = "extractFile extraction failed"
                    operationErrorMessage = error.localizedDescription
                    showOperationError = true
                    appendLog("extractFile failed: \(error.localizedDescription)", success: false)
                    isExtractingFiles = false
                }
            }
        }
    }

    private func updateExtractFileProgress(from line: String) {
        let value = line.lowercased()
        if value.contains("create zip") || value.contains("summary") {
            progress = max(progress, 0.90)
            activityText = "Creating the Desktop archive…"
        } else if value.contains("download") {
            progress = max(progress, 0.68)
            activityText = "Extracting files from the device…"
        } else if value.contains("/mnt2") || value.contains("mount/setup") || value.contains("mount flow") {
            progress = max(progress, 0.48)
            activityText = "Checking /mnt2…"
        } else if value.contains("ssh connected") {
            progress = max(progress, 0.32)
            activityText = "Ramdisk SSH Connected"
        } else if value.contains("iproxy") {
            progress = max(progress, 0.18)
            activityText = "Starting USB SSH forwarding…"
        } else if value.contains("decrypt") {
            progress = max(progress, 0.10)
        }
    }

    private func startMnt2() {
        guard !isBusy else { return }
        isMountingMnt2 = true
        progress = 0.05
        activityText = "Connecting to Ramdisk SSH…"
        appendLog("Mounting mnt2", success: true)

        Task {
            do {
                try await mnt2Service.mountOld { line in
                    guard ContentView.shouldPublishMnt2Output(line) else { return }
                    let displayLine = ContentView.displayLogText(line)
                    Task { @MainActor in
                        updateMnt2Progress(from: displayLine)
                        appendLog(displayLine, success: true)
                    }
                }
                await MainActor.run {
                    activityText = "/mnt2 mount complete"
                    progress = 1.0
                    appendLog("/mnt2 ready", success: true)
                    operationSuccessTitle = "mnt2 success"
                    operationSuccessMessage = "/mnt2 is mounted and ready."
                    showOperationSuccess = true
                    isMountingMnt2 = false
                }
            } catch {
                await MainActor.run {
                    activityText = "mnt2 mount failed"
                    progress = 0
                    operationErrorTitle = "mnt2 mount failed"
                    operationErrorMessage = error.localizedDescription
                    showOperationError = true
                    appendLog("mnt2 failed: \(error.localizedDescription)", success: false)
                    isMountingMnt2 = false
                }
            }
        }
    }

    private func updateMnt2Progress(from line: String) {
        let value = line.lowercased()
        if value.contains("/mnt2 ready") || value.contains("mnt2 is mounted") {
            progress = max(progress, 0.95)
            activityText = "Verifying /mnt2…"
        } else if value.contains("run remote mount helper") || value.contains("mount mode") || value.contains("mount data") {
            progress = max(progress, 0.70)
            activityText = "Mounting mnt2"
        } else if value.contains("ssh") || value.contains("wait device") || value.contains("connected") {
            progress = max(progress, 0.45)
            activityText = "Ramdisk SSH Connected"
        } else if value.contains("iproxy") {
            progress = max(progress, 0.20)
            activityText = "Starting USB SSH forwarding…"
        } else if value.contains("decrypt") {
            progress = max(progress, 0.10)
        }
    }

    private func updateRamdiskProgress(from line: String) {
        let value = line.lowercased()
        if value.contains("bootx") {
            progress = max(progress, 0.95)
            activityText = "Starting Ramdisk…"
        } else if value.contains("boot_order") || value.contains("send sequence") {
            progress = max(progress, 0.72)
            activityText = "Sending Ramdisk components…"
        } else if value.contains("ibss") {
            progress = max(progress, 0.58)
            activityText = "Loading iBSS…"
        } else if value.contains("gaster") || value.contains("pwn stage") {
            progress = max(progress, 0.45)
            activityText = "Preparing PWNDFU…"
        } else if value.contains("sep") || value.contains("ipsw") {
            progress = max(progress, 0.30)
            activityText = "Preparing SEP for iOS \(ramdiskIOSVersion)…"
        } else {
            progress = max(progress, 0.10)
        }
    }

    private func prepareErase() {
        guard !isErasing else { return }
        guard let device = detectedDevice else {
            activityText = "Obliteration not started"
            appendLog("No USB device detected", success: false)
            return
        }
        guard device.isSupported else {
            activityText = "Obliteration not started"
            appendLog("Device \(device.displayName) is not in the supported device list", success: false)
            return
        }
        guard device.isPwndfu else {
            activityText = "Obliteration not started"
            appendLog("Put the device into PWNDFU mode first", success: false)
            return
        }

        activityText = "Waiting for obliteration confirmation"
        appendLog("Preflight passed: supported device / PWNDFU", success: true)
        showEraseConfirmation = true
    }

    private func startErase() {
        guard !isErasing, let device = detectedDevice else { return }
        isErasing = true
        progress = 0.04
        activityText = "Starting the obliteration process…"
        appendLog("Starting obliteration for  \(device.displayName)", success: true)

        Task {
            do {
                try await restoreService.erase(device: device) { step in
                    Task { @MainActor in
                        activityText = step.title
                        progress = step.progress
                        appendLog(step.title, success: true)
                    }
                }
                await MainActor.run {
                    activityText = "Obliteration command sent; device is rebooting"
                    progress = 1.0
                    appendLog("Obliteration workflow complete", success: true)
                    isErasing = false
                }
            } catch {
                await MainActor.run {
                    activityText = "Obliteration failed"
                    appendLog("Obliteration failed: \(error.localizedDescription)", success: false)
                    isErasing = false
                }
            }
        }
    }

    nonisolated private static func shouldPublishHelloNoChangeOutput(_ line: String) -> Bool {
        let value = line.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = value.lowercased()
        return value.hasPrefix("[+")
            || value.hasPrefix("[!")
            || value.hasPrefix("[-")
            || lower.contains("step:")
            || lower.contains("ssh connected")
            || lower.contains("native identity")
            || lower.contains("stage 1/3")
            || lower.contains("stage 2/3")
            || lower.contains("stage 3/3")
            || lower.contains("fresh ticket")
            || lower.contains("strict final verification")
            || lower.contains("mobilegestalt unchanged")
            || lower.contains("replay complete")
            || lower.contains("decrypt")
    }

    nonisolated private static func shouldPublishRestoreFileOutput(_ line: String) -> Bool {
        let value = line.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = value.lowercased()
        return value.hasPrefix("[+")
            || value.hasPrefix("[!")
            || value.hasPrefix("[-")
            || lower.contains("ssh connected")
            || lower.contains("mount")
            || lower.contains("upload")
            || lower.contains("restore ")
            || lower.contains("verify")
            || lower.contains("done")
            || lower.contains("decrypt")
    }

    nonisolated private static func shouldPublishExtractFileOutput(_ line: String) -> Bool {
        let value = line.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = value.lowercased()
        return value.hasPrefix("[+")
            || value.hasPrefix("[!")
            || value.hasPrefix("[-")
            || lower.contains("ssh connected")
            || lower.contains("iproxy")
            || lower.contains("mount/setup")
            || lower.contains("/mnt2")
            || lower.contains("download")
            || lower.contains("create zip")
            || lower.contains("final extract")
            || lower.contains("done")
            || lower.contains("decrypt")
    }

    nonisolated private static func shouldPublishMnt2Output(_ line: String) -> Bool {
        let value = line.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = value.lowercased()
        return value.hasPrefix("[+")
            || value.hasPrefix("[!")
            || value.hasPrefix("[-")
            || lower.contains("mnt2")
            || lower.contains("iproxy")
            || lower.contains("ssh")
            || lower.contains("mount mode")
            || lower.contains("mount data")
            || lower.contains("remote-old")
            || lower.contains("decrypt")
    }

    nonisolated private static func shouldPublishRamdiskOutput(_ line: String) -> Bool {
        let value = line.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = value.lowercased()
        return value.hasPrefix("[+")
            || value.hasPrefix("[!")
            || value.hasPrefix("[-")
            || lower.contains("ramdisk")
            || lower.contains("sep")
            || lower.contains("ipsw")
            || lower.contains("gaster")
            || lower.contains("ibss")
            || lower.contains("bootx")
            || lower.contains("boot_order")
    }

    nonisolated private static func displayLogText(_ text: String) -> String {
        let singleLine = text
            .replacingOccurrences(of: "\r", with: " ")
            .split(whereSeparator: \.isNewline)
            .first
            .map(String.init) ?? ""
        guard singleLine.count > 220 else { return singleLine }
        return String(singleLine.prefix(217)) + "…"
    }

    private func appendLog(_ text: String, success: Bool) {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        logs.append(.init(
            time: formatter.string(from: Date()),
            text: Self.displayLogText(text),
            success: success
        ))
        if logs.count > 6 { logs.removeFirst(logs.count - 6) }
    }

    private func runPreviewAction(_ title: String) {
        activityText = "Preparing \(title)"
        progress = min(0.94, progress + 0.04)
        appendLog("Selected \(title)", success: true)
    }
}

enum BrandedModalButtonKind {
    case primary
    case secondary
    case destructive
}

struct BrandedModalButton: View {
    let title: String
    let symbol: String
    let style: BrandedModalButtonKind
    var isEnabled: Bool = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: symbol)
                Text(title)
            }
            .font(.system(size: 12, weight: .bold))
            .foregroundColor(foregroundColor)
            .frame(maxWidth: .infinity)
            .frame(height: 36)
            .background {
                background
            }
            .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
            .overlay {
                if style == .secondary {
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .stroke(AppColors.greenDark.opacity(0.12), lineWidth: 1)
                }
            }
            .shadow(
                color: style == .secondary ? .clear : shadowColor,
                radius: 7,
                x: 0,
                y: 4
            )
        }
        .buttonStyle(PressableButtonStyle())
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.42)
    }

    private var foregroundColor: Color {
        style == .secondary ? AppColors.greenDark : .white
    }

    private var shadowColor: Color {
        switch style {
        case .primary: return AppColors.greenDark.opacity(0.20)
        case .destructive: return AppColors.pink.opacity(0.24)
        case .secondary: return .clear
        }
    }

    @ViewBuilder
    private var background: some View {
        switch style {
        case .primary:
            LinearGradient(
                colors: [AppColors.green, AppColors.greenDark],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        case .secondary:
            Color.white.opacity(0.78)
        case .destructive:
            LinearGradient(
                colors: [AppColors.pink, Color(red: 0.76, green: 0.27, blue: 0.40)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
    }
}

struct BrandedModalCard<Content: View, Actions: View>: View {
    let symbol: String
    let eyebrow: String
    let title: String
    let message: String
    let accent: Color
    private let content: Content
    private let actions: Actions

    init(
        symbol: String,
        eyebrow: String,
        title: String,
        message: String,
        accent: Color,
        @ViewBuilder content: () -> Content,
        @ViewBuilder actions: () -> Actions
    ) {
        self.symbol = symbol
        self.eyebrow = eyebrow
        self.title = title
        self.message = message
        self.accent = accent
        self.content = content()
        self.actions = actions()
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [accent.opacity(0.22), AppColors.purplePale.opacity(0.86)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 54, height: 54)
                Image(systemName: symbol)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundColor(accent == AppColors.pink ? Color(red: 0.68, green: 0.22, blue: 0.34) : AppColors.greenDark)
            }
            .padding(.top, 18)

            Text(eyebrow)
                .font(.system(size: 10, weight: .bold))
                .tracking(1.8)
                .foregroundColor(accent.opacity(0.86))
                .padding(.top, 10)

            Text(title)
                .font(.system(size: 18, weight: .bold))
                .foregroundColor(AppColors.ink)
                .multilineTextAlignment(.center)
                .padding(.top, 5)
                .padding(.horizontal, 28)

            Text(message)
                .font(.system(size: 11.5))
                .foregroundColor(AppColors.secondaryText)
                .multilineTextAlignment(.center)
                .lineSpacing(4)
                .textSelection(.enabled)
                .padding(.top, 8)
                .padding(.horizontal, 26)

            content
                .padding(.top, 12)
                .padding(.horizontal, 20)

            actions
                .padding(.top, 16)
                .padding(.horizontal, 20)
                .padding(.bottom, 18)
        }
        .frame(width: 370)
        .background(.ultraThinMaterial)
        .background(Color.white.opacity(0.68))
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(Color.white.opacity(0.84), lineWidth: 1)
        )
        .shadow(color: AppColors.ink.opacity(0.20), radius: 26, x: 0, y: 14)
    }
}

struct FlowingGradientBackground: View {
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.88, green: 0.98, blue: 0.93),
                    Color(red: 0.99, green: 0.98, blue: 0.98),
                    Color(red: 1.00, green: 0.92, blue: 0.95)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            Circle()
                .fill(AppColors.greenBright.opacity(0.18))
                .frame(width: 620, height: 620)
                .blur(radius: 100)
                .offset(x: -360, y: -260)

            Circle()
                .fill(AppColors.pink.opacity(0.20))
                .frame(width: 700, height: 700)
                .blur(radius: 115)
                .offset(x: 390, y: 300)
        }
        .ignoresSafeArea()
    }
}

struct SummaryCard: View {
    let symbol: String
    let tint: Color
    let label: String
    let value: String
    let status: String
    let statusColor: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(AppColors.ink)
                    .frame(width: 34, height: 34)
                    .background(tint)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                Spacer()
                Circle()
                    .fill(statusColor.opacity(0.82))
                    .frame(width: 7, height: 7)
            }
            Spacer()
            Text(label)
                .font(.system(size: 10))
                .foregroundColor(AppColors.tertiaryText)
            Text(value)
                .font(.system(size: 14, weight: .bold))
                .foregroundColor(AppColors.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
                .padding(.top, 3)
            Text(status)
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundColor(statusColor)
                .lineLimit(1)
                .padding(.top, 4)
        }
        .padding(15)
        .frame(maxWidth: .infinity, minHeight: 124, alignment: .leading)
        .background(Color.white.opacity(0.56))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(AppColors.ink.opacity(0.07), lineWidth: 1))
        .softShadow()
    }
}

struct IdentityRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(spacing: 15) {
            Text(label)
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(AppColors.tertiaryText)
                .frame(width: 38, alignment: .leading)
            Text(value)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundColor(AppColors.ink)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .frame(height: 38)
    }
}

struct PanelCard<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .font(.system(size: 14, weight: .bold))
                .foregroundColor(AppColors.ink)
            content
        }
        .padding(22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.56))
        .clipShape(RoundedRectangle(cornerRadius: 21, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 21).stroke(AppColors.ink.opacity(0.065), lineWidth: 1))
        .softShadow()
    }
}

struct DeviceRow: View {
    let symbol: String
    let title: String
    let subtitle: String
    var status: String? = nil

    var body: some View {
        HStack(spacing: 13) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 36, height: 36)
                .background(LinearGradient(colors: [AppColors.greenPale, AppColors.pinkPale], startPoint: .topLeading, endPoint: .bottomTrailing))
                .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(AppColors.ink)
                Text(subtitle)
                    .font(.system(size: 9.5))
                    .foregroundColor(AppColors.tertiaryText)
                    .lineLimit(1)
            }
            Spacer()
            if let status {
                Text(status)
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundColor(AppColors.greenDark)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 6)
                    .background(AppColors.greenPale)
                    .clipShape(Capsule())
            }
        }
        .padding(.vertical, 7)
    }
}

struct ActionButton: View {
    let item: ActionItem
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: item.symbol)
                    .font(.system(size: 15, weight: .semibold))
                Text(item.title)
                    .font(.system(size: 10, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
            }
            .frame(maxWidth: .infinity, minHeight: 54)
            .foregroundColor(item.foreground)
            .background(item.background)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(item.border, lineWidth: 1))
        }
        .buttonStyle(PressableButtonStyle())
    }
}

struct PressableButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.975 : 1)
            .opacity(configuration.isPressed ? 0.88 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct LogLine: Identifiable {
    let id = UUID()
    let time: String
    let text: String
    let success: Bool
}

struct ActionItem: Identifiable {
    enum Kind { case normal, primary, destructive, reboot }
    let id = UUID()
    let title: String
    let symbol: String
    let kind: Kind

    var background: Color {
        switch kind {
        case .normal: return Color.white.opacity(0.55)
        case .primary: return AppColors.greenPale.opacity(0.9)
        case .destructive: return AppColors.pinkPale.opacity(0.96)
        case .reboot: return AppColors.greenDark
        }
    }

    var foreground: Color {
        switch kind {
        case .destructive: return Color(red: 0.72, green: 0.25, blue: 0.38)
        case .reboot: return .white
        default: return AppColors.greenDark
        }
    }

    var border: Color {
        switch kind {
        case .destructive: return AppColors.pink.opacity(0.32)
        case .reboot: return Color.clear
        default: return AppColors.ink.opacity(0.07)
        }
    }
}

enum AppColors {
    static let ink = Color(red: 0.13, green: 0.24, blue: 0.20)
    static let secondaryText = Color(red: 0.35, green: 0.45, blue: 0.41)
    static let tertiaryText = Color(red: 0.48, green: 0.57, blue: 0.53)
    static let green = Color(red: 0.24, green: 0.76, blue: 0.51)
    static let greenBright = Color(red: 0.35, green: 0.84, blue: 0.62)
    static let greenDark = Color(red: 0.18, green: 0.36, blue: 0.29)
    static let greenPale = Color(red: 0.85, green: 0.97, blue: 0.90)
    static let pink = Color(red: 0.93, green: 0.58, blue: 0.70)
    static let pinkPale = Color(red: 1.00, green: 0.90, blue: 0.93)
    static let purplePale = Color(red: 0.93, green: 0.91, blue: 0.99)
    static let logBackground = Color(red: 0.12, green: 0.21, blue: 0.18)
}

extension View {
    func softShadow() -> some View {
        shadow(color: AppColors.ink.opacity(0.07), radius: 18, x: 0, y: 9)
    }
}
