import Foundation

// The engine holds everything lapwy knows in a run. Every method runs on its
// queue (Lapwy hands calls to it there), so nothing in it needs a lock. Time,
// storage, the network and timers come from outside, so that tests can stand
// in for them.

/// Where the id, the queue and the run's mark are kept. UserDefaults in an app.
protocol KeyValueStore: AnyObject, Sendable {
    func data(_ key: String) -> Data?
    func string(_ key: String) -> String?
    func set(_ value: Any?, _ key: String)
}

/// Posts one batch; done gets the HTTP status, or nil when nothing came back.
protocol Transport: AnyObject, Sendable {
    func post(_ body: Data, to url: URL, done: @escaping @Sendable (Int?) -> Void)
}

protocol Cancellable { func cancel() }

/// Runs work later on the engine's queue.
protocol Scheduler: AnyObject, Sendable {
    func after(_ seconds: Double, _ work: @escaping @Sendable () -> Void) -> Cancellable
}

struct Config {
    var site: String
    var app: String
    var endpoint: URL
    var collect: Collect
    var version: String
    var buildNumber: String
    var buildType: String
    var simulator: Bool?
    var errors: Bool
}

/// What the device is, read once at start. Collect decides what of it is sent.
struct DeviceInfo {
    var model = ""
    var osVersion = ""
    var tablet = false
    var width = 0
    var height = 0
    var language = ""
    /// When the process began (ms since 1970), nil when it cannot be known
    /// or the system started it ahead of time (prewarming): a start time from it would be wrong.
    var processStart: Int64?
}

let idKey = "lapwy_device_id"
let installedKey = "lapwy_installed"
let queueKey = "lapwy_queue"
let runKey = "lapwy_run"
let enabledKey = "lapwy_enabled"

let maxQueue = 500
let batchSize = 50
/// How often the run's mark is written while in front: a kill loses at most this much screen time.
let beatSeconds = 15.0
/// How long an open waits for what opened it (a link, a push) before it is sent.
let openWait = 3.0
/// A launch's open also waits for the first screen, so that it says where the app opened, but no longer.
let firstScreenWait = 10.0
/// How long after an open opened(via:) may still name it, as a late open.
let lateOpen: Int64 = 60_000
let maxStart: Int64 = 60_000
let minFreeze = 700.0
let maxFreeze = 60_000.0
let maxFreezes = 10
let maxNav = 30_000.0
let maxErrors = 10

final class Engine: @unchecked Sendable {
    let cfg: Config
    let device: DeviceInfo
    let store: KeyValueStore
    let transport: Transport
    let sched: Scheduler
    /// Wall clock, ms since 1970.
    let now: @Sendable () -> Int64
    /// The next frame on the main thread, then back on the engine's queue.
    let nextFrame: @Sendable (@escaping @Sendable () -> Void) -> Void
    let log: @Sendable (String) -> Void

    var id = ""
    var user = ""
    var installed: Int64 = 0
    var queue: [Wire] = []
    var held = Set<String>()
    var screenUrl: String
    var screenId = ""
    var shownAt: Int64 = 0
    var engaged: Int64 = 0
    var timer: Cancellable?
    var timerAt = 0.0
    var backoff = 0
    var sending = false
    var out = false
    var began: Int64
    var bgAt: Int64 = 0
    var lastRun: Int64 = 0
    var install = false
    var active = false
    /// The process started in the background: its first return to the front is its launch.
    var coldLater = false
    var open: String?
    var link: (url: String, at: Int64)?
    var push: (name: String, campaign: String, at: Int64)?
    var openDue = false
    var releaseTimer: Cancellable?
    var sentOpen: (cold: Bool, at: Int64, named: Bool)?
    var timing = false
    var errors: [String: (id: String, fatal: Bool)] = [:]
    var fails = 0
    var warned = false
    var revenuecat = ""
    var beat: Cancellable?
    var navAt: Double = 0
    var freezes = 0
    var idle: [@Sendable () -> Void] = []

    init(cfg: Config, device: DeviceInfo, store: KeyValueStore, transport: Transport, sched: Scheduler,
         now: @escaping @Sendable () -> Int64, nextFrame: @escaping @Sendable (@escaping @Sendable () -> Void) -> Void,
         log: @escaping @Sendable (String) -> Void = { _ in })
    {
        self.cfg = cfg
        self.device = device
        self.store = store
        self.transport = transport
        self.sched = sched
        self.now = now
        self.nextFrame = nextFrame
        self.log = log
        began = now()
        screenUrl = screenURL(cfg.app, "")
    }

