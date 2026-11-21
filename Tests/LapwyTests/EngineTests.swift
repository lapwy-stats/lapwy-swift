import XCTest
@testable import Lapwy

// The engine with a hand-turned clock, a store in memory, a network that
// answers what the test says, and timers that fire when the clock passes them.

final class Memory: KeyValueStore, @unchecked Sendable {
    var values: [String: Any] = [:]
    func data(_ key: String) -> Data? { values[key] as? Data }
    func string(_ key: String) -> String? { values[key] as? String }
    func set(_ value: Any?, _ key: String) { values[key] = value }
}

final class FakeNet: Transport, @unchecked Sendable {
    var batches: [[String: Any]] = []
    var status: Int? = 202
    func post(_ body: Data, to url: URL, done: @escaping @Sendable (Int?) -> Void) {
        batches.append(try! JSONSerialization.jsonObject(with: body) as! [String: Any])
        done(status)
    }
    var events: [[String: Any]] { batches.flatMap { $0["e"] as! [[String: Any]] } }
    func kinds() -> [String] { events.map { $0["k"] as! String } }
}

final class Clock: Scheduler, @unchecked Sendable {
    var ms: Int64 = 1_800_000_000_000
    final class Job: Cancellable {
        var at: Int64
        var work: (() -> Void)?
        init(_ at: Int64, _ w: @escaping () -> Void) { self.at = at; work = w }
        func cancel() { work = nil }
    }
    var jobs: [Job] = []
    func after(_ seconds: Double, _ work: @escaping @Sendable () -> Void) -> Cancellable {
        let j = Job(ms + Int64(seconds * 1000), work)
        jobs.append(j)
        return j
    }
    /// Moves time on, running every timer it passes, in order.
    func pass(_ seconds: Double) {
        let end = ms + Int64(seconds * 1000)
        while let j = jobs.filter({ $0.work != nil && $0.at <= end }).min(by: { $0.at < $1.at }) {
            ms = max(ms, j.at)
            let w = j.work
            j.work = nil
            w?()
        }
        ms = end
        jobs.removeAll { $0.work == nil }
    }
}

final class EngineTests: XCTestCase {
    var store = Memory()
    var net = FakeNet()
    var clock = Clock()

    func engine(collect: Collect = .standard, buildType: String = "release", version: String = "1.0", build: String = "7") -> Engine {
        let cfg = Config(site: "lw_test", app: "kaira", endpoint: URL(string: "https://i.example.com/e")!, collect: collect,
                         version: version, buildNumber: build, buildType: buildType, simulator: false, errors: true)
        var d = DeviceInfo()
        d.model = "iPad14,3"
        d.osVersion = "18.2"
        d.tablet = true
        d.width = 820
        d.height = 1180
        d.language = "nl-NL"
        d.processStart = clock.ms - 900
        let c = clock
        return Engine(cfg: cfg, device: d, store: store, transport: net, sched: clock, now: { c.ms }, nextFrame: { $0() })
    }

    func testLaunchSendsOpenWithFirstScreenAndStartTime() {
        let e = engine()
        e.boot(active: true, enabled: true)
        e.screen("Home", props: nil)
        clock.pass(4)
        XCTAssertEqual(net.kinds(), ["open", "pageview", "start"])
        let open = net.events[0]
        XCTAssertEqual(open["n"] as? String, "launcher")
        XCTAssertEqual(open["u"] as? String, "app://kaira/Home")
        let props = open["props"] as! [String: Any]
        XCTAssertEqual(props["cold"] as? Bool, true)
        XCTAssertEqual(props["install"] as? Bool, true)
        XCTAssertEqual(net.events[2]["n"] as? String, "native")
        XCTAssertEqual(net.events[2]["v"] as? Double, 900)
        let batch = net.batches[0]
        XCTAssertEqual(batch["k"] as? String, "lw_test")
        XCTAssertEqual(batch["sdk"] as? String, "swift-" + Lapwy.version)
        XCTAssertEqual((batch["v"] as? String)?.count, 32)
        XCTAssertNil(net.events[0]["_b"])
    }

    func testStandardSendsTheDevice() {
        let e = engine(collect: .standard)
        e.boot(active: true, enabled: true)
        e.screen("Home", props: nil)
        clock.pass(4)
        let c = net.batches[0]["c"] as! [String: Any]
        XCTAssertEqual(c["pf"] as? String, "ios")
        XCTAssertEqual(c["dm"] as? String, "iPad14,3")
        XCTAssertEqual(c["osv"] as? String, "18.2")
        XCTAssertEqual(c["dt"] as? String, "tablet")
        XCTAssertEqual(c["sw"] as? Int, 820)
        XCTAssertEqual(c["l"] as? String, "nl-NL")
        XCTAssertEqual(c["rel"] as? String, "1.0")
        XCTAssertEqual(c["bn"] as? String, "7")
    }

