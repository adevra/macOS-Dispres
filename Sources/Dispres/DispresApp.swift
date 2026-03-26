import SwiftUI

@main
struct DispresApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var displayManager = DisplayManager()
    @StateObject private var virtualDisplayService = VirtualDisplayService()
    @StateObject private var loginItemService = LoginItemService()

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
            .onAppear {
                displayManager.start()
                virtualDisplayService.startup()
                // Restore display state after virtual displays have time to come up
                Task {
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    displayManager.restoreState()
                }
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
