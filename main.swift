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

// MARK: - Ops status (the agent dashboard, ~/.claude/ops/dashboard/server.py)

struct OpsStatus: Decodable {
    struct Agent: Decodable { let name: String; let health: String; let progress: Double?; let done_today: Int; let next: String?; let waiting_on: [String]? }
    struct Decisions: Decodable { struct Old: Decodable { let age_days: Int; let id: String?; let title: String? }; let count: Int; let oldest: [Old] }
    struct Runner: Decodable { let ok: Bool; let age_min: Int? }
    struct Triage: Decodable { let on: Bool; let stale: Bool? }
    struct Jobs: Decodable { let failing: [String]? }
    let agents: [Agent]; let decisions: Decisions; let runner: Runner; let triage: Triage; let jobs: Jobs
}

let opsURL = URL(string: "http://127.0.0.1:8788/")!

final class Ops: ObservableObject {
    @Published private(set) var status: OpsStatus?
    @Published private(set) var offline = false
    var onChange: (() -> Void)?

    func refresh() {
        var req = URLRequest(url: opsURL.appendingPathComponent("api/status"))
        req.timeoutInterval = 4
        URLSession.shared.dataTask(with: req) { [weak self] data, resp, _ in
            let s = (resp as? HTTPURLResponse)?.statusCode == 200 ? data.flatMap { try? JSONDecoder().decode(OpsStatus.self, from: $0) } : nil
            DispatchQueue.main.async {
                guard let self else { return }
                self.offline = s == nil           // a bad answer shows "offline", never stale numbers as fresh
                if let s { self.status = s } else { self.status = nil }
                self.onChange?()
            }
        }.resume()
    }

    // orange: a decision older than 24 h or a stuck agent. red: runner down, triage should run but does not, or no answer at all.
    enum Alert { case none, orange, red }
    var alert: Alert {
        guard let s = status else { return offline ? .red : .none }
        if !s.runner.ok || s.triage.stale == true { return .red }
        if (s.decisions.oldest.first?.age_days ?? 0) >= 1 || s.agents.contains(where: { $0.health == "stuck" }) { return .orange }
        return .none
    }

    var rows: Int { min(status?.agents.count ?? 0, 16) }
}

// MARK: - Notch panel

final class Hover: ObservableObject {
    @Published var openH: CGFloat = 176
    @Published var hovered: String?
    var rowWork: DispatchWorkItem?
    @Published var expanded = false
    @Published var notch = CGSize(width: 200, height: 32)
    @Published var hasNotch = false
}

let openW: CGFloat = 400
let baseH: CGFloat = 176      // the sleep controls
let statusH: CGFloat = 54     // the two summary lines
let detailH: CGFloat = 52     // second-level detail under the list
func opsHeight(_ ops: Ops) -> CGFloat { ops.status == nil ? 30 : statusH + CGFloat(ops.rows) * 18 + 6 + detailH }

struct NotchView: View {
    @ObservedObject var m: Model
    @ObservedObject var h: Hover
    @ObservedObject var ops: Ops
    let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

