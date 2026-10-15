import AppKit
import Observation
import UserNotifications

/// Posts problems as notifications whose buttons do the work in the background.
@MainActor
final class NotificationController: NSObject, UNUserNotificationCenterDelegate {
    private nonisolated static let routeKey = "route"
    private nonisolated static let commandKey = "command"

    private let model: AppModel
    private let store: NotifiedAlerts
    private let perform: (MenuAction) -> Void
    private let run: (AlertCommand) -> Void
    private let center = UNUserNotificationCenter.current()
    private var knownAlerts: Set<AlertKey>?

    init(
        model: AppModel, store: NotifiedAlerts, perform: @escaping (MenuAction) -> Void,
        run: @escaping (AlertCommand) -> Void
    ) {
        self.model = model
        self.store = store
        self.perform = perform
        self.run = run
        knownAlerts = store.load()
        super.init()
        center.delegate = self
        center.setNotificationCategories(
            Set(
                AlertCommand.Style.allCases.map { style in
                    let action = UNNotificationAction(
                        identifier: style.rawValue, title: style.title, options: [],
                        icon: UNNotificationActionIcon(systemImageName: style.systemImage))
                    return UNNotificationCategory(identifier: style.rawValue, actions: [action], intentIdentifiers: [])
                }))
        observe()
    }

    private func observe() {
        let state = withObservationTracking {
            model.state
        } onChange: { [weak self] in
            Task { @MainActor in self?.observe() }
        }
        let result = AlertPlanner(calendar: model.calendar).newAlerts(in: state, previous: knownAlerts)
        if result.current != knownAlerts { store.save(result.current) }
        knownAlerts = result.current
        for alert in result.new { post(alert) }
    }

    /// Permission is asked during setup; without it the problem only shows in the menu.
    private func post(_ alert: BackupAlert) {
        let content = UNMutableNotificationContent()
        content.title = alert.title
        content.body = alert.body
        content.categoryIdentifier = alert.style.rawValue
        content.userInfo = [
            Self.routeKey: AlertRoute.encode(alert.route), Self.commandKey: AlertRoute.encode(alert.command),
        ]
        let request = UNNotificationRequest(identifier: alert.key.identifier, content: content, trigger: nil)
        let center = center
        Task { try? await center.add(request) }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse
    ) async {
        let userInfo = response.notification.request.content.userInfo
        let route = (userInfo[Self.routeKey] as? String).flatMap(AlertRoute.decode)
        let command = (userInfo[Self.commandKey] as? String).flatMap(AlertRoute.decodeCommand)
        let isBodyClick = response.actionIdentifier == UNNotificationDefaultActionIdentifier
        let isDismissal = response.actionIdentifier == UNNotificationDismissActionIdentifier
        await MainActor.run {
            if isBodyClick {
                perform(route ?? .showHistory)
            } else if let command, !isDismissal {
                run(command)
            }
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list]
    }
}
