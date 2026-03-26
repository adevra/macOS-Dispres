import AppKit
import CoreGraphics
import Combine
import IOKit

// MARK: - Saved Display State

struct SavedDisplayState: Codable {
    var mainDisplayKey: String?
    var resolutions: [String: SavedResolution]

    struct SavedResolution: Codable {
        var width: Int
        var height: Int
        var refreshRate: Double
        var isHiDPI: Bool
    }
}

@MainActor
final class DisplayManager: ObservableObject {
    @Published var displays: [DisplayInfo] = []
    @Published var customResolutions: [CustomResolution] = []
    @Published var lastError: String?

    private static let customResKey = "customResolutions"
    private static let stateKey = "dispres.DisplayState"
    private var started = false

    nonisolated init() {
        // Registration happens in onAppear via start()
    }

    func start() {
        guard !started else { return }
        started = true
        loadCustomResolutions()
        refresh()
        registerDisplayCallback()
    }

    /// Restore saved state (main display + resolutions). Call after virtual displays are created.
    func restoreState() {
        guard let data = UserDefaults.standard.data(forKey: Self.stateKey),
              let state = try? JSONDecoder().decode(SavedDisplayState.self, from: data) else {
            return
        }

        refresh()

        // Restore per-display resolutions
        for display in displays {
            let key = stableKey(for: display.id)
            guard let saved = state.resolutions[key] else { continue }
            if let current = display.currentMode,
               current.width == saved.width && current.height == saved.height &&
               Int(current.refreshRate) == Int(saved.refreshRate) && current.isHiDPI == saved.isHiDPI {
                continue // already correct
            }
            if let match = display.modes.first(where: {
                $0.width == saved.width && $0.height == saved.height &&
                Int($0.refreshRate) == Int(saved.refreshRate) && $0.isHiDPI == saved.isHiDPI
            }) {
                _ = setDisplayMode(match.cgMode, for: display.id)
            }
        }

        // Restore main display
        if let mainKey = state.mainDisplayKey {
            for display in displays {
                if stableKey(for: display.id) == mainKey && CGDisplayIsMain(display.id) == 0 {
                    var config: CGDisplayConfigRef?
                    if CGBeginDisplayConfiguration(&config) == .success {
                        CGConfigureDisplayOrigin(config, display.id, 0, 0)
                        CGCompleteDisplayConfiguration(config, .permanently)
                    }
                    break
                }
            }
        }

        refresh()
    }

    func saveState() {
        var state = SavedDisplayState(resolutions: [:])

        for display in displays {
            let key = stableKey(for: display.id)
            if CGDisplayIsMain(display.id) != 0 {
                state.mainDisplayKey = key
            }
            if let current = display.currentMode {
                state.resolutions[key] = .init(
                    width: current.width,
                    height: current.height,
                    refreshRate: current.refreshRate,
                    isHiDPI: current.isHiDPI
                )
            }
        }

        if let data = try? JSONEncoder().encode(state) {
            UserDefaults.standard.set(data, forKey: Self.stateKey)
        }
    }

    /// Stable identifier for a display using vendor/model/serial (survives reboot, unlike CGDirectDisplayID)
    private func stableKey(for displayID: CGDirectDisplayID) -> String {
        let vendor = CGDisplayVendorNumber(displayID)
        let model = CGDisplayModelNumber(displayID)
        let serial = CGDisplaySerialNumber(displayID)
        return "\(vendor)-\(model)-\(serial)"
    }

    func refresh() {
        displays = enumerateDisplays()
    }

    // MARK: - Display Enumeration

    private func enumerateDisplays() -> [DisplayInfo] {
        var displayIDs = [CGDirectDisplayID](repeating: 0, count: 16)
        var displayCount: UInt32 = 0
        guard CGGetActiveDisplayList(16, &displayIDs, &displayCount) == .success else {
            return []
        }

        let activeIDs = Array(displayIDs.prefix(Int(displayCount)))
        return activeIDs.map { displayID in
            let name = displayName(for: displayID)
            let isBuiltIn = CGDisplayIsBuiltin(displayID) != 0
            let modes = modesForDisplay(displayID)
            let current = currentMode(for: displayID)
            return DisplayInfo(
                id: displayID,
                name: name,
                isBuiltIn: isBuiltIn,
                modes: modes,
                currentMode: current
            )
        }
    }