    // MARK: Start

    /// The process starts: read what the last run left, then report this launch.
    /// enabled is the person's choice, or the app's default when they made none.
    func boot(active: Bool, enabled: Bool) {
        self.active = active
        out = !enabled
        if out {
            forget()
            return
        }
        load()
        if active {
            opening(cold: true)
            timing = device.processStart != nil
        } else {
            coldLater = true
            bgAt = now()
        }
        mark()
        scheduleBeat()
    }

    private func load() {
        let stored = store.string(idKey)
        let fresh: Bool
        if let s = stored, s.range(of: "^[0-9a-f]{16,64}$", options: .regularExpression) != nil {
            id = s
            fresh = false
        } else {
            id = hex(16)
            fresh = true
            store.set(id, idKey)
        }
        // A new id is a new install.
        if !fresh, let raw = store.string(installedKey), let at = Int64(raw), raw.count >= 9, raw.count <= 11 {
            installed = at
        } else {
            installed = now() / 1000
            store.set(String(installed), installedKey)
        }
        // Events from the last run that never got out go first.
        var old: [Wire] = []
        if let data = store.data(queueKey), let q = try? JSONDecoder().decode([Wire].self, from: data) { old = q }
        queue = Array((old + queue).suffix(maxQueue))
        var run: Run?
        if let data = store.data(runKey) { run = try? JSONDecoder().decode(Run.self, from: data) }
        previous(run, fresh: fresh)
        save()
    }

    /// What happened before this launch, read from the run's mark: a run that ended in front, an update.
    private func previous(_ run: Run?, fresh: Bool) {
        install = fresh
        if let r = run, !fresh { lastRun = r.h }
        guard let run, !fresh else { return }
        let before = Made(bt: run.bt, rel: run.rel, bn: run.bn, upd: run.upd)
        let same = before == made()
        // What the last run left in the queue was made in its build.
        if !same { for i in queue.indices where queue[i].made == nil { queue[i].made = before } }
        if run.f == 1 {
            // The last run never went to the background: it crashed, the system ended it, or it was force-quit.
            if !run.p.isEmpty && run.e >= 1000 {
                add("engagement", t: run.h, u: run.u, p: run.p, v: Double(run.e), made: same ? nil : before)
            }
            add("ended", u: run.u.isEmpty ? screenUrl : run.u, p: run.p, props: [
                "bt": .string(run.bt), "rel": .string(run.rel), "bn": .string(run.bn), "upd": .string(run.upd),
                "started": .int(run.s), "ran": .int(max(run.h - run.s, 0)), "run": .int(run.s),
            ])
        }
        if cfg.version != run.rel || cfg.buildNumber != run.bn {
            let what = cfg.version != run.rel ? "version" : "build"
            add("update", n: what, props: ["from": .string(run.rel), "from_bn": .string(run.bn), "from_upd": .string(run.upd)])
        }
    }

    func made() -> Made { Made(bt: cfg.buildType, rel: cfg.version, bn: cfg.buildNumber, upd: "") }

    // MARK: Queue

    @discardableResult
    func add(_ kind: String, t: Int64? = nil, u: String? = nil, p: String? = nil, n: String? = nil, r: String? = nil,
             ti: String? = nil, v: Double? = nil, props: Props? = nil, made: Made? = nil) -> String?
    {
        if out { return nil }
        let e = Wire(id: uuid(), t: t ?? now(), k: kind, u: u ?? screenUrl, p: p ?? screenId, n: n, r: r, ti: ti, v: v,
                     props: props?.isEmpty == false ? props : nil, made: made)
        queue.append(e)
        // Offline for a long time: the oldest events go first.
        if queue.count > maxQueue { queue.removeFirst(queue.count - maxQueue) }
        save()
        soon(2)
        return e.id
    }

    func save() {
        if out { return }
        store.set(try? JSONEncoder().encode(queue), queueKey)
    }

    private func soon(_ seconds: Double) {
        if timer != nil { return }
        timer = sched.after(seconds) { [weak self] in self?.timer = nil; self?.send() }
    }

