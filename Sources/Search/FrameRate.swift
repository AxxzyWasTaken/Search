import IOKit.ps
import WebKit

// How often a page may draw on a screen that can go faster than 60 times a
// second, like a MacBook Pro's.
//
// WebKit holds a page's animations, and the scrolling it draws itself, to
// about 60 frames a second even on a 120 Hz screen. That's Safari's default
// too, and it is the cheaper one: a page that animates at 120 draws twice as
// often, and in a short test on a 120 Hz MacBook Pro, a page with one CSS
// animation took about half again as much energy (Activity Monitor's 10 → 15).
// A page that is standing still costs nothing either way. So 60 unless
// asked; 120 always, or only while the Mac is plugged in.

enum FrameRate: String, CaseIterable, Identifiable {
    case standard, smooth, plugged

    var id: String { rawValue }

    var title: String {
        switch self {
        case .standard: return "60"
        case .smooth: return "120"
        case .plugged: return "120 plugged in"
        }
    }

    /// Settings › General › Frame rate.
    @MainActor static var chosen = FrameRate.standard {
        didSet { if chosen != oldValue { update() } }
    }

    /// Whether pages may go past 60 right now.
    @MainActor private static var fast = false

    /// Every page there is, told again whenever the answer changes — the
    /// setting, or the power cable.
    @MainActor static func update() {
        let now = chosen == .smooth || (chosen == .plugged && pluggedIn)
        if chosen == .plugged { watchPower() }
        guard now != fast else { return }
        fast = now
        // WebKit reads this when a page is made, so a new tab or a reload
        // gets the new rate at once. A page that is already open may keep
        // the old one until then (going up it catches up on the next switch
        // to its tab, going down only on a reload). Reloading every tab to
        // force it would lose what's typed in them, so it is left.
        for page in Web.pages.allObjects { apply(to: page.configuration.preferences) }
    }

    /// For a page's preferences before its view exists, and after.
    @MainActor static func apply(to preferences: WKPreferences) {
        feature("PreferPageRenderingUpdatesNear60FPSEnabled", on: !fast, in: preferences)
    }

    // MARK: - the cable

    private static var pluggedIn: Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let kind = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue()
        else { return true }
        return (kind as String) == kIOPMACPowerKey
    }

    @MainActor private static var watching = false

    /// macOS says when the power source changes; nothing is asked until then.
    /// Only started once someone picks "120 plugged in", and left running
    /// after: it costs nothing between changes.
    @MainActor private static func watchPower() {
        guard !watching else { return }
        watching = true
        let changed: IOPowerSourceCallbackType = { _ in
            MainActor.assumeIsolated { FrameRate.update() }
        }
        guard let source = IOPSNotificationCreateRunLoopSource(changed, nil)?.takeRetainedValue() else { return }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
    }

    // MARK: - WebKit's switch

    /// The switch is one of WebKit's feature flags, the list Safari shows
    /// under Develop › Feature Flags. It isn't in the public framework, so
    /// each step is asked first, and a WebKit without it is left alone.
    private static func feature(_ key: String, on: Bool, in preferences: WKPreferences) {
        let list = NSSelectorFromString("_features")
        let set = NSSelectorFromString("_setEnabled:forFeature:")
        let type: AnyObject = WKPreferences.self
        guard type.responds(to: list), preferences.responds(to: set),
              let all = type.perform(list)?.takeUnretainedValue() as? [NSObject],
              let flag = all.first(where: { $0.value(forKey: "key") as? String == key })
        else { return }
        typealias Setter = @convention(c) (AnyObject, Selector, Bool, AnyObject) -> Void
        unsafeBitCast(preferences.method(for: set), to: Setter.self)(preferences, set, on, flag)
    }
}
