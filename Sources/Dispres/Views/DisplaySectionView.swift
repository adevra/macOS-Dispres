import SwiftUI

struct DisplaySectionView: View {
    @EnvironmentObject var displayManager: DisplayManager
    let display: DisplayInfo
    var openCustomResolution: (DisplayInfo) -> Void

    var body: some View {
        let icon = display.isBuiltIn ? "laptopcomputer" : "display"
        Menu {
            // Current mode info header
            if let current = display.currentMode {
                Text("Current: \(current.resolutionLabel) (\(current.bitDepth))")
                Divider()
            }

            // Set as main display
            let isMain = CGDisplayIsMain(display.id) != 0
            Button {
                displayManager.setAsMainDisplay(display)
            } label: {
                let check = isMain ? "\u{2713} " : "   "
                Text("\(check)Main Display")
            }
            .disabled(isMain)

            Divider()

            // Standard modes
            ForEach(display.modes) { mode in
                Button {
                    displayManager.applyMode(mode, to: display)
                } label: {
                    let check = (mode == display.currentMode) ? "\u{2713} " : "   "
                    Text("\(check)\(mode.resolutionLabel)")
                }
                .disabled(mode == display.currentMode)
            }

            // Custom resolutions
            if !displayManager.customResolutions.isEmpty {
                Divider()
                Text("Custom Resolutions")
                ForEach(displayManager.customResolutions) { custom in
                    Button(custom.label) {
                        applyCustomResolution(custom, to: display)
                    }
                }

                Menu("Remove Custom Resolution") {
                    ForEach(displayManager.customResolutions) { custom in
                        Button("Remove \(custom.label)") {
                            displayManager.removeCustomResolution(custom)
                        }
                    }
                }
            }

            Divider()

            Button("Add Custom Resolution\u{2026}") {
                openCustomResolution(display)
            }

        } label: {
            Label(display.name, systemImage: icon)
        }
    }

    private func applyCustomResolution(_ custom: CustomResolution, to display: DisplayInfo) {
        if let match = displayManager.findMatchingMode(
            width: custom.width,
            height: custom.height,
            refreshRate: custom.refreshRate,
            in: display
        ) {
            displayManager.applyMode(match, to: display)
            return
        }

        let success = PrivateDisplayAPI.applyCustomResolution(
            width: custom.width,
            height: custom.height,
            refreshRate: custom.refreshRate.map { Int($0) },
            displayID: display.id
        )

        if success {
            displayManager.refresh()
        } else {
            let alert = NSAlert()
            alert.messageText = "Custom Resolution Failed"
            alert.informativeText = "Could not apply \(custom.label) to \(display.name). The display may not support this resolution."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }
}