    private func edit(_ id: String, _ change: (inout Wire) -> Void) {
        if let i = queue.firstIndex(where: { $0.id == id }) { change(&queue[i]) }
    }

    private func find(_ id: String) -> Wire? { queue.first { $0.id == id } }

    // MARK: Sending

    /// Sends what is ready. done runs once this attempt is over, sent or not.
    func send(done: (@Sendable () -> Void)? = nil) {
        timer?.cancel()
        timer = nil
        if let done { idle.append(done) }
        // An open waiting for what opened it goes with what came meanwhile, in one batch, when it is let go.
        if open != nil || sending { return settled() }
        let ready = queue.filter { !held.contains($0.id) }
        guard let first = ready.first else { return settled() }
        // One batch is one build: what waited from a run before an update goes as that run's.
        let events = Array(ready.filter { $0.made == first.made }.prefix(batchSize))
        let batch = Batch(k: cfg.site, v: id.isEmpty ? nil : id, u: user.isEmpty ? nil : user, sdk: "swift-" + Lapwy.version,
                          now: now(), c: client(first.made), e: events.map { var e = $0; e.made = nil; return e })
        guard let body = try? JSONEncoder().encode(batch) else { return settled() }
        sending = true
        let sent = Set(events.map(\.id))
        transport.post(body, to: cfg.endpoint) { [weak self] status in
            guard let self else { return }
            self.sending = false
            // 429 and anything from 500 up mean "not now": keep it and try again. Any other answer is final.
            guard let status, status != 429, status < 500 else {
                self.fails += 1
                if self.fails == 3 { self.warn("could not send events to \(self.cfg.endpoint) three times in a row. They wait and are tried again.") }
                let wait = min(5 * pow(2, Double(self.backoff)), 300)
                self.backoff += 1
                self.timer = self.sched.after(wait) { [weak self] in self?.timer = nil; self?.send() }
                return self.settled()
            }
            if status >= 400 { self.warn("\(self.cfg.endpoint) refused \(events.count) events with HTTP \(status), and they were dropped. Check the site key.") }
            self.queue.removeAll { sent.contains($0.id) }
            self.backoff = 0
            self.fails = 0
            self.save()
            if self.queue.contains(where: { !self.held.contains($0.id) }) {
                self.timer = self.sched.after(0.2) { [weak self] in self?.timer = nil; self?.send() }
            }
            self.settled()
        }
    }

    private func settled() {
        if sending { return }
        let waiting = idle
        idle = []
        waiting.forEach { $0() }
    }

    func client(_ made: Made?) -> Client {
        let c = cfg.collect
        return Client(
            sw: c.contains(.screenSize) ? device.width : nil,
            sh: c.contains(.screenSize) ? device.height : nil,
            l: c.contains(.language) && !device.language.isEmpty ? device.language : nil,
            rel: made?.rel ?? cfg.version,
            pf: "ios",
            osv: c.contains(.osVersion) && !device.osVersion.isEmpty ? device.osVersion : nil,
            dt: c.contains(.deviceClass) ? (device.tablet ? "tablet" : "mobile") : nil,
            bt: made.map { $0.bt.isEmpty ? nil : $0.bt } ?? cfg.buildType,
            sim: cfg.simulator,
            bn: nonEmpty(made?.bn ?? cfg.buildNumber),
            dm: c.contains(.deviceModel) && !device.model.isEmpty ? device.model : nil,
            ins: installed > 0 ? installed : nil
        )
    }

    /// A debug build says so once when its events do not get through. A release build never logs.
    private func warn(_ message: String) {
        if cfg.buildType != "dev" || warned { return }
        warned = true
        log("lapwy: " + message)
    }

    /// Everything that waits is let go and sent now.
    func flush(done: (@Sendable () -> Void)? = nil) {
        release()
        send(done: done)
    }

    // MARK: Runs

    private func engagedNow() -> Int64 { engaged + (shownAt > 0 ? now() - shownAt : 0) }

    /// Writes the run's mark (see Run).
    func mark() {
        if out { return }
        let run = Run(s: began, h: now(), f: bgAt > 0 || !active ? 0 : 1, bt: cfg.buildType, rel: cfg.version, bn: cfg.buildNumber,
                      upd: "", u: screenUrl, p: screenId, e: screenId.isEmpty ? 0 : engagedNow())
        store.set(try? JSONEncoder().encode(run), runKey)
    }

