// Awake: keeps the Mac awake. Lives behind the notch.
// Move the pointer to the notch and the panel drops down. Move away and it hides.
// Turns itself off on battery at 20% or less.
// "With Claude": while a Claude Code session works, the Mac stays awake but the display can sleep and lock.
import AppKit
import SwiftUI
import IOKit.pwr_mgt
import IOKit.ps
import ServiceManagement

// MARK: - Sleep state

final class Model: ObservableObject {
    @Published private(set) var isOn = false
    @Published private(set) var minutes: Int?          // nil = indefinitely
    @Published private(set) var endsAt: Date?
    @Published private(set) var battery: Int?          // percent, only while on battery
    @Published var keepDisplay = UserDefaults.standard.object(forKey: "keepDisplay") as? Bool ?? true {
        didSet { UserDefaults.standard.set(keepDisplay, forKey: "keepDisplay"); if isOn { release(); acquire() } }
    }
    @Published var openAtLogin = SMAppService.mainApp.status == .enabled
    @Published var withClaude = UserDefaults.standard.object(forKey: "withClaude") as? Bool ?? true {
        didSet { UserDefaults.standard.set(withClaude, forKey: "withClaude"); tick() }
    }
    @Published private(set) var claudeHolds = false   // the Claude assertion is active
    private var claudeAssertion: IOPMAssertionID = 0

    private var assertion: IOPMAssertionID = 0
    private var timer: Timer?

    init() {
        battery = Self.batteryPercentOnBattery()
        // Always tick, so the battery reading stays fresh even while off.
        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in self?.tick() }
        tick()
    }

    var batteryLow: Bool { (battery ?? 100) <= 20 }

    func start(minutes: Int?) {
        battery = Self.batteryPercentOnBattery()
        if batteryLow { NSSound.beep(); return }
        release()
        acquire()
        guard assertion != 0 else { return }
        self.minutes = minutes
        endsAt = minutes.map { Date().addingTimeInterval(Double($0) * 60) }
        isOn = true
    }

    func stop() {
        release()
        isOn = false
        minutes = nil
        endsAt = nil
    }

    func toggle() { isOn ? stop() : start(minutes: nil) }

    func toggleLogin() {
        let s = SMAppService.mainApp
        do { try s.status == .enabled ? s.unregister() : s.register() } catch { NSSound.beep() }
        openAtLogin = s.status == .enabled
    }

    private func tick() {
        battery = Self.batteryPercentOnBattery()
        updateClaude()
        guard isOn else { return }
        if batteryLow || (endsAt.map { Date() >= $0 } ?? false) { stop() } else { objectWillChange.send() }
    }

    // System sleep only, so the display still sleeps and the screen still locks.
    private func updateClaude() {
        let want = withClaude && !batteryLow && Self.claudeIsWorking()
        if want && claudeAssertion == 0 {
            if IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                                           IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                           "Awake: Claude is working" as CFString, &claudeAssertion) != kIOReturnSuccess {
                claudeAssertion = 0
            }
        } else if !want && claudeAssertion != 0 {
            IOPMAssertionRelease(claudeAssertion)
            claudeAssertion = 0
        }
        claudeHolds = claudeAssertion != 0
    }

    // True when a Claude Code session reports "busy". The hook ~/.claude/hooks/awake-state.sh writes
    // "<busy|idle> <claude pid>" to ~/.claude/awake/<session> on prompt, tool use, stop and permission waits.
    // ponytail: Esc-interrupt fires no hook, so a busy file older than 30 min without a tool call is ignored.
    // A thinking turn longer than 30 min with no tool call loses its hold. Upgrade path: also read the pid's CPU time.
    static let stateDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/awake")

    static func claudeIsWorking() -> Bool {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: stateDir, includingPropertiesForKeys: [.contentModificationDateKey])
        else { return false }
        var working = false
        for f in files {
            guard let text = try? String(contentsOf: f, encoding: .utf8) else { continue }
            let parts = text.split(separator: " ")
            guard parts.count == 2, let pid = pid_t(parts[1].trimmingCharacters(in: .whitespacesAndNewlines)) else { continue }
            if kill(pid, 0) != 0 && errno == ESRCH { try? fm.removeItem(at: f); continue }  // session is gone
            let age = (try? f.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
                .map { Date().timeIntervalSince($0) } ?? .infinity
            if parts[0] == "busy" && age < 30 * 60 { working = true }
        }
        return working
    }

    private func acquire() {
        let type = (keepDisplay ? kIOPMAssertionTypePreventUserIdleDisplaySleep
                                : kIOPMAssertionTypePreventUserIdleSystemSleep) as CFString
        if IOPMAssertionCreateWithName(type, IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                       "Awake" as CFString, &assertion) != kIOReturnSuccess {
            assertion = 0
            NSSound.beep()
        }
    }

    private func release() {
        if assertion != 0 { IOPMAssertionRelease(assertion); assertion = 0 }
    }

    // Battery percent while the Mac runs on battery. nil on AC power or with no battery.
    static func batteryPercentOnBattery() -> Int? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for ps in list {
            guard let d = IOPSGetPowerSourceDescription(info, ps)?.takeUnretainedValue() as? [String: Any],
                  d[kIOPSPowerSourceStateKey] as? String == kIOPSBatteryPowerValue,
                  let cur = d[kIOPSCurrentCapacityKey] as? Int,
                  let max = d[kIOPSMaxCapacityKey] as? Int, max > 0 else { continue }
            return cur * 100 / max
        }
        return nil
    }

    var statusText: String {
        if !isOn {
            if batteryLow { return "Off. Battery at 20% or less" }
            return claudeHolds ? "Claude is working. Screen can lock" : "Mac sleeps normally"
        }
        guard let end = endsAt else { return "Awake until you turn it off" }
        let mins = max(1, Int(ceil(end.timeIntervalSinceNow / 60)))
        return mins >= 60 ? "\(mins / 60) h \(mins % 60) min left" : "\(mins) min left"
    }
}

