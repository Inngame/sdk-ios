# Inngame for iOS

In-app support chat for regular iOS apps (SwiftUI or UIKit). Players write in their language; your team answers in theirs from the Inngame inbox, Telegram or Discord.

```swift
// Package: https://github.com/inngame/sdk-ios (from 0.1.0) — iOS 16+
import Inngame

@main struct MyApp: App {
    init() { Inngame.configure(appKey: "app_…") }
    var body: some Scene { WindowGroup { ContentView() } }
}

// After login (pass `token`, a JWT signed by your server with the app identity secret, to mark the user verified)
Inngame.identify(userId: user.id, name: user.name, email: user.email)
Inngame.setContext("plan", "pro")

// SwiftUI
.sheet(isPresented: $showHelp) { InngameChatView() }
// Unread badge
@ObservedObject var support = Inngame.shared   // support.unreadCount
// UIKit
Inngame.present(from: self)

// Push (APNs)
func application(_ app: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken token: Data) { Inngame.setPushToken(token) }
// In your notification handler: if Inngame.handleNotification(userInfo) { /* open the chat; Inngame.shared.wantsToOpen is true */ }
```

Also: `Inngame.track("checkout_failed")` (automations can reply or open the chat), `Inngame.logout()`, `Inngame.shared.deleteMyData()`. Text messages written offline wait in `Inngame.shared.pending` and are sent when the network is back or at the next launch.

Tests: `swift test`; live test against a server with `INNGAME_TEST_URL=… INNGAME_TEST_APP_KEY=app_… swift test`.