    private func scheduleBeat() {
        beat?.cancel()
        beat = sched.after(beatSeconds) { [weak self] in
            guard let self else { return }
            if self.bgAt == 0 && self.active { self.mark() }
            self.scheduleBeat()
        }
    }

    private func settle() {
        if shownAt > 0 {
            engaged += now() - shownAt
            shownAt = 0
        }
        if !screenId.isEmpty && engaged >= 1000 { add("engagement", v: Double(engaged)) }
        engaged = 0
        mark()
    }

    // MARK: Opens

    /// An open: a launch (cold) or a return to the foreground. It waits a moment
    /// for what opened it: a link (opened(url:)), or a push (opened(via:)).
    private func opening(cold: Bool, away: Int64? = nil) {
        var away = away
        if cold && lastRun > 0 { away = max(now() - lastRun, 0) }
        let recent = link.flatMap { now() - $0.at < Int64(openWait * 1000) ? $0.url : nil }
        link = nil
        let pushed = push.flatMap { now() - $0.at < Int64(openWait * 1000) ? $0 : nil }
        push = nil
        var props: Props = ["cold": .bool(cold)]
        if cold && install { props["install"] = .bool(true) }
        if let recent { props["url"] = .string(recent) }
        if let c = pushed?.campaign, !c.isEmpty { props["campaign"] = .string(c) }
        guard let e = add("open", n: pushed?.name ?? (recent != nil ? "link" : "launcher"), v: away.map(Double.init), props: props) else { return }
        held.insert(e)
        open = e
        releaseTimer?.cancel()
        releaseTimer = sched.after(openWait) { [weak self] in
            guard let self, self.open == e else { return }
            // A slow start: the first screen is not there yet. The open goes with it, or after firstScreenWait.
            if self.screenId.isEmpty {
                self.openDue = true
                self.releaseTimer = self.sched.after(firstScreenWait - openWait) { [weak self] in self?.go(e) }
                return
            }
            self.go(e)
        }
    }

    private func go(_ e: String) {
        guard open == e else { return }
        letOpenGo()
        save()
        send()
    }

    /// The open stops waiting. A launch is usually reported before its first screen has a name: it takes the first screen's.
    private func letOpenGo() {
        openDue = false
        if let o = open {
            if !screenId.isEmpty {
                let u = screenUrl, p = screenId
                edit(o) { if $0.p.isEmpty { $0.u = u; $0.p = p } }
            }
            held.remove(o)
            if let w = find(o) {
                sentOpen = (w.props?["cold"]?.bool ?? false, w.t, w.n != "launcher" && w.n != "link")
            }
        }
        open = nil
        releaseTimer?.cancel()
        releaseTimer = nil
    }

    private func release() {
        letOpenGo()
        held.removeAll()
    }

    func linked(_ raw: String) {
        let url = cleanLink(raw)
        if url.isEmpty || out { return }
        if let o = open, let w = find(o), w.n == "launcher" || w.n == "link" {
            edit(o) { $0.n = "link"; $0.props = ($0.props ?? [:]).merging(["url": .string(url)]) { $1 } }
            save()
        } else {
            link = (url, now())
        }
    }