// MARK: - Notch panel

final class Hover: ObservableObject {
    @Published var expanded = false
    @Published var notch = CGSize(width: 200, height: 32)
    @Published var hasNotch = false
}

let panelSize = CGSize(width: 380, height: 190)
let openSize = CGSize(width: 360, height: 176)

struct NotchView: View {
    @ObservedObject var m: Model
    @ObservedObject var h: Hover

    var body: some View {
        let w = h.expanded ? openSize.width : h.notch.width
        let ht = h.expanded ? openSize.height : h.notch.height
        let shape = UnevenRoundedRectangle(bottomLeadingRadius: h.expanded ? 26 : 10,
                                           bottomTrailingRadius: h.expanded ? 26 : 10, style: .continuous)
        // The content is clipped to the black shape, so it can never show without its background.
        ZStack(alignment: .top) {
            Color.black
            if h.expanded {
                content
                    .frame(width: openSize.width - 40)
                    .padding(.top, max(h.notch.height, 12) + 8)
                    .transition(.asymmetric(
                        insertion: .opacity.animation(.easeOut(duration: 0.2).delay(0.08)),
                        removal: .opacity.animation(.easeIn(duration: 0.12))))
            }
        }
        .frame(width: w, height: ht, alignment: .top)
        .clipShape(shape)
        .shadow(color: .black.opacity(h.expanded ? 0.35 : 0), radius: 16, y: 6)
        .opacity(h.expanded || h.hasNotch ? 1 : 0)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .frame(width: panelSize.width, height: panelSize.height, alignment: .top)
        .animation(.spring(response: 0.38, dampingFraction: 0.82), value: h.expanded)
        .animation(.easeInOut(duration: 0.2), value: m.isOn)
        .preferredColorScheme(.dark)
    }

