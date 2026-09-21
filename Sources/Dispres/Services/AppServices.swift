import Foundation

/// Owns the long-lived services and starts them at launch.
///
/// `MenuBarExtra` builds its content lazily, so `.onAppear` on that content is not a
/// launch hook — it fires the first time the user opens the menu. Bootstrapping there
/// left auto-created virtual displays, the clamshell monitor and the recovery hot key
/// all dormant until the menu bar icon happened to be clicked.
@MainActor
final class AppServices {
    static let shared = AppServices()

    let displayManager = DisplayManager()
    let virtualDisplayService = VirtualDisplayService()
    let loginItemService = LoginItemService()
    let recoveryCoordinator = RecoveryCoordinator()

    private var bootstrapped = false

    private init() {}

    func bootstrap() {
        guard !bootstrapped else { return }
        bootstrapped = true

        // Configure first: DisplayManager needs to know which displays are virtual
        // before it enumerates or restores anything.
        recoveryCoordinator.configure(
            displayManager: displayManager,
            virtualDisplayService: virtualDisplayService
        )
        displayManager.start()
        virtualDisplayService.startup()

        // Restore saved state once virtual displays have had time to come up, then
        // arm for the lid. Order matters: restoreState applies the saved main display,
        // so arming before it would be undone two seconds later.
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            displayManager.restoreState()
            recoveryCoordinator.armIfLidClosed()
        }
    }
}