    func opened(via: String, campaign: String) {
        let name = String(via.lowercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }.prefix(20))
        if name.isEmpty || out { return }
        let campaign = String(campaign.trimmingCharacters(in: .whitespaces).prefix(100))
        if let o = open, let w = find(o) {
            var props: Props = ["cold": .bool(w.props?["cold"]?.bool ?? false)]
            if w.props?["install"]?.bool == true { props["install"] = .bool(true) }
            if !campaign.isEmpty { props["campaign"] = .string(campaign) }
            edit(o) { $0.n = name; $0.props = props }
            save()
            return
        }
        // Not in front: the return it opens is about to come.
        if bgAt > 0 || !active {
            push = (name, campaign, now())
            return
        }
        // The open has gone: a late open names it, once, while it is recent.
        guard var last = sentOpen, !last.named, now() - last.at <= lateOpen else { return }
        last.named = true
        sentOpen = last
        var props: Props = ["cold": .bool(last.cold), "late": .bool(true)]
        if !campaign.isEmpty { props["campaign"] = .string(campaign) }
        add("open", n: name, props: props)
    }

    // MARK: Foreground and background

    func becameActive() {
        active = true
        if out { return }
        if shownAt == 0 && !screenId.isEmpty { shownAt = now() }
        if bgAt > 0 {
            let away = now() - bgAt
            bgAt = 0
            opening(cold: coldLater, away: coldLater ? nil : away)
            coldLater = false
            mark()
        }
        send()
    }

    /// The app leaves the front: for a moment (a system sheet, the app switcher) or to the background.
    func resigned(background: Bool, done: (@Sendable () -> Void)? = nil) {
        active = false
        if out { done?(); return }
        if background { bgAt = now() }
        // A navigation left in the middle has no honest time, nor has a launch that waited on a system sheet.
        navAt = 0
        timing = false
        settle()
        release()
        send(done: done)
    }

    // MARK: Screens and events

    /// navAt is the uptime (seconds) the navigation began; nowUptime the same clock now.
    func screen(_ name: String, props: Props?) {
        if out { return }
        let url = screenURL(cfg.app, name)
        if url == screenUrl && !screenId.isEmpty && props == nil { return }
        // The end of a launch: its first screen.
        var start: Int64?
        if timing, let from = device.processStart {
            let v = now() - from
            if v > 0 && v <= maxStart { start = v }
        }
        timing = false
        settle()
        let from = screenId.isEmpty ? "" : screenUrl
        let navFrom = !from.isEmpty && active ? navAt : 0
        navAt = 0
        screenUrl = url
        screenId = hex(8)
        shownAt = active ? now() : 0
        add("pageview", r: from.isEmpty ? nil : from, ti: name, props: props)
        if let start { add("start", n: "native", v: Double(start)) }
        if navFrom > 0 {
            let u = screenUrl, p = screenId
            nextFrame { [weak self] in
                guard let self, self.active, self.bgAt == 0 else { return }
                let v = (uptime() - navFrom) * 1000
                if v > 0 && v <= maxNav { self.add("nav", u: u, p: p, v: v.rounded()) }
            }
        }
        mark()
        // An open that only waited for this screen goes now.
        if openDue, let o = open { go(o) }
    }

    func navigating(at: Double) { navAt = at }

    func track(_ name: String, props: Props?) {
        if name.isEmpty { return }
        add("custom", n: String(name.prefix(100)), props: props)
    }

    func identify(_ userId: String?) {
        guard cfg.collect.contains(.users) else { return }
        let v = String((userId ?? "").trimmingCharacters(in: .whitespaces).prefix(200))
        if isEmail(v) {
            log("lapwy: identify() wants your own id for the account, not an email address. Nothing was sent.")
            user = ""
            return
        }
        user = v
    }

    func setRevenueCatId(_ raw: String?) {
        guard cfg.collect.contains(.users) else { return }
        let v = String((raw ?? "").trimmingCharacters(in: .whitespaces).prefix(200))
        if isEmail(v) {
            log("lapwy: setRevenueCatId() wants the RevenueCat app user id, not an email address. Nothing was sent.")
            return
        }
        if v.isEmpty || v == revenuecat || out { return }
        revenuecat = v
        add("link", n: "revenuecat", props: ["id": .string(v)])
    }

    // MARK: Health

    /// The main thread did nothing else for ms while the app was in front.
    func froze(_ ms: Double) {
        if out || ms < minFreeze || ms > maxFreeze || screenId.isEmpty || !active || freezes >= maxFreezes { return }
        freezes += 1
        add("freeze", v: ms.rounded(), props: ["run": .int(began)])
    }

    /// An uncaught error, once per run per name and message, with how often it came.
    /// A non-fatal one waits until the app goes to the background; a fatal one is kept at once.
    func error(name: String, message: String, fatal told: Bool) {
        let msg = String(message.prefix(300))
        if msg.isEmpty || out { return }
        let n = String((name.isEmpty ? "Error" : name).prefix(60))
        let fatal = told && cfg.buildType != "dev"
        let key = n + "\n" + msg
        if let seen = errors[key], queue.contains(where: { $0.id == seen.id }) || !fatal || seen.fatal {
            let run = began
            edit(seen.id) {
                var p = $0.props ?? [:]
                p["count"] = .int((p["count"]?.int ?? 1) + 1)
                if fatal { p["fatal"] = .bool(true); p["run"] = .int(run) }
                $0.props = p
            }
            if fatal { errors[key]?.fatal = true }
            save()
        } else if errors[key] != nil || errors.count < maxErrors {
            // A fatal error already sent as non-fatal is sent again: the run ends on it.
            // A fatal error names its run, so that a run that also ended is one crash, not two.
            var props: Props = ["msg": .string(msg), "fatal": .bool(fatal), "count": .int(1)]
            if fatal { props["run"] = .int(began) }
            guard let sent = add("error", n: n, props: props) else { return }
            errors[key] = (sent, fatal)
            if !fatal { held.insert(sent) }
        } else { return }
        if fatal {
            // The process ends now: the run's mark must say it ended in front, and the queue is already saved.
            release()
            save()
        }
    }

    // MARK: Switching off

    /// Stops or resumes tracking. Stopping throws away what waits and forgets the install id;
    /// resuming starts over as a new install.
    func setEnabled(_ on: Bool) {
        if on == !out { return }
        if !on {
            out = true
            queue = []
            release()
            forget()
            return
        }
        out = false
        load()
        began = now()
        mark()
        scheduleBeat()
    }

    private func forget() {
        timer?.cancel()
        timer = nil
        beat?.cancel()
        beat = nil
        id = ""
        installed = 0
        revenuecat = ""
        user = ""
        for key in [idKey, installedKey, queueKey, runKey] { store.set(nil, key) }
    }
}

