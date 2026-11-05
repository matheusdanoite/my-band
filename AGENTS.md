# AGENTS.md — My Band

Guidelines for AI agents (Claude, Codex, etc.) working on this project.

---

## Project Context

**My Band** is a universal iOS/macOS SwiftUI app that:
1. Connects to the Mi Band 10 via CoreBluetooth using the XiaomiSppPacketV2 protocol with HMAC-SHA256 authentication and an AuthKey
2. Syncs sleep, heart rate and activity data to Apple Health (HealthKit)
3. Exposes state and actions via App Intents for integration with Shortcuts and Siri
4. (Future) Shows a custom mini app on the band with actionable buttons

Platforms: iOS 17+ and macOS 14+. Distribution: personal sideload.

---

## What to Read Before Any Change

1. `CLAUDE.md` — full architecture, BLE protocol, code conventions
2. The file you are going to modify — read it in full before editing
3. If you touch BLE: `BLE/BandProtocol.swift` and `BLE/Services/MiBandUUID.swift`
4. If you touch data: the matching SwiftData model in `Models/`

---

## Rules by Area

### BLE (`BLE/`)

- `BandManager` is `@Observable @MainActor NSObject` — always access state on the main thread; do not dispatch to another queue without `Task { @MainActor in ... }`
- The authentication handshake is **sequential and stateful** — do not parallelize steps
- When changing packet parsing, add a fixture in `Tests/Fixtures/` with real captured bytes and a matching test
- Never reconnect in an infinite loop — use exponential backoff with a maximum of 5 attempts
- GATT characteristic UUIDs live only in `MiBandUUID.swift` — do not hardcode strings in other files
- V2 protocol: `XiaomiSppPacketV2`, service `FE95`, TX `005E`, RX `005F`. Legacy UUIDs FEE0/FEE1 and `0x0009` are for Mi Band 5/6 — do not use.
- Cryptographic primitives live in `BLE/Crypto/XiaomiCrypto.swift`; protobuf builders/parsers in `BLE/Protocol/XiaomiProto.swift` (thin layer over the types generated in `xiaomi.pb.swift` via SwiftProtobuf)
- `startScan()` may be called before BT is ready — the `pendingScan` flag in `BandManager` handles this; do not remove that logic
- **ACK is mandatory**: SPP V2 is a reliable transport with a window. **Every received DATA frame must be confirmed** with `sendAck(seqNum:)` using the received `seqNum`. Without it the band retransmits the entire handshake every ~6 s. Do not remove.
- **Post-auth init**: after `Authentication successful`, send `sendPostAuthInit()` (setCurrentTime + device info/state/battery). Without it the band considers the session incomplete and re-triggers auth.
- **A mismatched HMAC is not synonymous with a wrong AuthKey** (see ADR 0003). Four causes, only one is a wrong key: the band is still waiting for the user's acceptance (`sub=16` → `.awaitingPairingConfirmation`), the nonce arrived after our `CMD_AUTH` (`authStep3Sent` — `sub=27` decides), a nonce race (up to `maxNonceMismatches` tolerated), or the key really is wrong. Only the last case escalates to `retryAuthAfterReconnect()` (limit `maxAuthRetries`, teardown with increasing delay). Do not go back to dropping the link on the first mismatch: during pairing that dismisses the very prompt we are waiting for.
- **Session config received in `.connected` = the band opened a new session.** Redo the handshake and re-derive the keys (`maxBandSessionRestarts`), as GadgetBridge does on every session-config packet. Ignoring it leaves the app encrypting with dead keys — the band ACKs the transport and silently discards the command, and the sync hangs until the timeout with the link looking healthy. The duplicate guard applies **only** to `.authenticating` (the 005F bug).
- **Auth watchdog**: `armAuthWatchdog()` (20 s; 120 s during pairing) re-armed by every auth packet that makes progress. `AuthError.timeout` is a real timeout; a link drop is `AuthError.linkDropped`. Do not confuse the two again.
- BLE tests require a physical iPhone — the Simulator and the Mac do not connect to the Mi Band. **Authentication confirmed on real hardware (Mi Band 10) on 2026-06-19.**

### Auth / Keychain (`Auth/`)

