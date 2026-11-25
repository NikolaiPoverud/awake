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

// MARK: - Ops glance (ops-glance.py reads the board, the dispatcher and launchd; zero-base 25 Nov 2026)

struct Glance: Decodable {
    struct Item: Decodable { let id: String; let kind: String; let text: String; let age_h: Double?; let open: String? }
    struct Dispatch: Decodable {
        let paused: Bool; let loaded: Bool; let ok: Bool; let last_tick: String?; let age_min: Int?
        let live: Int; let max_live: Int?; let starts_today: Int; let max_day: Int?
        let usd_today: Double; let usd_cap: Double?; let pause_file: String; let log: String?; let runs: String?
    }
    struct Job: Decodable { let label: String; let status: String; let log: String? }
    struct Launchd: Decodable { let jobs: Int; let failed: [Job] }
    let waiting: [Item]; let names_you: [String]; let digest: String?; let board: String
    let dispatch: Dispatch; let launchd: Launchd; let closed_today: [String]
}

// The script ships inside the app (build.sh copies it to Resources).
let glanceScript = Bundle.main.path(forResource: "ops-glance", ofType: "py")
    ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("src/Awake/ops-glance.py").path

final class Ops: ObservableObject {
    @Published private(set) var g: Glance?
    @Published private(set) var error: String?
    var onChange: (() -> Void)?

    static func load() -> (Glance?, String?) {
        let p = Process(), out = Pipe(), err = Pipe()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        p.arguments = [glanceScript]
        p.standardOutput = out; p.standardError = err
        do { try p.run() } catch { return (nil, "ops-glance did not start") }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        if p.terminationStatus != 0 {
            let e = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            return (nil, "ops-glance failed: " + (e.split(separator: "\n").last.map(String.init) ?? "exit \(p.terminationStatus)"))
        }
        do { return (try JSONDecoder().decode(Glance.self, from: data), nil) }
        catch { return (nil, "ops-glance: bad JSON") }
    }

    // A failed read shows the error in red, never old numbers as fresh.
    func refresh() {
        DispatchQueue.global(qos: .utility).async {
            let (g, e) = Ops.load()
            DispatchQueue.main.async { self.g = g; self.error = e; self.onChange?() }
        }
    }

    func setForSnapshot(_ g: Glance) { self.g = g }

    func togglePause() {
        guard let d = g?.dispatch else { return }
        let fm = FileManager.default
        if d.paused { try? fm.removeItem(atPath: d.pause_file) }
        else { fm.createFile(atPath: d.pause_file, contents: Data("Paused from Awake \(ISO8601DateFormatter().string(from: Date()))\n".utf8)) }
        refresh()
    }

    // orange: something waits on him, or a launchd job failed. red: the dispatcher is down or stale, or the read failed.
    enum Alert { case none, orange, red }
    var alert: Alert {
        guard let g else { return error == nil ? .none : .red }
        if !g.dispatch.paused && !g.dispatch.ok { return .red }
        if !g.waiting.isEmpty || !g.launchd.failed.isEmpty { return .orange }
        return .none
    }

    var rows: Int { min(g?.waiting.count ?? 0, maxRows) }
}

let maxRows = 6

// Opens a file as text. A script is never run by a click.
func openText(_ path: String?) {
    guard let path, FileManager.default.fileExists(atPath: path) else { NSSound.beep(); return }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    p.arguments = ["-t", path]
    try? p.run()
}

func ageText(_ h: Double?) -> String {
    guard let h else { return "" }
    return h < 1 ? "\(max(1, Int(h * 60))) m" : h < 48 ? "\(Int(h)) h" : "\(Int(h / 24)) d"
}

// MARK: - Notch panel

final class Hover: ObservableObject {
    @Published var openH: CGFloat = 176
    @Published var expanded = false
    @Published var notch = CGSize(width: 200, height: 32)
    @Published var hasNotch = false
}

