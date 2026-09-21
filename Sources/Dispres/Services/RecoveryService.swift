import AppKit
import Carbon.HIToolbox
import Combine
import CoreGraphics
import Foundation
import IOKit
import IOKit.pwr_mgt
import os

let dispresLog = Logger(subsystem: "com.dispres.app", category: "clamshell")

// MARK: - Clamshell (lid) monitor

/// Watches the lid through IOPMrootDomain's `AppleClamshellState`.
///
/// Waiting for the built-in display to disappear is too late: for a moment there are no
/// active displays at all, which blanks the remote session and can drop the Mac to the
/// login window. The clamshell notification fires while the panel is still up, so a
/// virtual display can be in place before it goes.
final class ClamshellMonitor {
    private var port: IONotificationPortRef?
    private var notification: io_object_t = 0
    private var service: io_service_t = 0
    private var timer: DispatchSourceTimer?
    private(set) var isClosed: Bool
    private let onChange: (Bool) -> Void

    init?(onChange: @escaping (Bool) -> Void) {
        self.onChange = onChange

        service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard service != 0 else { return nil }
        isClosed = Self.readClamshellState(service) ?? false

        guard let port = IONotificationPortCreate(kIOMainPortDefault) else {
            IOObjectRelease(service)
            return nil
        }
        self.port = port
        IONotificationPortSetDispatchQueue(port, .main)

        // React to any general-interest message and diff the property, rather than
        // matching on a specific power-management message constant.
        let result = IOServiceAddInterestNotification(
            port,
            service,
            kIOGeneralInterest,
            { refcon, _, _, _ in
                guard let refcon else { return }
                Unmanaged<ClamshellMonitor>.fromOpaque(refcon).takeUnretainedValue().handleMessage()
            },
            Unmanaged.passUnretained(self).toOpaque(),
            &notification
        )

        guard result == KERN_SUCCESS else {
            IONotificationPortDestroy(port)
            IOObjectRelease(service)
            self.port = nil
            return nil
        }

        // AppleClamshellState lags the physical lid: when the notification arrives the
        // property can still hold the old value, so reading it once there silently drops
        // the transition. Poll as well — one registry property read a second — so a
        // missed edge is picked up on the next tick instead of never.
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 1.0, repeating: 1.0)
        timer.setEventHandler { [weak self] in self?.handleMessage() }
        timer.resume()
        self.timer = timer

        dispresLog.notice("ClamshellMonitor started, initial closed=\(self.isClosed, privacy: .public)")
    }

    fileprivate func handleMessage() {
        guard let state = Self.readClamshellState(service), state != isClosed else { return }
        isClosed = state
        dispresLog.notice("lid \(state ? "closed" : "opened", privacy: .public)")
        onChange(state)
    }

    private static func readClamshellState(_ service: io_service_t) -> Bool? {
        guard let value = IORegistryEntryCreateCFProperty(
            service, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0
        )?.takeRetainedValue() else { return nil }
        return (value as? NSNumber)?.boolValue
    }

    deinit {
        timer?.cancel()
        if notification != 0 { IOObjectRelease(notification) }
        if let port { IONotificationPortDestroy(port) }
        if service != 0 { IOObjectRelease(service) }
    }
}

// MARK: - Global recovery hot key

private nonisolated(unsafe) var recoveryHotKeyAction: (() -> Void)?

private func recoveryHotKeyHandler(
    _ callRef: EventHandlerCallRef?,
    _ event: EventRef?,
    _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
    DispatchQueue.main.async { recoveryHotKeyAction?() }
    return noErr
}

/// A system-wide hot key that still works when the menu bar and every window are
/// stranded on a virtual display nobody can see — the one situation where the menu bar
/// item that would normally fix this is itself unreachable.
///
/// Uses Carbon's RegisterEventHotKey rather than an NSEvent global monitor so it needs
/// no Accessibility permission.
final class RecoveryHotKey {
    static let displayString = "\u{2303}\u{2325}\u{2318}D"

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?

    init?(action: @escaping () -> Void) {
        recoveryHotKeyAction = action

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        guard InstallEventHandler(
            GetApplicationEventTarget(),
            recoveryHotKeyHandler,
            1,
            &eventType,
            nil,
            &handlerRef
        ) == noErr else {
            recoveryHotKeyAction = nil
            return nil
        }

        let hotKeyID = EventHotKeyID(signature: OSType(0x4453_5052), id: 1) // 'DSPR'
        guard RegisterEventHotKey(
            UInt32(kVK_ANSI_D),
            UInt32(controlKey | optionKey | cmdKey),
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        ) == noErr else {
            if let handlerRef { RemoveEventHandler(handlerRef) }
            handlerRef = nil
            recoveryHotKeyAction = nil
            return nil
        }
    }

    deinit {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
        recoveryHotKeyAction = nil
    }
}

// MARK: - Recovery coordinator

