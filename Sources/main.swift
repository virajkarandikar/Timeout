import SwiftUI
import AppKit
import CryptoKit
import Combine

// MARK: - Persistent state

enum Store {
    private static let d = UserDefaults.standard
    static var passHash: String? { get { d.string(forKey: "passHash") } set { d.set(newValue, forKey: "passHash") } }
    static var salt: String? { get { d.string(forKey: "salt") } set { d.set(newValue, forKey: "salt") } }
    static var endDate: Date? { get { d.object(forKey: "endDate") as? Date } set { d.set(newValue, forKey: "endDate") } }

    static func hash(_ pass: String, salt: String) -> String {
        SHA256.hash(data: Data((salt + pass).utf8)).map { String(format: "%02x", $0) }.joined()
    }
    static func setPass(_ pass: String) {
        let s = UUID().uuidString
        salt = s; passHash = hash(pass, salt: s)
    }
    static func check(_ pass: String) -> Bool {
        guard let s = salt, let h = passHash else { return false }
        return hash(pass, salt: s) == h
    }
}

// MARK: - System lock

enum SystemLock {
    static func lockScreen() {
        typealias Fn = @convention(c) () -> Int32
        if let h = dlopen("/System/Library/PrivateFrameworks/login.framework/login", RTLD_NOW),
           let sym = dlsym(h, "SACLockScreenImmediate") {
            _ = unsafeBitCast(sym, to: Fn.self)()
            return
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        p.arguments = ["displaysleepnow"]
        try? p.run()
    }
}

// MARK: - Background agent
// A LaunchAgent runs this binary headless with --lock-at, so the lock still fires if the app is quit or force-quit.

enum Agent {
    static let label = "com.timeout.app.lock"
    static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }
    static func launchctl(_ args: [String]) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = args
        p.standardError = FileHandle.nullDevice
        try? p.run(); p.waitUntilExit()
    }
    static func schedule(at end: Date) {
        guard let exe = Bundle.main.executablePath else { return }
        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": [exe, "--lock-at", String(end.timeIntervalSince1970)],
            "RunAtLoad": true,
            "KeepAlive": ["SuccessfulExit": false],
            "ThrottleInterval": 1,
        ]
        try? FileManager.default.createDirectory(at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        (plist as NSDictionary).write(to: plistURL, atomically: true)
        launchctl(["bootout", "gui/\(getuid())/\(label)"])
        launchctl(["bootstrap", "gui/\(getuid())", plistURL.path])
    }
    static func cancel() {
        try? FileManager.default.removeItem(at: plistURL)
        launchctl(["bootout", "gui/\(getuid())/\(label)"])
    }
    /// Headless mode: wait for the end time, lock, and clean up.
    static func runHeadless(end: Date) -> Never {
        while Date() < end { Thread.sleep(forTimeInterval: 1) }
        SystemLock.lockScreen()
        Store.endDate = nil
        try? FileManager.default.removeItem(at: plistURL)
        exit(0)
    }
}

// MARK: - Model

enum Threshold {
    static let hud: TimeInterval = 60      // show the big countdown panel
    static let sound: TimeInterval = 10    // play the warning sound
    static let notice: TimeInterval = 300  // brief heads-up banner
}

func clock(_ seconds: TimeInterval) -> String {
    let t = Int(seconds.rounded(.up))
    return t >= 3600
        ? String(format: "%d:%02d:%02d", t / 3600, (t / 60) % 60, t % 60)
        : String(format: "%02d:%02d", t / 60, t % 60)
}

final class AppModel: ObservableObject {
    @Published var endDate: Date? = Store.endDate
    @Published var hasPass = Store.passHash != nil
    @Published var now = Date()
    private var ticker: Timer?

