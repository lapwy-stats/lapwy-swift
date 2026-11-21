import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// lapwy for iOS apps.
///
///     import Lapwy
///
///     Lapwy.start(site: "lw_…", app: "kaira-math", collect: .minimal)   // once, at launch
///     Lapwy.screen("Home")                                               // on every screen
///     Lapwy.track("mission_done", props: ["skill": "addition"])
///     Lapwy.isEnabled = false                                            // a parent's "off" switch
///
/// A person is told apart by one random id per install, kept in UserDefaults.
/// Events wait in a queue that survives being offline and the app being
/// closed. Time on a screen counts only while the app is in front.
///
/// Sent on its own: every launch and return to the foreground (open), how long
/// a launch took to its first screen (start), a run that ended while the app
/// was in front, which is how crashes show (ended), a new version or build
/// (update), and every time the main thread froze for 0.7 seconds or more
/// while the app was in front (freeze).
public enum Lapwy {
    /// This package's version, as its release tag.
    public static let version = "0.1.0"

    /// Starts lapwy. Call it once, as the app launches, before the first screen.
    ///
    /// - Parameters:
    ///   - site: the app's public key, from its Install screen in lapwy.
    ///   - app: a short name for the app; it stands where a website's domain would. The bundle id's last part when left out.
    ///   - collect: what may be said about the device and the person. `.standard` is everything; `.minimal` none of it.
    ///   - enabledByDefault: whether tracking is on until someone switches it with `isEnabled`.
    ///     Pass false for "off until a parent allows it". Once set, the stored choice wins.
    ///   - reportErrors: uncaught Objective-C exceptions are reported as crashes. Other crashes show as runs that ended.
    ///   - endpoint: where events go. lapwy's own ingest when left out.
    @MainActor
    public static func start(site: String, app: String? = nil, collect: Collect = .standard, enabledByDefault: Bool = true,
                             reportErrors: Bool = true, endpoint: URL? = nil)
    {
        guard !site.isEmpty, hub.engine == nil else { return }
        let info = Bundle.main.infoDictionary ?? [:]
        let name = (app ?? Bundle.main.bundleIdentifier?.split(separator: ".").last.map(String.init) ?? "app")
            .lowercased().replacingOccurrences(of: #"[^a-z0-9.-]+"#, with: "-", options: .regularExpression)
        let cfg = Config(
            site: site,
            app: name.isEmpty ? "app" : name,
            endpoint: endpoint ?? URL(string: "https://i.lapwy.com/e")!,
            collect: collect,
            version: String((info["CFBundleShortVersionString"] as? String ?? "").prefix(64)),
            buildNumber: String((info["CFBundleVersion"] as? String ?? "").prefix(32)),
            buildType: debugBuild ? "dev" : "release",
            simulator: simulator,
            errors: reportErrors
        )
        let device = readDevice()
        let wasActive = isActive()
        hub.enabledByDefault = enabledByDefault
        let enabled = storedChoice() ?? enabledByDefault
        let engine = Engine(
            cfg: cfg, device: device, store: Defaults(), transport: Network(queue: hub.queue), sched: Timers(queue: hub.queue),
            now: wallClock,
            nextFrame: { work in DispatchQueue.main.async { hub.queue.async(execute: work) } },
            log: { print($0) }
        )
        let early = hub.take(engine)
        hub.queue.async {
            engine.boot(active: wasActive, enabled: enabled)
            early.forEach { $0(engine) }
        }
        Glue.shared.attach(active: wasActive, errors: reportErrors)
    }

    /// The person is looking at a screen. Call it when a screen comes up, with its name or path.
    public static func screen(_ name: String, props: Props? = nil) {
        hub.run { $0.screen(name, props: props) }
    }

    /// Something the person did: track("mission_done", props: ["skill": "addition"]).
    public static func track(_ name: String, props: Props? = nil) {
        hub.run { $0.track(name, props: props) }
    }

    /// A navigation begins: the screen reported next is timed from now to the
    /// frame after it is reported, and sent as how long it took to open.
    /// Call it just before you push a screen or switch a tab.
    public static func navigating() {
        let at = uptime()
        hub.run { $0.navigating(at: at) }
    }

    /// The link that opened the app. Call it from SwiftUI's onOpenURL or the app delegate.
    /// Only campaign tags of its query are sent.
    public static func opened(url: URL) {
        let raw = url.absoluteString
        hub.run { $0.linked(raw) }
    }

    /// What opened the app, when only the app can know: a tapped push.
    ///
    ///     Lapwy.opened(via: "push", campaign: "spring-sale")
    public static func opened(via: String, campaign: String? = nil) {
        hub.run { $0.opened(via: via, campaign: campaign ?? "") }
    }

    /// Who is signed in: your own id for the account, never an email. Kept in
    /// memory only; lapwy stores a one-way hash of it. Needs `.users` in collect.
    public static func identify(_ userId: String?) {
        hub.run { $0.identify(userId) }
    }

    /// The RevenueCat app user id of this install, so that payments can be
    /// matched to the person. Needs `.users` in collect.
    public static func setRevenueCatId(_ id: String?) {
        hub.run { $0.setRevenueCatId(id) }
    }

    /// Whether lapwy tracks at all, for an in-app switch (a parents' area).
    /// Remembered across launches. Switching it off throws away what waits to
    /// be sent and forgets the install id; switching it back on starts as a new install.
    /// May be set before start().
    public static var isEnabled: Bool {
        get { storedChoice() ?? hub.enabledByDefault }
        set {
            UserDefaults.standard.set(newValue, forKey: enabledKey)
            hub.run { $0.setEnabled(newValue) }
        }
    }

    /// Sends what waits, now. It happens on its own a moment after anything is
    /// tracked and when the app goes to the background.
    public static func flush() {
        hub.run { $0.flush() }
    }
}

// MARK: - Where calls go

/// The one engine and its queue. Calls made before start() wait for it, in order.
final class Hub: @unchecked Sendable {
    let queue = DispatchQueue(label: "com.lapwy.sdk")
    private let lock = NSLock()
    private var _engine: Engine?
    private var early: [@Sendable (Engine) -> Void] = []
    var enabledByDefault = true

