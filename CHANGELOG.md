# Changelog

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
