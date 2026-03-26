import CoreGraphics
import Foundation

struct DisplayInfo: Identifiable {
    let id: CGDirectDisplayID
    let name: String
    let isBuiltIn: Bool
    var modes: [DisplayModeInfo]
    var currentMode: DisplayModeInfo?
}

struct DisplayModeInfo: Identifiable, Equatable {
    let id: Int32
    let width: Int
    let height: Int
    let pixelWidth: Int
    let pixelHeight: Int
    let refreshRate: Double
    let isHiDPI: Bool
    let bitDepth: String
    let cgMode: CGDisplayMode

    var resolutionLabel: String {
        let hidpi = isHiDPI ? " HiDPI" : ""
        let hz = refreshRate > 0 ? " @ \(Int(refreshRate))Hz" : ""
        return "\(width) \u{00d7} \(height)\(hz)\(hidpi)"
    }

    static func == (lhs: DisplayModeInfo, rhs: DisplayModeInfo) -> Bool {
        lhs.width == rhs.width &&
        lhs.height == rhs.height &&
        lhs.refreshRate == rhs.refreshRate &&
        lhs.isHiDPI == rhs.isHiDPI
    }
}

struct CustomResolution: Codable, Identifiable {
    let id: UUID
    var width: Int
    var height: Int
    var refreshRate: Double?

    init(width: Int, height: Int, refreshRate: Double? = nil) {
        self.id = UUID()
        self.width = width
        self.height = height
        self.refreshRate = refreshRate
    }

    var label: String {
        let hz = refreshRate.map { " @ \(Int($0))Hz" } ?? ""
        return "\(width) \u{00d7} \(height)\(hz)"
    }
}