    var engine: Engine? { lock.lock(); defer { lock.unlock() }; return _engine }

    func run(_ work: @escaping @Sendable (Engine) -> Void) {
        lock.lock()
        guard let e = _engine else {
            if early.count < 100 { early.append(work) }
            lock.unlock()
            return
        }
        lock.unlock()
        queue.async { work(e) }
    }

    /// Sets the engine and hands back what was asked for before it.
    func take(_ e: Engine) -> [@Sendable (Engine) -> Void] {
        lock.lock(); defer { lock.unlock() }
        _engine = e
        let waiting = early
        early = []
        return waiting
    }

    /// Runs work on the queue and waits for it: for a crash, when the process is about to end.
    func now(_ work: (Engine) -> Void) {
        guard let e = engine else { return }
        if DispatchQueue.getSpecific(key: hubKey) != nil { work(e) } else { queue.sync { work(e) } }
    }
}

private let hubKey = DispatchSpecificKey<Bool>()
let hub: Hub = {
    let h = Hub()
    h.queue.setSpecific(key: hubKey, value: true)
    return h
}()

private func storedChoice() -> Bool? {
    UserDefaults.standard.object(forKey: enabledKey) as? Bool
}

@Sendable private func wallClock() -> Int64 { Int64((Date().timeIntervalSince1970 * 1000).rounded()) }

#if DEBUG
private let debugBuild = true
#else
private let debugBuild = false
#endif

#if targetEnvironment(simulator)
private let simulator: Bool? = true
#else
private let simulator: Bool? = false
#endif

// MARK: - Storage, network, timers

final class Defaults: KeyValueStore, @unchecked Sendable {
    let d = UserDefaults.standard
    func data(_ key: String) -> Data? { d.data(forKey: key) }
    func string(_ key: String) -> String? { d.string(forKey: key) }
    func set(_ value: Any?, _ key: String) {
        if let value { d.set(value, forKey: key) } else { d.removeObject(forKey: key) }
    }
}

final class Network: Transport, @unchecked Sendable {
    let queue: DispatchQueue
    let session: URLSession

    init(queue: DispatchQueue) {
        self.queue = queue
        let c = URLSessionConfiguration.ephemeral
        // CFNetwork's own User-Agent names the app and the Darwin version: lapwy's says only what sent it.
        c.httpAdditionalHeaders = ["User-Agent": "lapwy-swift/" + Lapwy.version]
        c.timeoutIntervalForRequest = 30
        session = URLSession(configuration: c)
    }

    func post(_ body: Data, to url: URL, done: @escaping @Sendable (Int?) -> Void) {
        var r = URLRequest(url: url)
        r.httpMethod = "POST"
        r.setValue("text/plain", forHTTPHeaderField: "Content-Type")
        r.httpBody = body
        let queue = self.queue
        session.dataTask(with: r) { _, response, _ in
            let status = (response as? HTTPURLResponse)?.statusCode
            queue.async { done(status) }
        }.resume()
    }
}

final class Timers: Scheduler, @unchecked Sendable {
    let queue: DispatchQueue
    init(queue: DispatchQueue) { self.queue = queue }

    final class Item: Cancellable {
        let work: DispatchWorkItem
        init(_ w: DispatchWorkItem) { work = w }
        func cancel() { work.cancel() }
    }