/// Gets the Mac back to a usable state after a clamshell session.
///
/// With the lid shut the built-in panel goes offline, so a virtual display is the only
/// screen left: it becomes main and collects the menu bar and every window. Opening the
/// lid brings the panel back, but the virtual display is still main and everything is
/// still on it — clicks land on an empty desktop and there is no visible menu bar to
/// undo it with. This watches for the panel returning and tears the virtual displays
/// down, which makes macOS migrate the menu bar and windows back.
@MainActor
final class RecoveryCoordinator: ObservableObject {
    @Published var autoSwitchForClamshell: Bool {
        didSet { UserDefaults.standard.set(autoSwitchForClamshell, forKey: Self.autoRecoverKey) }
    }
    @Published private(set) var hotKeyRegistered = false
    @Published private(set) var clamshellMonitored = false

    private static let autoRecoverKey = "dispres.AutoSwitchForClamshell"

    private weak var displayManager: DisplayManager?
    private weak var virtualDisplayService: VirtualDisplayService?
    private var hotKey: RecoveryHotKey?
    private var clamshell: ClamshellMonitor?
    private var work: Task<Void, Never>?
    private var started = false

    init() {
        let defaults = UserDefaults.standard
        // Default on: the failure it prevents costs a hard restart.
        autoSwitchForClamshell = defaults.object(forKey: Self.autoRecoverKey) as? Bool ?? true
    }

    func configure(displayManager: DisplayManager, virtualDisplayService: VirtualDisplayService) {
        guard !started else { return }
        started = true

        self.displayManager = displayManager
        self.virtualDisplayService = virtualDisplayService

        displayManager.virtualDisplayIDProvider = { [weak virtualDisplayService] in
            virtualDisplayService?.activeDisplayIDs ?? []
        }
        displayManager.onBuiltInDisplayReturned = { [weak self] in
            guard let self, self.autoSwitchForClamshell else { return }
            self.recover()
        }
        // Fallback for the lid closing, in case the clamshell notification is
        // unavailable. Late — by now there may be no displays at all — but better than
        // leaving the session with nothing to draw on.
        displayManager.onBuiltInDisplayLeft = { [weak self] in
            guard let self, self.autoSwitchForClamshell else { return }
            self.armForClamshell()
        }

        // Both directions come from the clamshell state. The display list is not a
        // reliable lid signal: with sleep disabled the built-in panel stays in the
        // active list for the whole closed period, so it never "returns".
        clamshell = ClamshellMonitor { [weak self] closed in
            MainActor.assumeIsolated {
                guard let self, self.autoSwitchForClamshell else { return }
                if closed {
                    self.armForClamshell()
                } else {
                    self.recover()
                }
            }
        }
        clamshellMonitored = clamshell != nil

        hotKey = RecoveryHotKey { [weak self] in
            MainActor.assumeIsolated { self?.recover() }
        }
        hotKeyRegistered = hotKey != nil
    }

    /// Launching with the lid already shut is not a transition, so nothing would promote
    /// the virtual display and the remote session would sit on a panel that is switched
    /// off. Must run *after* restoreState, which would otherwise hand main straight back
    /// to the built-in. This is the cold-start path: login item, or a restart while
    /// remoted in with the lid down.
    func armIfLidClosed() {
        guard autoSwitchForClamshell, clamshell?.isClosed == true else { return }
        dispresLog.notice("launched with lid closed, arming")
        armForClamshell()
    }

    /// Serialize lid work. Opening and closing in quick succession otherwise interleaves
    /// a teardown with a create, which is the other way this ends up in a wrong state.
    private func enqueue(_ operation: @escaping @MainActor () async -> Void) {
        let previous = work
        work = Task { @MainActor in
            await previous?.value
            await operation()
        }
    }

    /// Make sure a virtual display exists before the built-in panel goes offline.
    /// Without this, the second lid close of a session lands on zero active displays:
    /// the remote view goes black and macOS drops to the login window.
    func armForClamshell() {
        guard let virtualDisplayService, let displayManager else { return }
        enqueue {
            let created = await virtualDisplayService.ensureAutoCreateDisplays()

            // The built-in panel can stay in the active display list for the whole time
            // the lid is shut — sleep being disabled makes that the normal case — so it
            // keeps the menu bar and the remote session keeps showing a screen nobody
            // can see. Promote the virtual display explicitly instead of relying on the
            // panel dropping out on its own.
            try? await Task.sleep(nanoseconds: 400_000_000)
            displayManager.refresh()
            var promoted = false
            if let virtualID = virtualDisplayService.activeDisplayIDs.first {
                promoted = displayManager.makeMain(displayID: virtualID)
            }
            dispresLog.notice(
                "armForClamshell created=\(created, privacy: .public) promoted=\(promoted, privacy: .public)"
            )
        }
    }

    /// Drop every virtual display, then hand the origin back to the built-in panel.
    func recover() {
        guard let displayManager, let virtualDisplayService else { return }
        enqueue {
            // Order matters: releasing the virtual displays first makes macOS move the
            // menu bar and the windows onto the remaining real screen.
            let had = virtualDisplayService.destroyAll()
            // WindowServer needs a beat to reconfigure before an arrangement will stick.
            try? await Task.sleep(nanoseconds: 800_000_000)
            displayManager.refresh()
            let madeMain = displayManager.makeBuiltInMain()
            displayManager.refresh()
            displayManager.saveState()
            dispresLog.notice("recover destroyed=\(had, privacy: .public) builtInMain=\(madeMain, privacy: .public)")
        }
    }
}
