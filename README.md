# SignalQuest iOS

Native SwiftUI app (180+ Swift files) for a social-first SignalQuest companion: end-to-end-encrypted (E2EE) messaging, LiveKit real-time calls, a WidgetKit extension with Live Activities, and MapKit-based coverage/antenna maps. It does not attempt to reproduce Android radio scanning because iOS public APIs do not expose fine cellular metrics such as RSRP, RSRQ, SINR, PCI, Cell ID, eNB/gNB, bands, ARFCN/EARFCN, timing advance, handovers, or neighbor cells.

## Scope

- Social feed, community map, speedtest, photos, messages, leaderboards, and profile.
- iOS speedtests contribute throughput, latency, consented location, network path type, coarse cellular technology, and device model.
- Radio summaries displayed on iOS are server/community data only.
- iOS submissions can report `WIFI`, `2G`, `3G`, `4G`, `5G NSA`, or `5G SA`; modem-level radio metrics stay unavailable.

## Generate The Project

This repo uses XcodeGen to keep project generation deterministic.

```bash
cd /Users/alexandregermain/Site/iOS
brew install xcodegen
xcodegen generate
open SignalQuest.xcodeproj
```

If XcodeGen is already installed:

```bash
cd /Users/alexandregermain/Site/iOS
xcodegen generate
```

Current Codex environment note: `xcodegen` was not installed, so `SignalQuest.xcodeproj` was not generated in this pass. All Swift sources, configs, tests, and `project.yml` are present.

## Build And Test

The local machine has Xcode 26.4.1, Swift 6.3.1, and the iOS 26.4 SDK available. Device types for iPhone 17 Pro and iPhone 16 Pro are available, but `xcrun simctl list runtimes` returned no installed iOS Simulator runtime in this Codex environment. If the runtime is installed later, use:

```bash
cd /Users/alexandregermain/Site/iOS
xcodegen generate
xcodebuild test -scheme SignalQuest -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
```

Fallback:

```bash
xcodebuild test -scheme SignalQuest -destination 'platform=iOS Simulator,name=iPhone 16 Pro'
```

If the device type exists but no simulator is created, create one after installing an iOS runtime:

```bash
xcrun simctl create "iPhone 17 Pro" com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro com.apple.CoreSimulator.SimRuntime.iOS-26-4
```

Physical device note: `xctrace` showed `iPhone d’Alexandre (26.5)` as offline in this pass. A real build/run still requires the device to be online, trusted in Xcode, and signed with a valid Apple team/provisioning profile. Do not treat physical-device visibility as a completed test.

Syntax validation performed without a generated Xcode project:

```bash
APP_SDK=$(xcrun --sdk iphonesimulator --show-sdk-path)
APP_TARGET=arm64-apple-ios18.0-simulator
xcrun swiftc -target "$APP_TARGET" -sdk "$APP_SDK" -swift-version 6 -typecheck $(find SignalQuestApp -name '*.swift' | sort)
```

## Configuration

Default config values (`Config/Debug.xcconfig` and `Config/Release.xcconfig`):

- `SQ_APP_BASE_URL=https://signalquest.fr`
- `SQ_API_BASE_URL=https://api.signalquest.fr`

`Config/Staging.xcconfig` ships safe-by-default placeholder hosts (`app.staging.invalid` / `api.staging.invalid`), not production. A Beta build must override them with the real isolated staging services. The `ci_scripts/validate_build_environment.sh` build phase fails the build when a staging configuration still uses the placeholder hosts or points to a production host.

## iOS Radio Limits

iOS public APIs do not expose modem-level radio metrics. This app uses:

- `Network.framework` for Wi-Fi/cellular/other path type, expensive, constrained.
- `CoreTelephony` for coarse cellular radio access technology: 2G, 3G, 4G, 5G NSA, or 5G SA.
- `CoreLocation` only after consent.
- `PhotosUI` for user-selected image contribution.
- Keychain for auth/session and E2EE local material.

Never hardcode secrets, private API keys, certificates, provisioning profiles, or private Apple entitlements in this repo.

## Distribution privée

- Installing via profile requires a signed binary with a suitable provisioning profile.
- For a small pilot, use Ad Hoc distribution with registered UDIDs.
- For testing without a public App Store release, TestFlight is appropriate.
- Apple Developer Enterprise Program is only for eligible organizations and internal use, not broad community distribution.
- MDM or Apple Configurator can be used depending on the deployment context.

Archive/export example after project generation and signing setup:

```bash
xcodebuild archive \
  -scheme SignalQuest \
  -configuration Release \
  -archivePath build/SignalQuest.xcarchive

xcodebuild -exportArchive \
  -archivePath build/SignalQuest.xcarchive \
  -exportPath build/ad-hoc \
  -exportOptionsPlist ExportOptions-AdHoc.plist.example
```

## Backend Notes

- Auth uses `auth_token` from `Set-Cookie` and sends it back as `Cookie: auth_token=...`.
- `/api/social/radio-snapshot` is called by `LivePresenceService.publishRadio` only while live radio sharing is active (technology/operator only — iOS does not expose raw RSRP); it is not called otherwise.
- Photo upload uses authenticated multipart `POST /api/photos`; external v1 photo write routes require API key scopes and are not used by the app.
- E2EE messages never fall back to cleartext in encrypted conversations.