    init() {
        ticker = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.tick() }
    }

    var remaining: TimeInterval { max(0, (endDate ?? now).timeIntervalSince(now)) }

    func tick() {
        now = Date()
        if let e = endDate, now >= e { clearTimer() }
    }

    func start(minutes: Double) {
        let e = Date().addingTimeInterval(minutes * 60)
        Store.endDate = e; endDate = e
        Agent.schedule(at: e)
    }

    private func clearTimer() { Store.endDate = nil; endDate = nil }

    func setPass(_ p: String) { Store.setPass(p); hasPass = true }

    func cancel(pass: String) -> Bool {
        guard Store.check(pass) else { return false }
        Agent.cancel()
        clearTimer()
        return true
    }
}

// MARK: - Views

struct MainView: View {
    @ObservedObject var m: AppModel
    final class F: ObservableObject {
        @Published var minutes = 30.0
        @Published var p1 = ""
        @Published var p2 = ""
        @Published var cur = ""
        @Published var msg = ""
    }
    @StateObject private var f = F()

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "hourglass").font(.system(size: 40))
            Text("Timeout").font(.largeTitle.bold())
            if !m.hasPass {
                Text("Choose a passcode. You'll need it to cancel a running timer.")
                    .multilineTextAlignment(.center).foregroundStyle(.secondary)
                SecureField("Passcode (4+ characters)", text: $f.p1)
                SecureField("Confirm passcode", text: $f.p2)
                Button("Save Passcode") {
                    if f.p1.count < 4 { f.msg = "Use at least 4 characters." }
                    else if f.p1 != f.p2 { f.msg = "Passcodes don't match." }
                    else { m.setPass(f.p1); f.p1 = ""; f.p2 = ""; f.msg = "" }
                }.keyboardShortcut(.defaultAction)
            } else if m.endDate != nil {
                Text(clock(m.remaining)).font(.system(size: 56, weight: .light, design: .monospaced))
                Text("Your screen locks when this reaches zero, even if you quit this app.")
                    .multilineTextAlignment(.center).foregroundStyle(.secondary)
                SecureField("Passcode to cancel", text: $f.cur)
                Button("Cancel Timer") {
                    f.msg = m.cancel(pass: f.cur) ? "" : "Wrong passcode."
                    f.cur = ""
                }.keyboardShortcut(.defaultAction)
            } else {
                Text("Lock in")
                Picker("", selection: $f.minutes) {
                    ForEach([1.0, 5, 15, 30], id: \.self) { Text("\(Int($0)) min").tag($0) }
                }.pickerStyle(.segmented).labelsHidden()
                Button("Start Timer") { m.start(minutes: f.minutes) }.keyboardShortcut(.defaultAction)
            }
            if !f.msg.isEmpty { Text(f.msg).foregroundStyle(.red) }
        }
        .textFieldStyle(.roundedBorder)
        .padding(30).frame(width: 360)
    }
}

struct CountdownHUD: View {
    @ObservedObject var m: AppModel
    var body: some View {
        let secs = Int(m.remaining.rounded(.up))
        VStack(spacing: 6) {
            Text("SCREEN LOCKS IN").font(.system(size: 13, weight: .semibold)).tracking(1.5)
                .foregroundStyle(.white.opacity(0.7))
            Text("\(secs)").font(.system(size: 84, weight: .bold, design: .rounded)).monospacedDigit()
                .foregroundStyle(.white)
            ProgressView(value: min(1, m.remaining / Threshold.hud)).progressViewStyle(.linear).tint(.orange)
        }
        .padding(.horizontal, 28).padding(.vertical, 20)
        .frame(width: 280)
        .background(RoundedRectangle(cornerRadius: 24).fill(Color.black.opacity(0.82)))
        .padding(10)
    }
}

