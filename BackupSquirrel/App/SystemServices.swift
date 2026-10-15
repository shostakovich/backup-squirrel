import AppKit
import ServiceManagement
import UserNotifications

@MainActor
enum SystemServices {
    /// Asked asynchronously and kept here, so `inspect()` can stay synchronous.
    private static var notificationPermission = NotificationPermission.notDetermined

    static func inspect() -> SystemState {
        let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        let volumes = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: nil, options: []) ?? []
        return SystemState(
            hasFullDiskAccess: FullDiskAccessProbe.isGranted(home: home) { url in
                _ = try FileManager.default.contentsOfDirectory(atPath: url.path)
            },
            opensAtLogin: loginItemStatus == .enabled,
            notifications: notificationPermission,
            mountedVolumes: Set(volumes.map(\.standardizedFileURL.path))
        )
    }

    static var loginItemStatus: LoginItemStatus {
        switch SMAppService.mainApp.status {
        case .enabled: .enabled
        case .requiresApproval: .requiresApproval
        case .notRegistered: .notRegistered
        case .notFound: .notFound
        @unknown default: .notFound
        }
    }

    static func registerLoginItemIfInstalled() {
        guard LoginItemPolicy.shouldRegister(appURL: Bundle.main.bundleURL, status: loginItemStatus) else { return }
        try? SMAppService.mainApp.register()
    }

    static func refreshNotificationPermission() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        notificationPermission =
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral: .allowed
            case .denied: .denied
            case .notDetermined: .notDetermined
            @unknown default: .denied
            }
    }

    /// Asks once; after a refusal only System Settings can allow notifications.
    static func allowNotifications() async {
        await refreshNotificationPermission()
        switch notificationPermission {
        case .notDetermined:
            _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
            await refreshNotificationPermission()
        case .denied:
            openNotificationSettings()
        case .allowed:
            break
        }
    }

    static func fix(_ problem: SystemProblem, then refresh: @escaping @MainActor () -> Void) {
        switch problem {
        case .noFullDiskAccess: openFullDiskAccessSettings()
        case .notOpeningAtLogin: openLoginItemsSettings()
        case .notificationsOff:
            Task {
                await allowNotifications()
                refresh()
            }
        }
    }

    static func openFullDiskAccessSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")
    }

    static func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    static func openNotificationSettings() {
        open(
            "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(Bundle.main.bundleIdentifier ?? "")"
        )
    }

    private static func open(_ address: String) {
        guard let url = URL(string: address) else { return }
        NSWorkspace.shared.open(url)
    }
}
