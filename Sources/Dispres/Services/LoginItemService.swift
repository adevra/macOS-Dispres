import Foundation
import ServiceManagement
import SwiftUI

@MainActor
final class LoginItemService: ObservableObject {
    @Published var isEnabled: Bool = false

    private let useSMAppService: Bool

    // LaunchAgent fallback
    private static let plistName = "com.dispres.app.plist"
    private var launchAgentsDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents")
    }
    private var plistURL: URL {
        launchAgentsDir.appendingPathComponent(Self.plistName)
    }
    private var executablePath: String {
        ProcessInfo.processInfo.arguments.first ?? Bundle.main.executablePath ?? ""
    }

    init() {
        // Use SMAppService if running from a .app bundle
        useSMAppService = Bundle.main.bundlePath.hasSuffix(".app")

        if useSMAppService {
            isEnabled = SMAppService.mainApp.status == .enabled
        } else {
            isEnabled = FileManager.default.fileExists(atPath: plistURL.path)
        }
    }

    func toggle() {
        if useSMAppService {
            toggleSMAppService()
        } else {
            toggleLaunchAgent()
        }
    }

    // MARK: - SMAppService (bundled .app)

    private func toggleSMAppService() {
        do {
            if isEnabled {
                try SMAppService.mainApp.unregister()
                isEnabled = false
            } else {
                try SMAppService.mainApp.register()
                isEnabled = true
            }
        } catch {
            isEnabled = SMAppService.mainApp.status == .enabled
        }
    }

    // MARK: - LaunchAgent (unbundled executable)

    private func toggleLaunchAgent() {
        if isEnabled {
            try? FileManager.default.removeItem(at: plistURL)
            isEnabled = false
        } else {
            try? FileManager.default.createDirectory(at: launchAgentsDir, withIntermediateDirectories: true)
            let plist: [String: Any] = [
                "Label": "com.dispres.app",
                "ProgramArguments": [executablePath],
                "RunAtLoad": true,
                "KeepAlive": false,
            ]
            if let data = try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0) {
                try? data.write(to: plistURL)
                isEnabled = true
            }
        }
    }
}
