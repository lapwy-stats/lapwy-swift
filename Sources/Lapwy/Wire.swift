import Foundation

/// A property's value: text, a whole number, a number or a yes/no.
///
///     Lapwy.track("mission_done", props: ["skill": "addition", "stars": 3, "perfect": true])
public enum Prop: Codable, Sendable, Equatable,
    ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByFloatLiteral, ExpressibleByBooleanLiteral
{
    case string(String)
    case int(Int64)
    case double(Double)
    case bool(Bool)

    public init(stringLiteral value: String) { self = .string(value) }
    public init(integerLiteral value: Int64) { self = .int(value) }
    public init(floatLiteral value: Double) { self = .double(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let i = try? c.decode(Int64.self) { self = .int(i) }
        else if let d = try? c.decode(Double.self) { self = .double(d) }
        else { self = .string(try c.decode(String.self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let s): try c.encode(s)
        case .int(let i): try c.encode(i)
        case .double(let d): try c.encode(d)
        case .bool(let b): try c.encode(b)
        }
    }

    var bool: Bool? { if case .bool(let b) = self { return b }; return nil }
    var int: Int64? { if case .int(let i) = self { return i }; return nil }
}

public typealias Props = [String: Prop]

/// The build an event was made in, when it is not the one running now: a run
/// before an update left it in the queue. Never sent as such: a batch carries it.
struct Made: Codable, Equatable, Sendable {
    var bt: String
    var rel: String
    var bn: String
    var upd: String
}

/// One event as it goes over the wire (and as it waits in the queue).
struct Wire: Codable, Equatable, Sendable {
    var id: String
    var t: Int64
    var k: String
    var u: String
    var p: String
    var n: String?
    var r: String?
    var ti: String?
    var v: Double?
    var props: Props?
    var made: Made?

    enum CodingKeys: String, CodingKey {
        case id, t, k, u, p, n, r, ti, v, props
        case made = "_b"
    }
}

/// What the app and, as far as Collect allows, the device are. Empty parts are left out.
struct Client: Codable, Equatable {
    var sw: Int?
    var sh: Int?
    var l: String?
    var rel: String
    var pf: String
    var osv: String?
    var dt: String?
    var bt: String?
    var sim: Bool?
    var bn: String?
    var dm: String?
    var ins: Int64?
}

struct Batch: Codable {
    var k: String
    var v: String?
    var u: String?
    var sdk: String
    var now: Int64
    var c: Client
    var e: [Wire]
}

/// The mark a run leaves in storage, written at launch, every 15 seconds in
/// front, on every screen and when the app goes to the background. f is 1
/// while the app is in front: still 1 at the next launch means the run ended
/// there (a crash, the system, a force-quit). s is when the run began, h when
/// the mark was last written, both ms since 1970; u and p the screen then,
/// e the time on it not yet sent as engagement (ms).
struct Run: Codable, Equatable {
    var s: Int64
    var h: Int64
    var f: Int
    var bt: String
    var rel: String
    var bn: String
    var upd: String
    var u: String
    var p: String
    var e: Int64
}
