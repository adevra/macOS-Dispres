import CoreGraphics
import Foundation

// MARK: - Private CoreGraphics/SkyLight API Declarations
// These are undocumented APIs used by tools like RDM, BetterDisplay, etc.
// They may break on future macOS versions.

// Private display mode descriptor used by CGS APIs
struct CGSDisplayModeDescription {
    var
        modeNumber: UInt32,
        flags: UInt32,
        width: UInt32,
        height: UInt32,
        depth: UInt32,
        _pad0: UInt32,
        density: UInt32,
        _pad1: UInt32,
        refreshRate: UInt32,
        _pad2: UInt32,
        ioFlags: UInt32
    // Additional fields may exist depending on macOS version
}

// CGSGetNumberOfDisplayModes(displayID, &modeCount) -> CGError
private let _CGSGetNumberOfDisplayModes: (@convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Int32>) -> CGError)? = {
    guard let handle = dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_LAZY) else { return nil }
    guard let sym = dlsym(handle, "CGSGetNumberOfDisplayModes") else { return nil }
    return unsafeBitCast(sym, to: (@convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Int32>) -> CGError).self)
}()

// CGSGetDisplayModeDescriptionOfLength(displayID, modeIndex, &desc, length) -> CGError
private let _CGSGetDisplayModeDescriptionOfLength: (@convention(c) (CGDirectDisplayID, Int32, UnsafeMutableRawPointer, Int32) -> CGError)? = {
    guard let handle = dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_LAZY) else { return nil }
    guard let sym = dlsym(handle, "CGSGetDisplayModeDescriptionOfLength") else { return nil }
    return unsafeBitCast(sym, to: (@convention(c) (CGDirectDisplayID, Int32, UnsafeMutableRawPointer, Int32) -> CGError).self)
}()

// CGSConfigureDisplayMode(config, displayID, modeNumber) -> CGError
private let _CGSConfigureDisplayMode: (@convention(c) (CGDisplayConfigRef, CGDirectDisplayID, Int32) -> CGError)? = {
    guard let handle = dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_LAZY) else { return nil }
    guard let sym = dlsym(handle, "CGSConfigureDisplayMode") else { return nil }
    return unsafeBitCast(sym, to: (@convention(c) (CGDisplayConfigRef, CGDirectDisplayID, Int32) -> CGError).self)
}()

// MARK: - Private Mode Info

struct PrivateModeInfo {
    let modeNumber: Int32
    let width: Int
    let height: Int
    let refreshRate: Int
    let depth: Int
    let density: Int
}

// MARK: - Public Interface

enum PrivateDisplayAPI {
    static var isAvailable: Bool {
        _CGSGetNumberOfDisplayModes != nil &&
        _CGSGetDisplayModeDescriptionOfLength != nil &&
        _CGSConfigureDisplayMode != nil
    }

    /// Enumerate all private display modes (includes modes hidden from public API)
    static func allModes(for displayID: CGDirectDisplayID) -> [PrivateModeInfo] {
        guard let getCount = _CGSGetNumberOfDisplayModes,
              let getDesc = _CGSGetDisplayModeDescriptionOfLength else {
            return []
        }

        var modeCount: Int32 = 0
        guard getCount(displayID, &modeCount) == .success else { return [] }

        var modes: [PrivateModeInfo] = []
        let descSize = Int32(MemoryLayout<CGSDisplayModeDescription>.size)

        for i in 0..<modeCount {
            var desc = CGSDisplayModeDescription(
                modeNumber: 0, flags: 0, width: 0, height: 0,
                depth: 0, _pad0: 0, density: 0, _pad1: 0,
                refreshRate: 0, _pad2: 0, ioFlags: 0
            )
            guard getDesc(displayID, i, &desc, descSize) == .success else { continue }

            modes.append(PrivateModeInfo(
                modeNumber: Int32(desc.modeNumber),
                width: Int(desc.width),
                height: Int(desc.height),
                refreshRate: Int(desc.refreshRate),
                depth: Int(desc.depth),
                density: Int(desc.density)
            ))
        }

        return modes
    }

    /// Try to apply a custom resolution using private APIs.
    /// Returns true on success.
    static func applyCustomResolution(
        width: Int,
        height: Int,
        refreshRate: Int?,
        displayID: CGDirectDisplayID
    ) -> Bool {
        guard let configureMode = _CGSConfigureDisplayMode else { return false }

        let modes = allModes(for: displayID)
        guard let match = modes.first(where: { mode in
            mode.width == width && mode.height == height &&
            (refreshRate == nil || mode.refreshRate == refreshRate)
        }) else {
            return false
        }

        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success, let config else { return false }

        guard configureMode(config, displayID, match.modeNumber) == .success else {
            CGCancelDisplayConfiguration(config)
            return false
        }

        return CGCompleteDisplayConfiguration(config, .permanently) == .success
    }
}