let openW: CGFloat = 400
let baseH: CGFloat = 176      // the sleep controls
let rowH: CGFloat = 20
func opsHeight(_ ops: Ops) -> CGFloat {
    guard let g = ops.g else { return 30 }
    let more: CGFloat = g.waiting.count > maxRows || !g.names_you.isEmpty ? rowH : 0
    return 24 + CGFloat(ops.rows) * rowH + more + 14 + 4 * rowH + 8
}

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

    // Three questions: what needs me now, is the machine healthy, what closed today.
    var opsView: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let g = ops.g {
                let n = g.waiting.count
                Button { openText(g.digest) } label: {
                    HStack(spacing: 6) {
                        Text(n == 0 ? "Nothing waits on you" : "\(n) wait\(n == 1 ? "s" : "") on you" + (g.waiting.first?.age_h).map { " · oldest \(ageText($0))" }.orEmpty)
                            .font(.system(size: 13, weight: .semibold)).foregroundStyle(n == 0 ? Color.green : .orange)
                        Spacer()
                        Text("digest ›").font(.system(size: 11)).foregroundStyle(.secondary)
                    }.frame(height: 24).contentShape(Rectangle())
                }.buttonStyle(.plain).help("Opens today's 08:15 digest")
                ForEach(g.waiting.prefix(maxRows), id: \.id) { it in
                    Button { openText(it.open) } label: {
                        HStack(spacing: 6) {
                            Text(it.kind).font(.system(size: 9, weight: .semibold)).foregroundStyle(.black)
                                .padding(.horizontal, 5).frame(width: 62, height: 14)
                                .background(Capsule().fill(it.kind == "yes?" ? Color.green : .orange))
                            Text(it.id).font(.system(size: 11, weight: .medium).monospacedDigit()).frame(width: 36, alignment: .leading)
                            Text(it.text).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                            Spacer(minLength: 4)
                            Text(ageText(it.age_h)).font(.system(size: 10).monospacedDigit()).foregroundStyle(.secondary)
                            Image(systemName: it.open == nil ? "minus" : "arrow.up.forward.square").font(.system(size: 10)).foregroundStyle(.secondary)
                        }.frame(height: rowH).contentShape(Rectangle())
                    }.buttonStyle(.plain).help(it.text + (it.open.map { "\nOpens " + $0 } ?? "\nNo file to open"))
                }
                if n > maxRows || !g.names_you.isEmpty {
                    let more = max(0, n - maxRows)
                    Button { openText(g.digest) } label: {
                        Text((more > 0 ? "+\(more) more. " : "") + (g.names_you.isEmpty ? "" : "\(g.names_you.count) other board items name you as next step"))
                            .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                            .frame(maxWidth: .infinity, minHeight: rowH, alignment: .leading).contentShape(Rectangle())
                    }.buttonStyle(.plain).help(g.names_you.joined(separator: ", "))
                }
                Divider().overlay(Color.white.opacity(0.15)).padding(.vertical, 6)
                machine(g)
            } else {
                Text(ops.error ?? "Reading ops status...")
                    .font(.system(size: 12)).foregroundStyle(ops.error == nil ? Color.secondary : .red).lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    func machine(_ g: Glance) -> some View {
        let d = g.dispatch
        let state = d.paused ? "paused" : !d.loaded ? "not loaded" : d.ok ? "on" : "stale"
        let color: Color = d.paused ? .yellow : d.ok ? .green : .red
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Button { openText(d.log) } label: {
                    HStack(spacing: 6) {
                        Circle().fill(color).frame(width: 7, height: 7)
                        Text("Dispatch \(state)").font(.system(size: 11, weight: .medium))
                        Text("· last \(d.last_tick ?? "never") · \(d.live)/\(d.max_live.map(String.init) ?? "?") live")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain).help("Opens dispatch.log")
                Spacer()
                Button(action: ops.togglePause) {
                    Label(d.paused ? "Resume" : "Pause", systemImage: d.paused ? "play.fill" : "pause.fill")
                        .font(.system(size: 10, weight: .medium)).padding(.horizontal, 8).frame(height: 18)
                        .background(Capsule().fill(Color.white.opacity(0.12)))
                }.buttonStyle(.plain).help(d.paused ? "Removes PAUSE-DISPATCH" : "Creates PAUSE-DISPATCH (the kill switch)")
            }.frame(height: rowH)
            line(d.usd_cap.map { d.usd_today > $0 * 0.8 } ?? false ? .orange : .green,
                 String(format: "Today $%.2f", d.usd_today) + (d.usd_cap.map { String(format: " of $%.0f cap", $0) } ?? "")
                 + " · \(d.starts_today)/\(d.max_day.map(String.init) ?? "?") starts", d.runs)
            let f = g.launchd.failed
            line(f.isEmpty ? .green : .red, f.isEmpty ? "launchd: \(g.launchd.jobs) jobs OK"
                 : "launchd: \(f.count) failed: " + f.map { "\($0.label) (\($0.status))" }.joined(separator: ", "), f.first?.log)
            line(g.closed_today.isEmpty ? .gray : .green, "Judge PASS today: \(g.closed_today.count)"
                 + (g.closed_today.isEmpty ? "" : " · " + g.closed_today.joined(separator: ", ")), g.board)
        }
    }

    func line(_ c: Color, _ text: String, _ path: String?) -> some View {
        Button { if path != nil { openText(path) } } label: {
            HStack(spacing: 6) {
                Circle().fill(c).frame(width: 7, height: 7)
                Text(text).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
            }.frame(height: rowH).contentShape(Rectangle())
        }.buttonStyle(.plain).disabled(path == nil).help(path.map { "Opens " + $0 } ?? "")
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

extension Optional where Wrapped == String { var orEmpty: String { self ?? "" } }

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

// Awake --snapshot <file.png>: renders the open panel with live numbers to a PNG and exits. For checks and judges.
if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--snapshot" {
    let m = Model(), h = Hover(), ops = Ops()
    let (g, e) = Ops.load()
    if let g { ops.setForSnapshot(g) } else { FileHandle.standardError.write(Data((e ?? "load failed").utf8)); exit(1) }
    h.expanded = true; h.notch = CGSize(width: 200, height: 32); h.hasNotch = true
    h.openH = baseH + opsHeight(ops) + 48
    MainActor.assumeIsolated {
        let r = ImageRenderer(content: NotchView(m: m, h: h, ops: ops).environment(\.colorScheme, .dark).background(Color(white: 0.2)))
        r.scale = 2
        guard let cg = r.cgImage, let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) else { exit(1) }
        try! png.write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
    }
    exit(0)
}

let app = NSApplication.shared
let delegate = App()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