- AuthKey **never** in SwiftData, UserDefaults, logs or prints
- Xiaomi Cloud credentials (email, password) **never** persisted — use only in memory during the extraction flow
- When writing to the Keychain: use `kSecAttrAccessibleAfterFirstUnlock` for background accessibility
- **The AuthKey is the only state the app cannot rebuild on its own** (see ADR 0004). The item's `service` is a fixed constant, not the bundle id — changing it without a migration loses the key. `save` updates in place (never `delete`+`add`). `isStored` distinguishes `.notFound` from `.locked`: a locked Keychain (background relaunch before the first unlock after boot) is **not** "no key" — answering `false` there sends a paired user back to setup.

### HealthKit (`Health/`)

- Always check authorization before writing — `HKHealthStore.authorizationStatus(for:)`
- Implement deduplication: query existing samples in the same period before inserting
- Use an `HKQueryAnchor` persisted in SwiftData for incremental syncs (do not re-sync everything every time)
- Sleep phases: map to `HKCategoryValueSleepAnalysis` (.inBed, .asleepCore, .asleepDeep, .asleepREM, .awake)
- **Never** include `HKCategoryType(.appleStandHour)` in `requestAuthorization(toShare:)` — it is reserved and throws `NSInvalidArgumentException` (third-party apps cannot write it)
- Workouts: use `HKWorkoutBuilder` (not the deprecated `HKWorkout` init); GPS route via `HKWorkoutRouteBuilder.insertRouteData` + `finishRoute(with:)`

### App Intents (`Intents/`)

- Each Intent must have a clear `title` and `description` so it shows up well in the Shortcuts app
- `perform()` must return a useful result — do not return empty when data is available
- Date parameters must have reasonable default values (e.g. "today" for `GetSleepDataIntent`)
- Register Siri phrases in `BandShortcuts.swift` via `AppShortcutsProvider`
- An intent made to run inside a Personal Automation (which fires on its own, often) must be **silent in the common case** — no dialog when there is nothing to say, like `CheckBandBatteryIntent`, which only notifies below the threshold. A dialog on every run becomes noise and the person turns the automation off.
- An intent that depends on the BLE link must not fail when the band is out of range: syncing is best-effort and the answer falls back to the last known data — an exception brings down the whole automation

### UI (`UI/`)

- **Design system**: the UI follows the Claude Design handoff (`My Band — Design System`). Before creating screens, read the bundle's README and the tokens (`tokens/colors.css`, `typography.css`, `spacing.css`) and the components in `components/`. Faithfully recreate in SwiftUI — do not copy the HTML structure, copy the visual result.
- **Dark-mode first**, midnight palette (`#0A0B10` base, cards `#14161F`), a single Aurora indigo accent `#7C7FFF`. Health colors mirror Apple Health; sleep-phase ramp dusk→deep-night.
- Copy in **English**, sentence case, no emoji; numbers are heroes (tabular). Status always by color + SF Symbol (never color alone).
- Pure SwiftUI — no direct UIKit except where absolutely necessary (e.g. `UIApplication` for background tasks)
- macOS support via `#if os(macOS)` / `#if os(iOS)` when behaviors diverge
- Do not create separate screens for Mac and iPhone — use `NavigationSplitView` to adapt the layout
- Sleep data is the priority feature — the dashboard must show it prominently
- Connection status and sync freshness are first-class — present on every screen, never buried

### Models (`Models/`)

- SwiftData models are the source of truth for historical data
- `BandDevice` stores only identifiers — the AuthKey lives in the Keychain
- When adding a field to a model, always set a default value for automatic migration

---

## What Not to Do

