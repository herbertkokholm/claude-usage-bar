import SwiftUI
import AppKit
import ServiceManagement

@main
struct ClaudeUsageBarApp: App {
    @StateObject private var service = UsageService()
    @StateObject private var historyService = UsageHistoryService()
    @StateObject private var notificationService = NotificationService()
    @StateObject private var appUpdater = AppUpdater()
    @State private var statusMonitor: StatusMonitor = {
        StatusMonitor(client: StatusPageClient())
    }()

    @AppStorage(AppearanceDefaultsKey.showResetDivider) private var showResetDivider = false
    @AppStorage(AppearanceDefaultsKey.coloredResetDivider) private var coloredResetDivider = true
    @AppStorage(AppearanceDefaultsKey.showServiceStatus) private var showServiceStatus = false
    @AppStorage(AppearanceDefaultsKey.showOverlayWhenOperational) private var showOverlayWhenOperational = false
    @AppStorage(AppearanceDefaultsKey.statusPollMinutes) private var statusPollMinutes = StatusPollOptions.default

    var body: some Scene {
        MenuBarExtra {
            PopoverView(
                service: service,
                historyService: historyService,
                notificationService: notificationService,
                appUpdater: appUpdater,
                statusMonitor: statusMonitor
            )
        } label: {
            Image(nsImage: iconImage())
                .task {
                    // Auto-mark existing users as setup-complete
                    if service.isAuthenticated && !UserDefaults.standard.bool(forKey: "setupComplete") {
                        UserDefaults.standard.set(true, forKey: "setupComplete")
                    }
                    // Re-register launch-at-login on every startup so macOS system events
                    // or app updates that silently clear the SMAppService registration are
                    // repaired automatically without the user having to re-toggle the setting.
                    // For users who enabled the feature before intent was persisted to
                    // UserDefaults, fall back to the live system status and save it.
                    let launchAtLoginIntentKey = "launchAtLoginIntent"
                    let launchAtLoginIntent: Bool
                    if UserDefaults.standard.object(forKey: launchAtLoginIntentKey) != nil {
                        launchAtLoginIntent = UserDefaults.standard.bool(forKey: launchAtLoginIntentKey)
                    } else {
                        launchAtLoginIntent = SMAppService.mainApp.status == .enabled
                        UserDefaults.standard.set(launchAtLoginIntent, forKey: launchAtLoginIntentKey)
                    }
                    if launchAtLoginIntent {
                        try? SMAppService.mainApp.register()
                    }
                    historyService.loadHistory()
                    service.historyService = historyService
                    service.notificationService = notificationService
                    service.startPolling()
                    if showServiceStatus {
                        statusMonitor.start()
                    }
                }
                .onChange(of: showServiceStatus) { _, enabled in
                    if enabled {
                        statusMonitor.start()
                    } else {
                        statusMonitor.stop()
                    }
                }
                .onChange(of: statusPollMinutes) { _, minutes in
                    statusMonitor.updateInterval(minutes)
                }
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsWindowContent(
                service: service,
                notificationService: notificationService
            )
        }
        .windowResizability(.contentSize)
        .windowStyle(.titleBar)
    }

    @MainActor
    private func iconImage() -> NSImage {
        guard service.isAuthenticated else { return renderUnauthenticatedIcon() }
        let now = Date()
        let pos5 = service.usage?.fiveHour?.resetPosition(windowSeconds: 5 * 3600, now: now)
        let pos7 = service.usage?.sevenDay?.resetPosition(windowSeconds: 7 * 24 * 3600, now: now)
        let usagePct5 = service.pct5h * 100
        let usagePct7 = service.pct7d * 100
        let state5 = resetIndicatorState(
            usagePct: usagePct5,
            timeLeftFraction: 1.0 - (pos5 ?? .zero)
        )
        let state7 = resetIndicatorState(
            usagePct: usagePct7,
            timeLeftFraction: 1.0 - (pos7 ?? .zero)
        )
        return renderIcon(MenuBarIconParams(
            pct5h: service.pct5h,
            pct7d: service.pct7d,
            resetPos5h: pos5,
            state5h: state5,
            resetPos7d: pos7,
            state7d: state7,
            showResetDivider: showResetDivider,
            coloredResetDivider: coloredResetDivider,
            statusOverlay: serviceStatusOverlay()
        ))
    }

    /// Map the current monitor snapshot to a renderer overlay. Returns nil when the feature flag
    /// is off, the snapshot is missing, or the rollup is operational without the opt-in green toggle.
    @MainActor
    private func serviceStatusOverlay() -> ServiceStatusOverlay? {
        guard showServiceStatus, let snap = statusMonitor.snapshot else { return nil }
        return switch snap.rollup {
        case .operational:      
            nil
        case .underMaintenance: 
            ServiceStatusOverlay(color: .yellow)
        case .degradedPerformance, .partialOutage:
            ServiceStatusOverlay(color: .orange)
        case .majorOutage:
            ServiceStatusOverlay(color: .red)
        }
    }
}
