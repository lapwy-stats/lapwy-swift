# lapwy for iOS

Screens, events, launches, start times, freezes and crashes for iOS apps, sent to [lapwy](https://lapwy.com). You choose what is said about the device.

## Install

In Xcode: **File → Add Package Dependencies**, then this repo's address:

```
https://github.com/lapwy-stats/lapwy-swift
```

Pick **Up to Next Major Version**. iOS 15 or later.

## Use

```swift
import Lapwy
import SwiftUI

@main
struct KairaApp: App {
    init() {
        Lapwy.start(site: "lw_…", app: "kaira-math", collect: .minimal)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .onOpenURL { Lapwy.opened(url: $0) }
        }
    }
}

// On every screen:
.onAppear { Lapwy.screen("Home") }

// Something the person did:
Lapwy.track("mission_done", props: ["skill": "addition", "stars": 3])
```

The site key is on the app's Install screen in lapwy.

## What is sent

Always:

| | |
|---|---|
| Screens and how long they were in front | `screen()` |
| Events and their properties | `track()` |
| Launches and returns to the foreground, and what opened them (a link, a push) | on its own |
| How long a launch took to its first screen | on its own |
| The main thread frozen for 0.7 s or more | on its own |
| A run that ended while the app was in front (a crash, a kill) | on its own |
| Uncaught Objective-C exceptions | on its own; `reportErrors: false` switches it off |
| A new version or build | on its own |
| The app's version, build number, debug or release, simulator or not | on its own |
| A random id for the install, and when it was made | on its own |

Only what `collect` allows:

| `Collect` | What | `.standard` | `.minimal` |
|---|---|:-:|:-:|
| `.deviceModel` | `iPhone17,1` | ✓ | |
| `.osVersion` | `18.2` | ✓ | |
| `.deviceClass` | phone or tablet | ✓ | |
| `.screenSize` | points | ✓ | |
| `.language` | `en-US` | ✓ | |
| `.users` | `identify()`, `setRevenueCatId()` | ✓ | |

Mix them: `collect: [.deviceClass, .osVersion]`.

Never sent: the advertising id (IDFA), the vendor id (IDFV), location, contacts, names or anything typed. The User-Agent is `lapwy-swift/<version>`, not the system's, which names the app and the Darwin version. lapwy does not ask for App Tracking Transparency, because it does not track across apps.

## Kids' apps

Apps in the App Store's Kids Category may not send device information to third parties (App Review Guidelines 1.3 and 5.1.4). Use `.minimal`.

## Switching it off

```swift
Toggle("Usage statistics", isOn: Binding(get: { Lapwy.isEnabled }, set: { Lapwy.isEnabled = $0 }))
```

`isEnabled` is remembered across launches. Off: nothing is sent, what waits is thrown away, and the install id is forgotten. On again: a new install. To keep tracking off until someone switches it on:

```swift
Lapwy.start(site: "lw_…", collect: .minimal, enabledByDefault: false)
```

## Privacy manifest

The package ships its own `PrivacyInfo.xcprivacy`: product interaction, crash data and performance data, none of it linked to the person or used for tracking; UserDefaults (CA92.1) and the system uptime (35F9.1, to time things). Xcode adds it to the app's privacy report. Still set the app's App Privacy answers in App Store Connect to match. With `identify()` the data is linked to the person: say so there.

## Reference

| | |
|---|---|
| `Lapwy.start(site:app:collect:enabledByDefault:reportErrors:endpoint:)` | once, at launch, on the main thread |
| `Lapwy.screen(_:props:)` | a screen came up |
| `Lapwy.track(_:props:)` | something the person did |
| `Lapwy.navigating()` | just before a navigation: the next screen's opening time is measured from here |
| `Lapwy.opened(url:)` | the link that opened the app |
| `Lapwy.opened(via:campaign:)` | a push that opened the app |
| `Lapwy.identify(_:)` | your own account id (needs `.users`) |
| `Lapwy.setRevenueCatId(_:)` | the RevenueCat app user id (needs `.users`) |
| `Lapwy.isEnabled` | on or off, remembered |
| `Lapwy.flush()` | send what waits, now |

Calls made before `start()` wait for it. Events wait in a queue (500 at most) while offline, and go when the network is back.

## Licence

MIT