    var body: some View {
        let w = h.expanded ? openW : h.notch.width
        let ht = h.expanded ? h.openH : h.notch.height
        let shape = UnevenRoundedRectangle(bottomLeadingRadius: h.expanded ? 26 : 10,
                                           bottomTrailingRadius: h.expanded ? 26 : 10, style: .continuous)
        // The content is clipped to the black shape, so it can never show without its background.
        ZStack(alignment: .top) {
            Color.black
            if h.expanded {
                content
                    .frame(width: openW - 40)
                    .padding(.top, max(h.notch.height, 12) + 8)
                    .transition(.asymmetric(
                        insertion: .opacity.animation(.easeOut(duration: 0.2).delay(0.08)),
                        removal: .opacity.animation(.easeIn(duration: 0.12))))
            }
        }
        .frame(width: w, height: ht, alignment: .top)
        .clipShape(shape)
        .overlay(alignment: .top) {
            // A thin line under the collapsed notch. Static, so reduce motion needs nothing.
            if !h.expanded, h.hasNotch, ops.alert != .none {
                Capsule().fill(ops.alert == .red ? Color.red : Color.orange).opacity(0.85)
                    .frame(width: h.notch.width * 0.7, height: 2).offset(y: h.notch.height + 1)
            }
        }
        .shadow(color: .black.opacity(h.expanded ? 0.35 : 0), radius: 16, y: 6)
        .opacity(h.expanded || h.hasNotch ? 1 : 0)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .frame(width: openW + 20, height: h.openH + 20, alignment: .top)
        .animation(reduceMotion ? nil : .spring(response: 0.38, dampingFraction: 0.82), value: h.expanded)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: m.isOn)
        .preferredColorScheme(.dark)
    }

    var opsView: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let s = ops.status {
                let n = s.decisions.count, old = s.decisions.oldest.first?.age_days
                HStack(spacing: 6) {
                    Text(n == 0 ? "No decisions wait on you" : "\(n) decision\(n == 1 ? "" : "s") wait on you" + (old.map { $0 == 0 ? " (oldest today)" : " (oldest \($0) d)" } ?? ""))
                        .font(.system(size: 12, weight: .semibold)).foregroundStyle(n == 0 ? Color.green : .orange)
                    Spacer()
                    Text("open ›").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                let failing = s.jobs.failing?.count ?? 0
                HStack(spacing: 12) {
                    flag("Runner", s.runner.ok ? "OK" : "down", s.runner.ok)
                    flag("Triage", s.triage.on ? "on" : "off", s.triage.on)
                    flag("Jobs", s.jobs.failing == nil ? "?" : failing == 0 ? "OK" : "\(failing) failing", s.jobs.failing != nil && failing == 0)
                    Spacer()
                }
                .padding(.bottom, 2)
                ForEach(Array(s.agents.prefix(16).enumerated()), id: \.offset) { _, a in
                    HStack(spacing: 6) {
                        Circle().fill(color(a.health)).frame(width: 7, height: 7)
                        Text(a.name).font(.system(size: 11)).lineLimit(1).frame(width: 130, alignment: .leading)
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.white.opacity(0.12))
                            GeometryReader { g in Capsule().fill(color(a.health)).frame(width: g.size.width * CGFloat(a.progress ?? 0)) }
                        }.frame(height: 4)
                        Text(a.progress.map { "\(Int($0 * 100))%" } ?? "n/a").font(.system(size: 10)).foregroundStyle(.secondary).frame(width: 32, alignment: .trailing)
                        Text("\(a.done_today) today").font(.system(size: 10)).foregroundStyle(a.done_today > 0 ? .white : .secondary).frame(width: 52, alignment: .trailing)
                    }
                    .frame(height: 18)
                    .contentShape(Rectangle())
                    .onHover { inside in h.rowWork?.cancel()
                        if inside {   // second level only after the pointer rests 400 ms on the row
                            let w = DispatchWorkItem { h.hovered = a.name }
                            h.rowWork = w
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: w)
                        } else if h.hovered == a.name { h.hovered = nil } }
                }
                detail(s)
            } else {
                Text(ops.offline ? "Ops dashboard offline (127.0.0.1:8788)" : "Reading ops status...")
                    .font(.system(size: 12)).foregroundStyle(ops.offline ? Color.red : .secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture { NSWorkspace.shared.open(opsURL) }
    }

    // Second level: the oldest 3 decisions, or the next action and the wait of the hovered agent.
    func detail(_ s: OpsStatus) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            if let name = h.hovered, let a = s.agents.first(where: { $0.name == name }) {
                Text("Next: " + ((a.next ?? "").isEmpty ? "none queued" : a.next!)).lineLimit(2)
                Text("Waiting on: " + ((a.waiting_on ?? []).isEmpty ? "nobody" : a.waiting_on!.joined(separator: ", "))).lineLimit(1)
            } else {
                ForEach(Array(s.decisions.oldest.prefix(3).enumerated()), id: \.offset) { _, d in
                    Text("\(d.age_days) d  \(d.title ?? d.id ?? "")").lineLimit(1)
                }
                if s.decisions.oldest.isEmpty { Text("No open decisions") }
            }
        }
        .font(.system(size: 10)).foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, minHeight: detailH - 8, maxHeight: detailH - 8, alignment: .topLeading)
        .padding(.top, 6)
    }

    func color(_ health: String) -> Color {
        switch health { case "earning": return .green; case "quiet": return .yellow; case "stuck", "error": return .red; default: return .gray }
    }

    func flag(_ title: String, _ value: String, _ ok: Bool) -> some View {
        HStack(spacing: 4) {
            Circle().fill(ok ? Color.green : .red).frame(width: 6, height: 6)
            Text("\(title) \(value)").font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }

    var content: some View {
        VStack(spacing: 14) {
            opsView
            Divider().overlay(Color.white.opacity(0.15))
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
    let ops = Ops()
    var opsTimer: Timer?
    var panel: Panel!
    var screen: NSScreen?
    var closeWork: DispatchWorkItem?
    var dwellStart: Date?

    func applicationDidFinishLaunching(_: Notification) {
        panel = Panel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.contentView = NSHostingView(rootView: NotchView(m: model, h: hover, ops: ops))
        ops.onChange = { [weak self] in self?.resize() }
        NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in
            guard let self, !self.hover.expanded else { return }
            let p = NSEvent.mouseLocation
            if let s = NSScreen.screens.first(where: { NSMouseInRect(p, $0.frame, false) }) {
                if NSMouseInRect(p, self.hotRect(s.frame), false) { self.setExpanded(true, why: "click") }
            }
        }
        ops.refresh()
        Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in self?.ops.refresh() }  // keeps the collapsed tint fresh
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
        panel.setFrame(NSRect(x: f.midX - (openW + 20) / 2, y: f.maxY - (hover.openH + 20),
                              width: openW + 20, height: hover.openH + 20), display: true)
    }

    // The panel grows with the agent list. The window is resized with it so it never blocks clicks below.
    func resize() {
        hover.openH = baseH + opsHeight(ops) + 48
        place(on: screen ?? NSScreen.main ?? NSScreen.screens[0])
    }

    // The notch width plus 40 px each side, and the top 8 px of the screen under the notch.
    func hotRect(_ f: NSRect) -> NSRect {
        let w = hover.notch.width + 80, h = max(hover.notch.height, 4) + 8
        return NSRect(x: f.midX - w / 2, y: f.maxY - h, width: w, height: h + 1)
    }

    func track() {
        let p = NSEvent.mouseLocation
        guard let s = NSScreen.screens.first(where: { NSMouseInRect(p, $0.frame, false) }) else { return }
        let f = s.frame
        if hover.expanded {
            let open = NSRect(x: f.midX - openW / 2 - 16, y: f.maxY - hover.openH - 16,
                              width: openW + 32, height: hover.openH + 16)
            // Stays open while the pointer is over the notch zone or the panel. Closes 300 ms after it leaves both.
            if NSMouseInRect(p, open, false) || NSMouseInRect(p, hotRect(f), false) { closeWork?.cancel(); closeWork = nil }
            else if closeWork == nil {
                let w = DispatchWorkItem { [weak self] in self?.setExpanded(false) }
                closeWork = w
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: w)
            }
        } else {
            if s != screen { place(on: s) }
            let hot = hotRect(f)
            // Opens only after the pointer rests 300 ms in the notch zone. A pass-through never opens it. A click is the second trigger.
            if NSMouseInRect(p, hot, false) {
                let t0 = dwellStart ?? Date()
                dwellStart = t0
                if Date().timeIntervalSince(t0) >= 0.3 { setExpanded(true, why: "rest-300ms") }
            } else { dwellStart = nil }
        }
    }

    // Every open is logged with its trigger: ~/Library/Logs/Awake-opens.log. The panel opens for no other reason.
    func logOpen(_ why: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date())) open \(why)\n"
        let f = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Awake-opens.log")
        if let h = try? FileHandle(forWritingTo: f) { h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close() }
        else { try? Data(line.utf8).write(to: f) }
    }

    func setExpanded(_ on: Bool, why: String = "") {
        dwellStart = nil; closeWork?.cancel(); closeWork = nil
        guard hover.expanded != on else { return }
        if on { logOpen(why) }
        hover.expanded = on
        panel.ignoresMouseEvents = !on
        opsTimer?.invalidate(); opsTimer = nil
        if on {
            ops.refresh()
            opsTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.ops.refresh() }
        }
    }
}

let app = NSApplication.shared
let delegate = App()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