    func testMinimalSendsNothingAboutTheDevice() {
        let e = engine(collect: .minimal)
        e.boot(active: true, enabled: true)
        e.identify("user-1")
        e.setRevenueCatId("rc-1")
        e.screen("Home", props: nil)
        clock.pass(4)
        let batch = net.batches[0]
        let c = batch["c"] as! [String: Any]
        XCTAssertEqual(Set(c.keys), ["rel", "pf", "bt", "sim", "bn", "ins"])
        XCTAssertNil(batch["u"])
        XCTAssertFalse(net.kinds().contains("link"))
    }

    func testDeviceClassAlone() {
        let e = engine(collect: [.deviceClass])
        e.boot(active: true, enabled: true)
        e.screen("Home", props: nil)
        clock.pass(4)
        let c = net.batches[0]["c"] as! [String: Any]
        XCTAssertEqual(c["dt"] as? String, "tablet")
        XCTAssertNil(c["dm"])
        XCTAssertNil(c["osv"])
        XCTAssertNil(c["sw"])
    }

    func testDisabledSendsNothingAndForgets() {
        let e = engine()
        e.boot(active: true, enabled: true)
        e.screen("Home", props: nil)
        XCTAssertNotNil(store.string(idKey))
        e.setEnabled(false)
        e.track("mission_done", props: nil)
        clock.pass(30)
        XCTAssertTrue(net.batches.isEmpty)
        XCTAssertNil(store.string(idKey))
        XCTAssertNil(store.data(queueKey))
        XCTAssertNil(store.data(runKey))
    }

    func testDisabledAtLaunchTouchesNothing() {
        let e = engine()
        e.boot(active: true, enabled: false)
        e.screen("Home", props: nil)
        e.track("x", props: nil)
        clock.pass(30)
        XCTAssertTrue(net.batches.isEmpty)
        XCTAssertTrue(store.values.isEmpty)
    }

    func testEnablingAgainIsANewInstall() {
        let e = engine()
        e.boot(active: true, enabled: true)
        e.screen("Home", props: nil)
        clock.pass(4)
        let first = net.batches[0]["v"] as! String
        e.setEnabled(false)
        e.setEnabled(true)
        e.track("again", props: nil)
        clock.pass(4)
        let last = net.batches.last!["v"] as! String
        XCTAssertNotEqual(first, last)
    }

    func testEngagementWhenGoingToTheBackground() {
        let e = engine()
        e.boot(active: true, enabled: true)
        e.screen("Home", props: nil)
        clock.pass(5)
        e.resigned(background: true)
        let eng = net.events.first { $0["k"] as? String == "engagement" }
        XCTAssertEqual(eng?["v"] as? Double, 5000)
    }

    func testReturnIsAWarmOpenWithTimeAway() {
        let e = engine()
        e.boot(active: true, enabled: true)
        e.screen("Home", props: nil)
        clock.pass(4)
        e.resigned(background: true)
        clock.pass(60)
        e.becameActive()
        clock.pass(4)
        let opens = net.events.filter { $0["k"] as? String == "open" }
        XCTAssertEqual(opens.count, 2)
        XCTAssertEqual((opens[1]["props"] as! [String: Any])["cold"] as? Bool, false)
        XCTAssertEqual(opens[1]["v"] as? Double, 60000)
    }

    func testInactiveIsNotAReturn() {
        let e = engine()
        e.boot(active: true, enabled: true)
        e.screen("Home", props: nil)
        clock.pass(4)
        e.resigned(background: false)
        e.becameActive()
        clock.pass(4)
        XCTAssertEqual(net.events.filter { $0["k"] as? String == "open" }.count, 1)
    }

    func testARunThatEndedInFrontIsReportedNextLaunch() {
        let e = engine()
        e.boot(active: true, enabled: true)
        e.screen("Mission", props: nil)
        clock.pass(20) // a beat writes the mark
        // The process dies here: no background.
        net.batches = []
        let next = engine()
        next.boot(active: true, enabled: true)
        next.screen("Home", props: nil)
        clock.pass(4)
        XCTAssertTrue(net.kinds().contains("ended"))
        let ended = net.events.first { $0["k"] as? String == "ended" }!
        XCTAssertEqual(ended["u"] as? String, "app://kaira/Mission")
        let open = net.events.first { $0["k"] as? String == "open" }!
        XCTAssertNil((open["props"] as! [String: Any])["install"])
    }