// MARK: Helpers

func hex(_ bytes: Int) -> String {
    var g = SystemRandomNumberGenerator()
    return (0 ..< bytes).map { _ in String(format: "%02x", UInt8.random(in: 0 ... 255, using: &g)) }.joined()
}

func uuid() -> String { UUID().uuidString.lowercased() }

/// Seconds on a clock that only goes forward.
func uptime() -> Double { ProcessInfo.processInfo.systemUptime }

func nonEmpty(_ s: String?) -> String? { (s ?? "").isEmpty ? nil : s }

func isEmail(_ s: String) -> Bool { s.range(of: #"^[^@\s]+@[^@\s]+\.[^@\s]+$"#, options: .regularExpression) != nil }

/// "Home" or "/missions/addition" as the address a screen is stored under: app://<app>/<screen>.
func screenURL(_ app: String, _ name: String) -> String {
    let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
    let trimmed = name.drop { $0 == "/" }
    let path = trimmed.split(separator: "/", omittingEmptySubsequences: false)
        .map { String($0).addingPercentEncoding(withAllowedCharacters: allowed) ?? "" }
        .joined(separator: "/")
    return "app://\(app)/\(path)"
}

/// Ids in a path are replaced: numbers, UUIDs, long tokens.
func tidy(_ path: String) -> String {
    let parts = path.split(separator: "/", omittingEmptySubsequences: false).map { seg -> String in
        let s = String(seg)
        let id = s.range(of: #"^\d+$"#, options: .regularExpression) != nil
            || s.range(of: #"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-"#, options: .regularExpression) != nil
            || s.range(of: #"^[0-9a-fA-F]{16,}$"#, options: .regularExpression) != nil
            || (s.count >= 20 && s.contains { $0.isNumber })
        return id ? ":id" : s
    }
    return String(parts.joined(separator: "/").prefix(120))
}

private let campaignTag = #"^(utm_[a-z_]+|gclid|gbraid|wbraid|msclkid|ttclid|twclid|li_fat_id|dclid|fbclid)$"#

/// A link that opened the app, as it is sent: no fragment, ids in the path replaced,
/// and of the query only campaign tags and click ids, so that a token or an email stays on the phone.
func cleanLink(_ raw: String) -> String {
    guard let c = URLComponents(string: raw.trimmingCharacters(in: .whitespaces)), let scheme = c.scheme?.lowercased() else { return "" }
    let keep = (c.percentEncodedQuery ?? "").split(separator: "&").filter { kv in
        let k = (kv.split(separator: "=", maxSplits: 1).first.map(String.init) ?? "").removingPercentEncoding?.lowercased() ?? ""
        return k.range(of: campaignTag, options: .regularExpression) != nil
    }
    var s = scheme + ":"
    if let host = c.host { s += "//" + host.lowercased() + (c.port.map { ":\($0)" } ?? "") }
    s += tidy(c.percentEncodedPath)
    if !keep.isEmpty { s += "?" + keep.joined(separator: "&") }
    return String(s.prefix(500))
}