struct NoticeHUD: View {
    let lockTime: Date
    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "hourglass").font(.system(size: 30)).foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("5 minutes left").font(.system(size: 20, weight: .bold)).foregroundStyle(.white)
                Text("Screen locks at \(lockTime.formatted(date: .omitted, time: .shortened))")
                    .font(.system(size: 13)).foregroundStyle(.white.opacity(0.7))
            }
        }
        .padding(.horizontal, 24).padding(.vertical, 18)
        .background(RoundedRectangle(cornerRadius: 20).fill(Color.black.opacity(0.82)))
        .padding(10)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    private var mainWindow: NSWindow!
    private var statusItem: NSStatusItem?
    private var hud: NSPanel!
    private var notice: NSPanel?
    private var lastRemaining: TimeInterval?
    private var soundPlayed = false
    private var cancellable: AnyCancellable?

    func applicationDidFinishLaunching(_ n: Notification) {
        NSApp.setActivationPolicy(.regular)
        setUpMainWindow()
        setUpHUD()
        cancellable = model.$now.sink { [weak self] _ in self?.refresh() }
        model.tick()
        refresh()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool { model.endDate == nil }

    func applicationShouldHandleReopen(_ app: NSApplication, hasVisibleWindows: Bool) -> Bool {
        showWindow(); return true
    }

    // MARK: Setup

    private func setUpMainWindow() {
        mainWindow = NSWindow(contentRect: .zero, styleMask: [.titled, .closable, .miniaturizable],
                              backing: .buffered, defer: false)
        mainWindow.title = "Timeout"
        mainWindow.contentView = NSHostingView(rootView: MainView(m: model))
        mainWindow.isReleasedWhenClosed = false
        mainWindow.center()
        showWindow()
    }

    private func makeStatusItem() -> NSStatusItem {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.addItem(withTitle: "Show Timeout", action: #selector(showWindow), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = menu
        item.button?.image = NSImage(systemSymbolName: "hourglass", accessibilityDescription: "Timeout")
        item.button?.imagePosition = .imageLeft
        return item
    }

    private func setUpHUD() {
        hud = makeOverlay(CountdownHUD(m: model))
    }

    /// A click-through panel that floats above everything, including full-screen apps.
    private func makeOverlay<V: View>(_ view: V) -> NSPanel {
        let host = NSHostingView(rootView: view)
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: host.fittingSize),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.contentView = host
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.isReleasedWhenClosed = false
        return panel
    }

    private func placeTopRight(_ panel: NSPanel) {
        guard let f = NSScreen.screens.first?.visibleFrame else { return }
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: f.maxX - size.width - 10, y: f.maxY - size.height - 10))
    }

    @objc private func showWindow() {
        mainWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: Updates

    private func refresh() {
        updateStatusItem()
        updateHUD()
        updateSound()
        updateNotice()
    }

    /// The menu bar item exists only while a timer is running.
    private func updateStatusItem() {
        guard model.endDate != nil else {
            if let item = statusItem { NSStatusBar.system.removeStatusItem(item); statusItem = nil }
            return
        }
        if statusItem == nil { statusItem = makeStatusItem() }
        statusItem?.button?.attributedTitle = NSAttributedString(
            string: " " + clock(model.remaining),
            attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular)])
    }

    private func updateHUD() {
        let show = model.endDate != nil && model.remaining <= Threshold.hud
        if show, !hud.isVisible {
            placeTopRight(hud)
            hud.orderFrontRegardless()
        } else if !show, hud.isVisible {
            hud.orderOut(nil)
        }
    }

    /// Briefly shows a banner when the remaining time first drops to five minutes.
    private func updateNotice() {
        guard let end = model.endDate else { lastRemaining = nil; return }
        let remaining = model.remaining
        defer { lastRemaining = remaining }
        guard let last = lastRemaining, last > Threshold.notice, remaining <= Threshold.notice else { return }

        let panel = makeOverlay(NoticeHUD(lockTime: end))
        placeTopRight(panel)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        panel.animator().alphaValue = 1
        notice = panel
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.5; panel.animator().alphaValue = 0 }) {
                panel.orderOut(nil)
                if self?.notice === panel { self?.notice = nil }
            }
        }
    }

    private func updateSound() {
        let warn = model.endDate != nil && model.remaining <= Threshold.sound
        if warn && !soundPlayed { NSSound(named: "Glass")?.play() }
        soundPlayed = warn
    }
}

if let i = CommandLine.arguments.firstIndex(of: "--lock-at"), i + 1 < CommandLine.arguments.count,
   let t = TimeInterval(CommandLine.arguments[i + 1]) {
    Agent.runHeadless(end: Date(timeIntervalSince1970: t))
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