    var content: some View {
        VStack(spacing: 14) {
            HStack(spacing: 14) {
                Button(action: m.toggle) {
                    Image(systemName: m.isOn ? "cup.and.saucer.fill" : "cup.and.saucer")
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(m.isOn ? .black : .white)
                        .frame(width: 48, height: 48)
                        .background(Circle().fill(m.isOn ? Color.orange : Color.white.opacity(0.12)))
                }
                .buttonStyle(.plain)
                .help(m.isOn ? "Turn off" : "Keep awake")
                VStack(alignment: .leading, spacing: 2) {
                    Text(m.isOn ? "Awake" : m.claudeHolds ? "Awake with Claude" : "Off").font(.system(size: 15, weight: .semibold))
                    Text(m.statusText).font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer()
                if let b = m.battery {
                    Label("\(b)%", systemImage: b <= 20 ? "battery.25" : "battery.75")
                        .font(.system(size: 11)).foregroundStyle(b <= 20 ? .red : .secondary)
                }
            }
            HStack(spacing: 6) {
                ForEach([(nil, "∞"), (15, "15m"), (30, "30m"), (60, "1h"), (120, "2h"), (240, "4h")], id: \.1) { mins, label in
                    let selected = m.isOn && m.minutes == mins
                    Button { m.start(minutes: mins) } label: {
                        Text(label).font(.system(size: 12, weight: .medium))
                            .frame(maxWidth: .infinity, minHeight: 26)
                            .background(Capsule().fill(selected ? Color.orange : Color.white.opacity(0.1)))
                            .foregroundStyle(selected ? .black : .white)
                    }
                    .buttonStyle(.plain)
                }
            }
            HStack(spacing: 14) {
                pill("With Claude", m.withClaude) { m.withClaude.toggle() }
                pill("Display on", m.keepDisplay) { m.keepDisplay.toggle() }
                pill("At login", m.openAtLogin) { m.toggleLogin() }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }.buttonStyle(.plain)
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
    }

    func pill(_ title: String, _ on: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: on ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 11)).foregroundStyle(on ? .white : .secondary)
        }
        .buttonStyle(.plain)
    }
}

final class Panel: NSPanel {
    override var canBecomeKey: Bool { true }
}

final class App: NSObject, NSApplicationDelegate {
    let model = Model()
    let hover = Hover()
    var panel: Panel!
    var screen: NSScreen?
    var closeWork: DispatchWorkItem?
    var last = NSPoint(x: -1, y: -1)

    func applicationDidFinishLaunching(_: Notification) {
        panel = Panel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.contentView = NSHostingView(rootView: NotchView(m: model, h: hover))
        place(on: NSScreen.main ?? NSScreen.screens[0])
        panel.orderFrontRegardless()

        // ponytail: polls the pointer at 20 Hz. Event monitors miss moves once the panel is key.
        // Upgrade path: a CGEventTap, which needs Accessibility permission.
        let t = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in self?.track() }
        t.tolerance = 0.02
        RunLoop.main.add(t, forMode: .common)
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            self?.place(on: self?.screen ?? NSScreen.main ?? NSScreen.screens[0])
        }
    }

    func place(on s: NSScreen) {
        screen = s
        let left = s.auxiliaryTopLeftArea?.width ?? 0, right = s.auxiliaryTopRightArea?.width ?? 0
        hover.hasNotch = s.safeAreaInsets.top > 0 && left > 0
        hover.notch = hover.hasNotch ? CGSize(width: s.frame.width - left - right, height: s.safeAreaInsets.top)
                                     : CGSize(width: 200, height: 0)
        let f = s.frame
        panel.setFrame(NSRect(x: f.midX - panelSize.width / 2, y: f.maxY - panelSize.height,
                              width: panelSize.width, height: panelSize.height), display: true)
    }

    func track() {
        let p = NSEvent.mouseLocation
        if p == last { return }
        last = p
        guard let s = NSScreen.screens.first(where: { NSMouseInRect(p, $0.frame, false) }) else { return }
        let f = s.frame
        if hover.expanded {
            let open = NSRect(x: f.midX - openSize.width / 2 - 16, y: f.maxY - openSize.height - 16,
                              width: openSize.width + 32, height: openSize.height + 16)
            if NSMouseInRect(p, open, false) { closeWork?.cancel(); closeWork = nil }
            else if closeWork == nil {
                let w = DispatchWorkItem { [weak self] in self?.setExpanded(false) }
                closeWork = w
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: w)
            }
        } else {
            if s != screen { place(on: s) }
            let hotW = hover.notch.width + 20, hotH = max(hover.notch.height, 4)
            let hot = NSRect(x: f.midX - hotW / 2, y: f.maxY - hotH, width: hotW, height: hotH + 1)
            if NSMouseInRect(p, hot, false) { setExpanded(true) }
        }
    }

    func setExpanded(_ on: Bool) {
        closeWork?.cancel(); closeWork = nil
        guard hover.expanded != on else { return }
        hover.expanded = on
        panel.ignoresMouseEvents = !on
    }
}

let app = NSApplication.shared
let delegate = App()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