    private func displayName(for displayID: CGDirectDisplayID) -> String {
        for screen in NSScreen.screens {
            if let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32,
               screenNumber == displayID {
                return screen.localizedName
            }
        }
        if CGDisplayIsBuiltin(displayID) != 0 {
            return "Built-in Display"
        }
        return "Display \(displayID)"
    }

    private func modesForDisplay(_ displayID: CGDirectDisplayID) -> [DisplayModeInfo] {
        let options: CFDictionary = [
            kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue as Any
        ] as CFDictionary

        guard let cfModes = CGDisplayCopyAllDisplayModes(displayID, options) as? [CGDisplayMode] else {
            return []
        }

        var seen = Set<String>()
        var result: [DisplayModeInfo] = []

        for mode in cfModes {
            let width = mode.width
            let height = mode.height
            let pixelWidth = mode.pixelWidth
            let pixelHeight = mode.pixelHeight
            let refreshRate = mode.refreshRate
            let isHiDPI = pixelWidth > width
            let ioFlags = mode.ioFlags
            let modeID = mode.ioDisplayModeID

            let bitDepth = "32-bit"

            let key = "\(width)x\(height)@\(Int(refreshRate))_\(isHiDPI)"
            guard !seen.contains(key) else { continue }
            seen.insert(key)

            let info = DisplayModeInfo(
                id: modeID,
                width: width,
                height: height,
                pixelWidth: pixelWidth,
                pixelHeight: pixelHeight,
                refreshRate: refreshRate,
                isHiDPI: isHiDPI,
                bitDepth: bitDepth,
                cgMode: mode
            )

            // Only include modes that are safe for desktop use
            let isSafe = (ioFlags & UInt32(kDisplayModeValidFlag)) != 0 &&
                         (ioFlags & UInt32(kDisplayModeSafeFlag)) != 0
            if isSafe {
                result.append(info)
            }
        }

        result.sort { a, b in
            if a.width != b.width { return a.width > b.width }
            if a.height != b.height { return a.height > b.height }
            if a.refreshRate != b.refreshRate { return a.refreshRate > b.refreshRate }
            return !a.isHiDPI && b.isHiDPI
        }

        return result
    }

    private func currentMode(for displayID: CGDirectDisplayID) -> DisplayModeInfo? {
        guard let mode = CGDisplayCopyDisplayMode(displayID) else { return nil }
        let width = mode.width
        let height = mode.height
        let pixelWidth = mode.pixelWidth
        let pixelHeight = mode.pixelHeight
        let refreshRate = mode.refreshRate
        let isHiDPI = pixelWidth > width
        let modeID = mode.ioDisplayModeID

        return DisplayModeInfo(
            id: modeID,
            width: width,
            height: height,
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight,
            refreshRate: refreshRate,
            isHiDPI: isHiDPI,
            bitDepth: "32-bit",
            cgMode: mode
        )
    }

    // MARK: - Main Display

    func setAsMainDisplay(_ display: DisplayInfo) {
        guard CGDisplayIsMain(display.id) == 0 else { return }

        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success else {
            showErrorAlert("Failed to begin display configuration.")
            return
        }

        // To make a display "main", move it to (0,0) and shift all others
        // by the inverse of its current origin so relative positions are preserved.
        let targetBounds = CGDisplayBounds(display.id)
        let dx = Int32(targetBounds.origin.x)
        let dy = Int32(targetBounds.origin.y)

        // Enumerate all active displays and reposition each one
        var displayIDs = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        CGGetActiveDisplayList(16, &displayIDs, &count)

        for i in 0..<Int(count) {
            let id = displayIDs[i]
            let bounds = CGDisplayBounds(id)
            let newX = Int32(bounds.origin.x) - dx
            let newY = Int32(bounds.origin.y) - dy
            CGConfigureDisplayOrigin(config, id, newX, newY)
        }

        if CGCompleteDisplayConfiguration(config, .permanently) == .success {
            refresh()
            saveState()
        } else {
            showErrorAlert("Failed to set \(display.name) as main display.")
        }
    }

