import SwiftUI
import AppKit

struct CustomResolutionFormView: View {
    let displayManager: DisplayManager
    let display: DisplayInfo
    let onDismiss: () -> Void

    @State private var widthText = ""
    @State private var heightText = ""
    @State private var refreshRateText = ""
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Custom Resolution for \(display.name)")
                .font(.headline)

            HStack {
                VStack(alignment: .leading) {
                    Text("Width")
                        .font(.caption)
                    TextField("2560", text: $widthText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 100)
                }
                Text("\u{00d7}")
                    .font(.title2)
                VStack(alignment: .leading) {
                    Text("Height")
                        .font(.caption)
                    TextField("1440", text: $heightText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 100)
                }
            }

            VStack(alignment: .leading) {
                Text("Refresh Rate (optional)")
                    .font(.caption)
                TextField("60", text: $refreshRateText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 100)
            }

            if let error = errorMessage {
                Text(error)
                    .foregroundStyle(.red)
                    .font(.caption)
            }

            HStack {
                Spacer()
                Button("Cancel") {
                    onDismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button("Save Only") {
                    saveOnly()
                }
                .disabled(widthText.isEmpty || heightText.isEmpty)

                Button("Save & Apply") {
                    saveAndApply()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(widthText.isEmpty || heightText.isEmpty)
            }

            Text("Resolution will be matched against all available display modes (including hidden ones).")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(width: 340)
    }

    private func saveOnly() {
        guard let width = Int(widthText), width > 0,
              let height = Int(heightText), height > 0 else {
            errorMessage = "Enter valid width and height values."
            return
        }
        let refreshRate: Double? = refreshRateText.isEmpty ? nil : Double(refreshRateText)
        let custom = CustomResolution(width: width, height: height, refreshRate: refreshRate)
        displayManager.addCustomResolution(custom)
        onDismiss()
    }

    private func saveAndApply() {
        guard let width = Int(widthText), width > 0,
              let height = Int(heightText), height > 0 else {
            errorMessage = "Enter valid width and height values."
            return
        }

        let refreshRate: Double? = refreshRateText.isEmpty ? nil : Double(refreshRateText)
        if !refreshRateText.isEmpty && refreshRate == nil {
            errorMessage = "Enter a valid refresh rate."
            return
        }

        let custom = CustomResolution(width: width, height: height, refreshRate: refreshRate)
        displayManager.addCustomResolution(custom)

        if let match = displayManager.findMatchingMode(
            width: width, height: height,
            refreshRate: refreshRate,
            in: display
        ) {
            displayManager.applyMode(match, to: display)
            onDismiss()
            return
        }

        let success = PrivateDisplayAPI.applyCustomResolution(
            width: width,
            height: height,
            refreshRate: refreshRate.map { Int($0) },
            displayID: display.id
        )

        if success {
            displayManager.refresh()
            onDismiss()
        } else {
            errorMessage = "Saved, but no matching mode found for \(width)\u{00d7}\(height). This display doesn't support this resolution."
        }
    }
}