    func after(_ seconds: Double, _ work: @escaping @Sendable () -> Void) -> Cancellable {
        let item = DispatchWorkItem(block: work)
        queue.asyncAfter(deadline: .now() + seconds, execute: item)
        return Item(item)
    }
}

// MARK: - The device

@MainActor
private func isActive() -> Bool {
    #if canImport(UIKit) && !os(watchOS)
    return UIApplication.shared.applicationState != .background
    #else
    return true
    #endif
}

@MainActor
private func readDevice() -> DeviceInfo {
    var d = DeviceInfo()
    #if canImport(UIKit) && !os(watchOS)
    let size = UIScreen.main.bounds.size
    d.width = Int(size.width.rounded())
    d.height = Int(size.height.rounded())
    d.tablet = UIDevice.current.userInterfaceIdiom == .pad
    let v = UIDevice.current.systemVersion
    #else
    let os = ProcessInfo.processInfo.operatingSystemVersion
    let v = "\(os.majorVersion).\(os.minorVersion)"
    #endif
    d.osVersion = v.split(separator: ".").prefix(2).joined(separator: ".")
    d.language = String((Locale.preferredLanguages.first ?? "").prefix(35))
    d.model = modelIdentifier()
    // iOS may start an app ahead of time (prewarming): the process is older than the tap.
    if ProcessInfo.processInfo.environment["ActivePrewarm"] != "1" { d.processStart = processStart() }
    return d
}

private func modelIdentifier() -> String {
    if let sim = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] { return sim }
    var sys = utsname()
    uname(&sys)
    let machine = withUnsafeBytes(of: &sys.machine) { raw in
        String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
    }
    return String(machine.prefix(64))
}

/// When this process began, ms since 1970, as the kernel knows it.
private func processStart() -> Int64? {
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.stride
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
    guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0 else { return nil }
    let t = info.kp_proc.p_un.__p_starttime
    let ms = Int64(t.tv_sec) * 1000 + Int64(t.tv_usec) / 1000
    return ms > 0 ? ms : nil
}

// MARK: - Foreground, background, freezes, crashes

/// Everything that must happen on the main thread: the app's comings and
/// goings, the freeze watch, the background time to send in.
@MainActor
final class Glue {
    static let shared = Glue()
    private var attached = false
    private var tick: Timer?
    private var ticked = 0.0

    func attach(active: Bool, errors: Bool) {
        guard !attached else { return }
        attached = true
        #if canImport(UIKit) && !os(watchOS)
        let c = NotificationCenter.default
        c.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { Glue.shared.watch(true) }
            hub.run { $0.becameActive() }
        }
        c.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { Glue.shared.watch(false) }
            hub.run { $0.resigned(background: false) }
        }
        c.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { Glue.shared.background() }
        }
        #endif
        if active { watch(true) }
        if errors { catchExceptions() }
    }

    #if canImport(UIKit) && !os(watchOS)
    /// Going to the background is the last sure moment to send: iOS is asked for a few seconds to do it in.
    private var task = UIBackgroundTaskIdentifier.invalid

    private func background() {
        watch(false)
        endTask()
        task = UIApplication.shared.beginBackgroundTask(withName: "lapwy") {
            MainActor.assumeIsolated { Glue.shared.endTask() }
        }
        hub.run { $0.resigned(background: true) { DispatchQueue.main.async { MainActor.assumeIsolated { Glue.shared.endTask() } } } }
    }

    private func endTask() {
        if task != .invalid { UIApplication.shared.endBackgroundTask(task) }
        task = .invalid
    }
    #endif

    /// The freeze watch: a timer on the main thread that ticks every half
    /// second while the app is in front. A tick 0.7 seconds or more late means
    /// the main thread did nothing else for that long: taps and scrolls did not answer.
    private func watch(_ on: Bool) {
        tick?.invalidate()
        tick = nil
        guard on else { return }
        ticked = uptime()
        let t = Timer(timeInterval: 0.5, repeats: true) { _ in
            MainActor.assumeIsolated {
                let g = Glue.shared
                let now = uptime()
                let late = (now - g.ticked - 0.5) * 1000
                g.ticked = now
                if late >= minFreeze { hub.run { $0.froze(late) } }
            }
        }
        RunLoop.main.add(t, forMode: .common)
        tick = t
    }

    private func catchExceptions() {
        previousHandler = NSGetUncaughtExceptionHandler()
        NSSetUncaughtExceptionHandler { exception in
            hub.now { $0.error(name: exception.name.rawValue, message: exception.reason ?? exception.name.rawValue, fatal: true) }
            previousHandler?(exception)
        }
    }
}

/// The app's own handler (a crash reporter's) goes on as before.
nonisolated(unsafe) private var previousHandler: (@convention(c) (NSException) -> Void)?
