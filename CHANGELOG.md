# Changelog

## [0.2.3] - 2026-11-02

### Changed
- Review cards open the App Store "Write a Review" page (`https://apps.apple.com/app/id<ID>?action=write-review`, id from the card or from the dashboard's Reviews settings, now in `InngameRemoteConfig.reviews`) instead of calling the system rating prompt, which Apple advises against showing in response to a button.

### Added
- Card handlers, like the Unity and web SDKs: `Inngame.onOffer`, `Inngame.onScreen` (the chat closes first), `Inngame.onItemGranted` (item cards show "Claim", the item is granted once the server confirms the claim, once per card even across devices; `Inngame.shared.claimItem(_:)`), `Inngame.onRestorePurchases` (default: StoreKit `AppStore.sync()`). Without a handler the tap is reported as failed and item cards stay disabled. Before, these cards did nothing.
- `InngameCard.customLabel`, `screen`, `value`, `offerId`, `transactionId`, `lastAction`, `item(messageId:)`; `InngameItem`; `InngameStoreIds`.

### Fixed
- A refused photo showed a hard-coded English "This image can't be sent." instead of the server's message in the user's language.
- Refund cards report `dismissed` when the user cancels Apple's sheet (was `failed`), and open Apple's Report a Problem page when the card has no transaction id.

## [0.2.2] - 2026-11-02

### Changed
- Default server address is now `https://app.inngame.app` (`Inngame.configure(appKey:baseURL:)`). The previous address keeps working, so 0.2.1 and earlier need no change.

### Fixed
- Cards the server sends on its own (satisfaction rating when a conversation is closed, then the App Store review) are shown as cards; they were rendered as an empty caption.
- Cards sent with the server's default English label ("Rate the game", "Request a refund") now show the SDK's translated text in the user's language. Labels written by the team are shown as they are. The server flags these cards with `defaultLabel: true`; `InngameCard.usesDefaultLabel` exposes it.

## [0.2.1] - 2026-11-01

### Fixed
- Suspended workspace (`403 org_suspended`): a clear "Support is unavailable right now" state in the user's language, unsent messages kept and sent once support is back; `Inngame.isUnavailable`.

## [0.2.0] - 2026-11-01

### Added
- Logo in the chat header, dashboard colors, build number and time zone in the context.

## [0.1.0] - 2026-10-31

- First release.
