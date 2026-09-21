import SwiftUI

@main
struct DispresApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var displayManager = AppServices.shared.displayManager
    @StateObject private var virtualDisplayService = AppServices.shared.virtualDisplayService
    @StateObject private var loginItemService = AppServices.shared.loginItemService
    @StateObject private var recoveryCoordinator = AppServices.shared.recoveryCoordinator

    var body: some Scene {
        MenuBarExtra("Dispres", systemImage: "display") {
            MenuContentView(
                openCustomResolution: { display in
                    AppDelegate.shared?.showPanel(
                        title: "Custom Resolution — \(display.name)",
                        size: NSSize(width: 340, height: 280)
                    ) { onDismiss in
                        CustomResolutionFormView(
                            displayManager: displayManager,
                            display: display,
                            onDismiss: onDismiss
                        )
                    }
                },
                openCreateVirtualDisplay: {
                    AppDelegate.shared?.showPanel(
                        title: "Create Virtual Display",
                        size: NSSize(width: 400, height: 380)
                    ) { onDismiss in
                        CreateVirtualDisplayFormView(
                            virtualDisplayService: virtualDisplayService,
                            onDismiss: onDismiss
                        )
                    }
                }
            )
            .environmentObject(displayManager)
            .environmentObject(virtualDisplayService)
            .environmentObject(loginItemService)
            .environmentObject(recoveryCoordinator)
            .onAppear {
                // Already done at launch; a no-op safety net.
                AppServices.shared.bootstrap()
            }
        }
        .menuBarExtraStyle(.menu)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static weak var shared: AppDelegate?
    private var panelWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.shared = self
        AppServices.shared.bootstrap()
        ProcessInfo.processInfo.disableAutomaticTermination("Menu bar app must stay running")
        ProcessInfo.processInfo.disableSuddenTermination()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        // State is saved automatically when changes are made
    }

    /// Generic panel presenter — avoids the NSHostingView + NSWindow(contentViewController:) crash.
    func showPanel<V: View>(
        title: String,
        size: NSSize,
        @ViewBuilder content: (@escaping @MainActor () -> Void) -> V
    ) {
        panelWindow?.close()
        panelWindow = nil

        let dismiss: @MainActor () -> Void = { [weak self] in
            self?.panelWindow?.close()
            self?.panelWindow = nil
        }

        let hostingView = NSHostingView(rootView: content(dismiss))
        hostingView.frame = NSRect(origin: .zero, size: size)

        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        panel.contentView = hostingView
        panel.title = title
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = false
        panel.center()

        self.panelWindow = panel

        NSApp.setActivationPolicy(.regular)
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            NSApp.setActivationPolicy(.accessory)
        }
    }
}