- **Do not use Combine** — the project uses async/await and @Observable exclusively
- **Do not use UserDefaults for sensitive data** — Keychain only
- **Do not add external dependencies (SPM)** without discussing. Dependencies approved so far: **SwiftProtobuf** (`apple/swift-protobuf`, used for the types generated in `xiaomi.pb.swift`). Any new one needs justification and approval.
- **Do not create ad-hoc documentation files** (NOTES, loose TODOs) — use inline comments only when the WHY is not obvious
- **Always update `CHANGELOG.md`** when adding, changing or fixing anything notable. Entries go under `## [Unreleased]` in the categories `Added / Changed / Deprecated / Removed / Fixed / Security` per [Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Do not record trivial internal refactors, only changes a future reader of the history would need to know.
- **Do not mock CBCentralManager in tests** — test only parsing layers that are independent of BLE
- **Do not write data to HealthKit without the user's explicit authorization** — always check `authorizationStatus`
- **Do not create an `Info.plist` inside `My Band/My Band/`** — the project uses `PBXFileSystemSynchronizedRootGroup` (Xcode 16), which automatically includes every file in the folder in the build. An Info.plist in there causes "Multiple commands produce Info.plist". The `Info.plist` lives at `$(SRCROOT)/Info.plist` (project root), with `GENERATE_INFOPLIST_FILE = NO` and `INFOPLIST_FILE = "Info.plist"` in the pbxproj.

---

## Build and Test

```bash
# Build on the simulator
xcodebuild -scheme "My Band" -destination "platform=iOS Simulator,name=iPhone 15 Pro" build

# Unit tests (parsers, conversions, HA logic)
xcodebuild test -scheme "My Band" -destination "platform=iOS Simulator,name=iPhone 15 Pro"
```

- BLE protocol tests: use fixture data (bytes captured from a real session), never a live device
- HealthKit tests: use `HKHealthStore` with a protocol-based mock — never write to the real Health in CI

---

## Future Phase: Mini App on the Band

The Mi Band 10 supports mini apps via a proprietary protocol that is still being reverse engineered. When the time comes:
- Create a separate `MiniApp/` module
- The mini app runs on the band and sends button events over BLE to the `BandManager`
- Those events must trigger the corresponding `AppIntent`s
- Do not implement anything in `MiniApp/` until there is confirmed protocol documentation

---

## Recommended Development Flow

- [x] **BLE V2 layer** — `MiBandUUID` (FE95/005E/005F), `BandProtocol` (XiaomiSppPacketV2 + CRC-16/ARC), `BandAuthenticator` (HMAC-SHA256), `BandScanner`, `BandManager`, `AuthKeyStore` — compiling on 2026-06-07
- [x] **Crypto + Proto** — `XiaomiCrypto` (HMAC-SHA256, HKDF, AES-CTR/CCM via CommonCrypto) and `XiaomiProto` (migrated to SwiftProtobuf + `xiaomi.pb.swift` generated from GadgetBridge)
- [x] **Base persistence** — `BandDevice`, `SleepSession`, `ActivityDay` SwiftData; `BandSyncer`; `SleepPacketParser` (V2 2-byte entries)
- [x] **Manual Info.plist** — fixes the CBCentralManager `NSInternalInconsistencyException` crash (UIBackgroundModes as `<array>`)
- [x] **Test on real hardware (2026-06-19)** — full auth on the Mi Band 10: HMAC-SHA256 handshake, first-pairing retry, transport ACK, post-auth init, stable encrypted communication. AuthKey validated.
- [x] **UI: design system + Setup (2026-06-19)** — tokens and components (`MBButton`/`MBIconButton`/`MBTextField`/`MBStatusPill`), `SetupView` (intro + AuthKey) and `ConnectingView` wired to the real `BandManager`; `RootView` routing the states
- [x] **HealthKit + Dashboard (2026-06-19)** — `HealthKitManager` (sleep/steps/calories/distance/HR/SpO₂ with dedup), `DailySummary`/`DailyDetails` parsers, `BandSyncer.syncToHealth()`, battery in `BandManager` and `DashboardView` (battery + last sync + button). **Hardware validation pending** (activity file format, cumulative vs delta steps).
- [x] **Manual-measurement + workout parsers (2026-06-19)** — `ManualSamplesParser` (HR/SpO₂/stress/temperature), `WorkoutSummaryParser` (+ positional builder, all sport types) and `WorkoutGpsParser`; `HealthKitManager` writes `HKWorkout`/GPS route/VO₂ max/temperature/resting HR. Fixed the `appleStandHour` authorization crash. **Hardware validation pending.**
- [ ] **UI: SleepDetail + Settings** → next screens from the Claude Design handoff
- [ ] **Device info / battery parsers** → `Proto command type=2` still only logged; parse to feed the Dashboard
- [x] **HealthKit** → `HealthKitManager` + per-minute reconciliation + deduplication
- [x] **App Intents** → `SyncBandIntent` + `GetSleepStateIntent` + `CheckBandBatteryIntent` + `BandShortcuts`
- [x] **AuthKey via Xiaomi Cloud** → `XiaomiCloudAuth` by username/password (alternative flow to manual)
- [ ] **Mini App** → (future phase, wait for protocol definition)