    // MARK: - Resolution Switching

    func applyMode(_ mode: DisplayModeInfo, to display: DisplayInfo) {
        let success = setDisplayMode(mode.cgMode, for: display.id)
        if success {
            refresh()
            saveState()
        } else {
            lastError = "Failed to switch to \(mode.resolutionLabel)"
            showErrorAlert(lastError!)
        }
    }

    private func setDisplayMode(_ mode: CGDisplayMode, for displayID: CGDirectDisplayID) -> Bool {
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success else { return false }
        CGConfigureDisplayWithDisplayMode(config, displayID, mode, nil)
        return CGCompleteDisplayConfiguration(config, .permanently) == .success
    }

    // MARK: - Custom Resolutions

    func findMatchingMode(width: Int, height: Int, refreshRate: Double?, in display: DisplayInfo) -> DisplayModeInfo? {
        // First search the safe modes list
        if let match = display.modes.first(where: { mode in
            mode.width == width && mode.height == height &&
            (refreshRate == nil || Int(mode.refreshRate) == Int(refreshRate!))
        }) {
            return match
        }
        // Fall back to searching ALL modes (including unsafe ones)
        return findMatchingModeInAllModes(width: width, height: height, refreshRate: refreshRate, displayID: display.id)
    }

    /// Search through all display modes including non-safe ones
    private func findMatchingModeInAllModes(width: Int, height: Int, refreshRate: Double?, displayID: CGDirectDisplayID) -> DisplayModeInfo? {
        let options: CFDictionary = [
            kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue as Any
        ] as CFDictionary

        guard let cfModes = CGDisplayCopyAllDisplayModes(displayID, options) as? [CGDisplayMode] else {
            return nil
        }

        for mode in cfModes {
            let w = mode.width
            let h = mode.height
            let hz = mode.refreshRate
            if w == width && h == height && (refreshRate == nil || Int(hz) == Int(refreshRate!)) {
                let pixelWidth = mode.pixelWidth
                let pixelHeight = mode.pixelHeight
                return DisplayModeInfo(
                    id: mode.ioDisplayModeID,
                    width: w,
                    height: h,
                    pixelWidth: pixelWidth,
                    pixelHeight: pixelHeight,
                    refreshRate: hz,
                    isHiDPI: pixelWidth > w,
                    bitDepth: "32-bit",
                    cgMode: mode
                )
            }
        }
        return nil
    }

    func addCustomResolution(_ res: CustomResolution) {
        customResolutions.append(res)
        saveCustomResolutions()
    }

    func removeCustomResolution(_ res: CustomResolution) {
        customResolutions.removeAll { $0.id == res.id }
        saveCustomResolutions()
    }

    private func loadCustomResolutions() {
        guard let data = UserDefaults.standard.data(forKey: Self.customResKey),
              let decoded = try? JSONDecoder().decode([CustomResolution].self, from: data) else {
            return
        }
        customResolutions = decoded
    }

    private func saveCustomResolutions() {
        if let data = try? JSONEncoder().encode(customResolutions) {
            UserDefaults.standard.set(data, forKey: Self.customResKey)
        }
    }

    // MARK: - Display Change Callback

    private func registerDisplayCallback() {
        CGDisplayRegisterReconfigurationCallback({ _, flags, userInfo in
            if flags.contains(.beginConfigurationFlag) { return }
            guard let userInfo else { return }
            Task { @MainActor in
                let mgr = Unmanaged<DisplayManager>.fromOpaque(userInfo).takeUnretainedValue()
                mgr.refresh()
            }
        }, Unmanaged.passUnretained(self).toOpaque())
    }

    // MARK: - Error Handling

    private func showErrorAlert(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Resolution Switch Failed"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
