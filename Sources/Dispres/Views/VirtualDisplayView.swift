import SwiftUI
import AppKit

struct VirtualDisplayMenuSection: View {
    @EnvironmentObject var virtualDisplayService: VirtualDisplayService
    var openCreatePanel: () -> Void

    var body: some View {
        Menu {
            if virtualDisplayService.configs.isEmpty {
                Text("No virtual displays configured")
            } else {
                ForEach(virtualDisplayService.configs) { config in
                    let active = virtualDisplayService.isActive(config.id)
                    Button {
                        Task {
                            await virtualDisplayService.toggleActive(config: config)
                        }
                    } label: {
                        let status = active ? "\u{2713} " : "   "
                        Text("\(status)\(config.label)")
                    }
                }

                Divider()

                // Remove submenu
                Menu("Remove Virtual Display") {
                    ForEach(virtualDisplayService.configs) { config in
                        Button("Remove \(config.name)") {
                            virtualDisplayService.removeConfig(id: config.id)
                        }
                    }
                }
            }

            Divider()

            Button("Create Virtual Display\u{2026}") {
                openCreatePanel()
            }
        } label: {
            Label("Virtual Displays", systemImage: "rectangle.on.rectangle.angled")
        }
    }
}

// MARK: - Create Virtual Display Form

struct CreateVirtualDisplayFormView: View {
    let virtualDisplayService: VirtualDisplayService
    let onDismiss: @MainActor () -> Void

    @State private var name = "Virtual Display"
    @State private var widthText = "2560"
    @State private var heightText = "1440"
    @State private var refreshRate = 60.0
    @State private var hiDPI = true
    @State private var autoCreate = true
    @State private var isCreating = false
    @State private var errorMessage: String?

    private let presets: [(String, Int, Int)] = [
        ("1080p", 1920, 1080),
        ("1440p", 2560, 1440),
        ("4K", 3840, 2160),
        ("Ultrawide", 3440, 1440),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Create Virtual Display")
                .font(.headline)

            // Presets
            HStack(spacing: 8) {
                ForEach(presets, id: \.0) { preset in
                    Button(preset.0) {
                        widthText = "\(preset.1)"
                        heightText = "\(preset.2)"
                        name = "\(preset.0) Virtual"
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }

            // Name
            TextField("Display Name", text: $name)
                .textFieldStyle(.roundedBorder)

            // Resolution
            HStack {
                VStack(alignment: .leading) {
                    Text("Width").font(.caption)
                    TextField("2560", text: $widthText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 80)
                }
                Text("\u{00d7}").font(.title2)
                VStack(alignment: .leading) {
                    Text("Height").font(.caption)
                    TextField("1440", text: $heightText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 80)
                }
                VStack(alignment: .leading) {
                    Text("Hz").font(.caption)
                    Picker("", selection: $refreshRate) {
                        Text("60").tag(60.0)
                        Text("50").tag(50.0)
                        Text("30").tag(30.0)
                    }
                    .frame(width: 60)
                }
            }

            Toggle("HiDPI (Retina)", isOn: $hiDPI)
            Toggle("Auto-create on launch", isOn: $autoCreate)

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

                Button(isCreating ? "Creating\u{2026}" : "Create") {
                    createDisplay()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(isCreating || widthText.isEmpty || heightText.isEmpty)
            }

            Text("Creates a virtual display visible to RustDesk and other remote desktop apps.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(width: 380)
    }

    private func createDisplay() {
        guard let width = Int(widthText), width > 0,
              let height = Int(heightText), height > 0 else {
            errorMessage = "Enter valid width and height."
            return
        }

        isCreating = true
        errorMessage = nil

        let config = VirtualDisplayConfig(
            name: name,
            width: width,
            height: height,
            refreshRate: refreshRate,
            hiDPI: hiDPI,
            autoCreate: autoCreate
        )

        Task {
            let success = await virtualDisplayService.addAndCreate(config)
            isCreating = false
            if success {
                onDismiss()
            } else {
                errorMessage = "Failed to create virtual display. The CGVirtualDisplay API may not be available on this system."
            }
        }
    }
}
