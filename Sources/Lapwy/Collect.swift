import Foundation

/// What lapwy may say about the device and the person, beyond what the app
/// itself does (its screens, events, launches and health).
///
/// Always sent: the platform (iOS), the app's version, build number and
/// build type (debug or release), whether it runs on a simulator, when the
/// install id was made, and the random install id itself. Nothing in this
/// set is needed for screens, events, launches, start times, freezes or
/// crashes to be counted.
///
///     Lapwy.start(site: "lw_…", collect: .minimal)              // a kids' app
///     Lapwy.start(site: "lw_…", collect: [.deviceClass])        // phone or tablet, nothing else
///     Lapwy.start(site: "lw_…")                                  // .standard: everything below
public struct Collect: OptionSet, Sendable, Hashable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    /// The model, as Apple names its hardware: "iPhone17,1", "iPad14,3".
    public static let deviceModel = Collect(rawValue: 1 << 0)
    /// The iOS version, major and minor: "18.2".
    public static let osVersion = Collect(rawValue: 1 << 1)
    /// Phone or tablet, and nothing more about the device.
    public static let deviceClass = Collect(rawValue: 1 << 2)
    /// The screen's size in points.
    public static let screenSize = Collect(rawValue: 1 << 3)
    /// The first language in the person's settings: "en-US".
    public static let language = Collect(rawValue: 1 << 4)
    /// identify() and setRevenueCatId(): who is signed in, and the id a
    /// payment provider knows them by. Off, both do nothing.
    public static let users = Collect(rawValue: 1 << 5)

    /// Everything above.
    public static let standard: Collect = [.deviceModel, .osVersion, .deviceClass, .screenSize, .language, .users]
    /// Nothing above: no device information and no user ids. Meant for apps
    /// in the App Store's Kids Category (App Review Guidelines 1.3 and 5.1.4).
    public static let minimal: Collect = []
}
