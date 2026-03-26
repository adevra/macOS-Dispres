import SwiftUI

struct MenuContentView: View {
    @EnvironmentObject var displayManager: DisplayManager
    @EnvironmentObject var virtualDisplayService: VirtualDisplayService
    @EnvironmentObject var loginItemService: LoginItemService
    var openCustomResolution: (DisplayInfo) -> Void
    var openCreateVirtualDisplay: () -> Void

    var body: some View {
        ForEach(displayManager.displays) { display in
            DisplaySectionView(display: display, openCustomResolution: openCustomResolution)
        }

        Divider()

        VirtualDisplayMenuSection(openCreatePanel: openCreateVirtualDisplay)

        Divider()

        Button("Refresh Displays") {
            displayManager.refresh()
        }
        .keyboardShortcut("r")

        Divider()

        Button {
            loginItemService.toggle()
        } label: {
            let check = loginItemService.isEnabled ? "\u{2713} " : "   "
            Text("\(check)Launch at Login")
        }

        Button("About Dispres") {
            showAbout()
        }

        Button("Quit") {
            displayManager.saveState()
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
    }

    private func showAbout() {
        let alert = NSAlert()
        alert.messageText = "Dispres"
        alert.informativeText = """
        Version 1.0

        A simple macOS display resolution switcher.
        Supports standard, custom, and virtual resolutions.
        Remembers display state across restarts.

        Uses CoreGraphics display management APIs.
        """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        NSApp.activate()
        alert.runModal()
    }
}