    func testANewVersionIsAnUpdate() {
        let e = engine(version: "1.0")
        e.boot(active: true, enabled: true)
        e.screen("Home", props: nil)
        clock.pass(4)
        e.resigned(background: true)
        net.batches = []
        let next = engine(version: "1.1")
        next.boot(active: true, enabled: true)
        next.screen("Home", props: nil)
        clock.pass(4)
        let update = net.events.first { $0["k"] as? String == "update" }
        XCTAssertEqual(update?["n"] as? String, "version")
        XCTAssertEqual((update?["props"] as? [String: Any])?["from"] as? String, "1.0")
    }

    func testOfflineEventsWaitAndBackOff() {
        net.status = nil
        let e = engine()
        e.boot(active: true, enabled: true)
        e.screen("Home", props: nil)
        clock.pass(4)
        XCTAssertEqual(net.batches.count, 1)
        XCTAssertEqual(e.queue.count, 3)
        net.status = 202
        clock.pass(6)
        XCTAssertTrue(e.queue.isEmpty)
        XCTAssertEqual(net.batches.count, 2)
    }

    func testRefusedBatchIsDropped() {
        net.status = 403
        let e = engine()
        e.boot(active: true, enabled: true)
        e.screen("Home", props: nil)
        clock.pass(4)
        XCTAssertTrue(e.queue.isEmpty)
    }

    func testLinkNamesTheOpenAndKeepsOnlyCampaignTags() {
        let e = engine()
        e.boot(active: true, enabled: true)
        e.linked("kaira://mission/12345?utm_campaign=spring&token=secret#x")
        e.screen("Home", props: nil)
        clock.pass(4)
        let open = net.events[0]
        XCTAssertEqual(open["n"] as? String, "link")
        XCTAssertEqual((open["props"] as! [String: Any])["url"] as? String, "kaira://mission/:id?utm_campaign=spring")
    }

    func testPushNamesTheOpen() {
        let e = engine()
        e.boot(active: true, enabled: true)
        e.opened(via: "Push", campaign: "daily")
        e.screen("Home", props: nil)
        clock.pass(4)
        XCTAssertEqual(net.events[0]["n"] as? String, "push")
        XCTAssertEqual((net.events[0]["props"] as! [String: Any])["campaign"] as? String, "daily")
    }

    func testFreezesOnlyOnAScreenAndAtMostTen() {
        let e = engine()
        e.boot(active: true, enabled: true)
        e.froze(900) // before the first screen: the start, not a freeze
        e.screen("Home", props: nil)
        e.froze(500) // too short
        for _ in 0 ..< 12 { e.froze(1200) }
        clock.pass(4)
        XCTAssertEqual(net.kinds().filter { $0 == "freeze" }.count, 10)
    }

    func testFatalErrorIsKeptForTheNextLaunch() {
        let e = engine()
        e.boot(active: true, enabled: true)
        e.screen("Home", props: nil)
        e.error(name: "NSRangeException", message: "index 3 beyond bounds", fatal: true)
        let queued = try! JSONDecoder().decode([Wire].self, from: store.data(queueKey)!)
        let err = queued.first { $0.k == "error" }
        XCTAssertEqual(err?.props?["fatal"], .bool(true))
        XCTAssertEqual(err?.props?["run"], .int(e.began))
    }

    func testRepeatedErrorIsCounted() {
        let e = engine()
        e.boot(active: true, enabled: true)
        e.screen("Home", props: nil)
        e.error(name: "E", message: "m", fatal: false)
        e.error(name: "E", message: "m", fatal: false)
        e.resigned(background: true)
        let errs = net.events.filter { $0["k"] as? String == "error" }
        XCTAssertEqual(errs.count, 1)
        XCTAssertEqual((errs[0]["props"] as! [String: Any])["count"] as? Int, 2)
    }

    func testCustomEventProps() {
        let e = engine()
        e.boot(active: true, enabled: true)
        e.screen("Home", props: nil)
        e.track("mission_done", props: ["skill": "addition", "stars": 3, "perfect": true, "score": 0.5])
        clock.pass(4)
        let ev = net.events.first { $0["k"] as? String == "custom" }!
        let p = ev["props"] as! [String: Any]
        XCTAssertEqual(ev["n"] as? String, "mission_done")
        XCTAssertEqual(p["skill"] as? String, "addition")
        XCTAssertEqual(p["stars"] as? Int, 3)
        XCTAssertEqual(p["perfect"] as? Bool, true)
        XCTAssertEqual(p["score"] as? Double, 0.5)
    }

    func testScreenURLs() {
        XCTAssertEqual(screenURL("kaira", "Home"), "app://kaira/Home")
        XCTAssertEqual(screenURL("kaira", "/missions/add two"), "app://kaira/missions/add%20two")
    }

    func testVersionIsSemver() {
        XCTAssertTrue(Lapwy.version.range(of: #"^\d+\.\d+\.\d+$"#, options: .regularExpression) != nil)
    }
}
