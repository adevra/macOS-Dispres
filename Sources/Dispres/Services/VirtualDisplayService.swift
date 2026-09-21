import CoreGraphics
import Foundation
import CGVirtualDisplayBridge

extension CGVirtualDisplayDescriptor: @unchecked @retroactive Sendable {}
extension CGVirtualDisplay: @unchecked @retroactive Sendable {}
extension CGVirtualDisplaySettings: @unchecked @retroactive Sendable {}

// MARK: - Config Model

struct VirtualDisplayConfig: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    var width: Int
    var height: Int
    var refreshRate: Double
    var hiDPI: Bool
    var autoCreate: Bool

    init(name: String, width: Int, height: Int,
         refreshRate: Double = 60.0, hiDPI: Bool = true, autoCreate: Bool = true) {
        self.id = UUID()
        self.name = name
        self.width = width
        self.height = height
        self.refreshRate = refreshRate
        self.hiDPI = hiDPI
        self.autoCreate = autoCreate
    }

    var label: String {
        "\(width) \u{00d7} \(height) @ \(Int(refreshRate))Hz\(hiDPI ? " HiDPI" : "")"
    }

    /// Deterministic 32-bit serial folded from the config UUID (FNV-1a).
    /// `hashValue` is randomly seeded per process, so using it here meant the display's
    /// identity changed on every launch and saved per-display state never matched.
    var stableSerial: UInt32 {
        withUnsafeBytes(of: id.uuid) { raw in
            var acc: UInt32 = 0x811C_9DC5
            for byte in raw {
                acc = (acc ^ UInt32(byte)) &* 0x0100_0193
            }
            return acc
        }
    }
}

// MARK: - Service

@MainActor
final class VirtualDisplayService: ObservableObject {
    @Published var configs: [VirtualDisplayConfig] = []
    @Published private(set) var activeConfigIDs: Set<UUID> = []

    private var activeDisplays: [UUID: CGVirtualDisplay] = [:]

    /// CGDirectDisplayIDs currently backed by a virtual display.
    var activeDisplayIDs: Set<CGDirectDisplayID> {
        Set(activeDisplays.values.map(\.displayID))
    }
    private static let configsKey = "dispres.VirtualDisplayConfigs"

    init() {
        loadConfigs()
    }

    func startup() {
        guard configs.contains(where: { $0.autoCreate }) else { return }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 500_000_000)
            // Skip configs that are already up: creating a second CGVirtualDisplay for
            // the same config replaces the first, which silently discards any
            // arrangement already applied to it.
            await ensureAutoCreateDisplays()
        }
    }

    /// Bring up every auto-create config that isn't already running. Used to re-arm the
    /// clamshell session after a lid-open teardown; without it the second lid close has
    /// no display to fall back to.
    @discardableResult
    func ensureAutoCreateDisplays() async -> Int {
        var created = 0
        for config in configs where config.autoCreate && !isActive(config.id) {
            if await create(config: config) { created += 1 }
        }
        return created
    }

    // MARK: - Create / Destroy

    @discardableResult
    func create(config: VirtualDisplayConfig) async -> Bool {
        // Build descriptor on main thread (required by CGVirtualDisplay)
        let descriptor = CGVirtualDisplayDescriptor()
        let ppi: Double = 110.0
        descriptor.sizeInMillimeters = CGSize(
            width: Double(config.width) / ppi * 25.4,
            height: Double(config.height) / ppi * 25.4
        )
        descriptor.maxPixelsWide = UInt32(config.width)
        descriptor.maxPixelsHigh = UInt32(config.height)
        descriptor.name = config.name
        descriptor.vendorID = 0xEEEE
        descriptor.productID = 0x0001
        descriptor.serialNum = config.stableSerial

        guard let virtualDisplay = CGVirtualDisplay(descriptor: descriptor) else {
            return false
        }

        // Build settings with modes
        let settings = CGVirtualDisplaySettings()
        settings.hiDPI = config.hiDPI

        var modes: [CGVirtualDisplayMode] = []
        let rates: [Double] = [60.0, 50.0, 30.0]
        for rate in rates {
            modes.append(CGVirtualDisplayMode(
                width: UInt(config.width),
                height: UInt(config.height),
                refreshRate: rate
            ))
        }
        if config.hiDPI {
            let hw = config.width / 2, hh = config.height / 2
            if hw >= 1, hh >= 1 {
                for rate in rates {
                    modes.append(CGVirtualDisplayMode(width: UInt(hw), height: UInt(hh), refreshRate: rate))
                }
            }
        }
        settings.modes = modes

        // Apply settings (may block on WindowServer IPC)
        let vd = virtualDisplay
        let s = settings
        let ok: Bool = await withCheckedContinuation { cont in
            DispatchQueue.global().async {
                let result = vd.apply(s)
                cont.resume(returning: result)
            }
        }

        guard ok, virtualDisplay.displayID != kCGNullDirectDisplay else {
            return false
        }

        activeDisplays[config.id] = virtualDisplay
        activeConfigIDs.insert(config.id)
        return true
    }

    @discardableResult
    func destroy(configID: UUID) -> Bool {
        guard activeDisplays[configID] != nil else { return false }
        activeDisplays.removeValue(forKey: configID)
        activeConfigIDs.remove(configID)
        return true
    }

    /// Tear down every virtual display. Returns true if anything was actually removed.
    /// CGVirtualDisplay has no explicit destroy call — the screen goes away when the last
    /// reference is released, so dropping them here is the teardown.
    @discardableResult
    func destroyAll() -> Bool {
        let had = !activeDisplays.isEmpty
        activeDisplays.removeAll()
        activeConfigIDs.removeAll()
        return had
    }

    func isActive(_ configID: UUID) -> Bool {
        activeConfigIDs.contains(configID)
    }

    // MARK: - Config Management

    @discardableResult
    func addAndCreate(_ config: VirtualDisplayConfig) async -> Bool {
        if await create(config: config) {
            configs.append(config)
            saveConfigs()
            return true
        }
        return false
    }

    func removeConfig(id: UUID) {
        destroy(configID: id)
        configs.removeAll { $0.id == id }
        saveConfigs()
    }

    func toggleActive(config: VirtualDisplayConfig) async {
        if isActive(config.id) {
            destroy(configID: config.id)
        } else {
            _ = await create(config: config)
        }
    }

    // MARK: - Persistence

    private func loadConfigs() {
        guard let data = UserDefaults.standard.data(forKey: Self.configsKey),
              let decoded = try? JSONDecoder().decode([VirtualDisplayConfig].self, from: data)
        else { return }
        configs = decoded
    }

    private func saveConfigs() {
        guard let data = try? JSONEncoder().encode(configs) else { return }
        UserDefaults.standard.set(data, forKey: Self.configsKey)
    }
}
