# My Band

> Xiaomi made the Mi Band. I turned it into My Band.

A native **iOS/macOS** app (SwiftUI + SwiftData) that connects your iPhone to a **Mi Band 10** over Bluetooth Low Energy and syncs health data to **Apple Health** — with no Xiaomi cloud in the way, straight from the band to a central, agnostic place. It also exposes state and actions through Shortcuts and Siri, for automations on the iPhone itself.

The official Mi Band 10 app does not send every metric the gadget collects to Apple Health. My Band exists to fill that gap — and so that health data really belongs to the user.

---

## Engineering highlights

This is a personal project that served as a lab for BLE, applied cryptography and deep HealthKit integration. What makes it interesting from a technical point of view:

- **🔐 Reverse-engineered cryptographic authentication, validated on hardware.** The Mi Band 10 handshake implemented from scratch in Swift: nonce exchange, HMAC-SHA256, session-key derivation via HKDF and encrypted communication with AES (CTR/CCM). Tested on a physical band, with real data.
- **📡 Binary protocol reverse engineering.** Packet format (frames, CRC-16/ARC, reliable transport with ACK, protobuf) and parsers for sleep, workouts and GPS route. Including a **per-second heart-rate series that the open-source reference implementation (GadgetBridge) does not decode** — layout reverse-engineered from real captures and validated by CRC-32.
- **❤️ Deep HealthKit integration.** Sleep, steps, HR, SpO₂, workouts with GPS route, physical effort, workout effort and heart-rate recovery. Highlight: a **per-minute reconciliation** layer that writes only the band's surplus over the iPhone — no double-counted steps and no breaking the Mobility metrics that iOS reserves.
- **🏗️ Modern concurrency and architectural discipline.** Swift 5.10, `async/await`, `@Observable`, `@MainActor`, background BLE with state restoration, unit tests with real-data fixtures and an AuthKey that never leaves the Keychain.

---

## Features

| Status | Feature |
|---|---|
| ✅ | BLE V2 connection with HMAC-SHA256 authentication via AuthKey — **validated on hardware (Mi Band 10)** |
| ✅ | Protobuf protocol via SwiftProtobuf (types generated from GadgetBridge) |
| ✅ | Reliable transport with ACK + post-auth init + first-pairing retry |
| ✅ | Secure AuthKey storage in the Keychain |
| ✅ | Automatic reconnection with exponential backoff |
| ✅ | Background BLE (band stays connected while the app is suspended) |
| ✅ | CBCentralManager state restoration after system suspension |
| ✅ | Sleep data sync (XiaomiSppPacketV2 parser) |
| ✅ | Local persistence with SwiftData (BandDevice, SleepSession, ActivityDay) |
| ✅ | Reassembly of fragmented BLE frames (activity files > MTU) |
| ✅ | Battery reading (level + charging) |
| ✅ | Setup UI (AuthKey + scan/connect) and Dashboard (battery, last sync, sync button) via Claude Design |
| ✅ | Upload to Apple Health — sleep (stages) and daily activity (steps, calories, distance, HR + resting HR, SpO₂) — **validated on hardware (Mi Band 10)** |
| ✅ | Background sync via `BGProcessingTask` (reconnects, syncs and reschedules while the app is suspended) — **validated on hardware** |
| ✅ | Manual measurements in Apple Health (HR, SpO₂) — **validated on hardware (Mi Band 10)** |
| ✅ | Workouts in Apple Health (`HKWorkout` + GPS route + VO₂ max) and GPS handshake with the iPhone (CoreLocation → `workoutLocation` stream) — **validated on hardware** |
| ✅ | Per-second workout HR series attached to the `HKWorkout` (HR chart inside the workout) — **validated on hardware** |
| ✅ | Rich metrics in Apple Health — physical effort (METs/min), workout effort (iOS 18+), heart-rate recovery, rowing speed/stroke and distance, derived from real measurements |
| ✅ | Per-minute reconciliation (writes only the band's surplus over the iPhone — no double-counted steps, Mobility preserved) — **validated on hardware** |
| ✅ | OKOK/Chipsea BLE scale (broadcast-only) → weight + BMI in Apple Health, with a height profile — **validated on hardware** |
| ✅ | AuthKey extraction via Xiaomi Cloud (QR login, no Xiaomi app) |
| ✅ | Unit-test target (Swift Testing, 23 tests) with real fixtures — **validated on iPhone** |
| ✅ | Shortcuts integration via App Intents and Siri phrases — **validated on hardware** |
| ✅ | Band battery shortcut with a configurable threshold — notifies only below the threshold, built for the "when I plug the iPhone into the charger" automation (v1.2) |
| ✅ | Sanitization and deduplication of sleep stages and physiological validation of vital signs (v1.1) |
| 🔜 | SleepDetail (hypnogram) + Settings screens |
| 🔜 | Custom mini app on the band with actionable buttons |

---

## Requirements

- **Xcode 16+**
- **iOS 17+** / **macOS 14+**
- Personal Apple Developer Program account (sideload — not published on the App Store)
- Mi Band 10 with a known AuthKey
- SPM dependency: **SwiftProtobuf** (`apple/swift-protobuf`) — resolved automatically by Xcode

---

## Initial setup

### 1. Get the AuthKey

The AuthKey is a 16-byte key (32 hex characters) tied to your device. Ways to obtain it:

- **Through the app itself** — Setup guides the extraction via **Xiaomi Cloud with QR login** (no password typed in the app; authentication happens on Xiaomi's side). The app walks through the Xiaomi regions and retrieves the band's *beaconkey*, which is the AuthKey. Flow ported from `token_extractor.py`, **still to be validated with a real account**.
- **Via Python** — [`huami-token`](https://github.com/argrento/huami-token): logs in to the Xiaomi account and extracts the token
- **Via GadgetBridge** — export the AuthKey from the app's database on Android

### 2. Enter the AuthKey in the app

On first use, the app opens the **Setup** screen when there is no AuthKey in the Keychain: enter the 32 hex characters of the AuthKey (secure, masked field) and tap **Connect band**. The app validates and stores the key in the Keychain with access after first unlock (`kSecAttrAccessibleAfterFirstUnlock`), allowing background sync. The key is **never** written to code, logs, SwiftData or UserDefaults.

### 3. Pair the band

The app automatically scans for devices named `Xiaomi Smart Band 10`. When it finds one, it starts the HMAC-SHA256 V2 handshake and keeps the connection persistent.

> **Note:** BLE tests require a physical iPhone. The Simulator and the Mac do not have the BLE stack needed to connect to the band.

---

## Architecture

```
My Band/
├── BLE/
│   ├── BandManager.swift         # @Observable @MainActor orchestrator — scan, connect, auth
│   ├── BandAuthenticator.swift   # HMAC-SHA256 V2 handshake (pure, testable)
│   ├── BandSyncer.swift          # Data sync → SwiftData
│   ├── BandScanner.swift         # BLE discovery filters
│   ├── BandProtocol.swift        # XiaomiSppPacketV2 encoding + CRC-16/ARC
│   ├── Crypto/
│   │   └── XiaomiCrypto.swift    # HMAC-SHA256, HKDF-expand, AES-CTR/CCM (CommonCrypto)
│   ├── Protocol/
│   │   ├── XiaomiProto.swift     # Builders/parsers (thin layer over SwiftProtobuf)
│   │   └── xiaomi.pb.swift       # Types generated from xiaomi.proto (GadgetBridge)
│   └── PacketParser/
│       ├── SleepPacketParser.swift     # Sleep 0x08 (stages FB FA FC FF + HR/SpO₂)
│       ├── DailySummaryParser.swift    # Daily totals + shared LEReader
│       ├── DailyDetailsParser.swift    # Per-minute series (HR/SpO₂/distance/stress)
│       ├── ManualSamplesParser.swift   # Manual measurements (HR/SpO₂/stress/temperature)
│       ├── WorkoutSummaryParser.swift  # Workout summaries (blueprint per subtype/version)
│       ├── WorkoutGpsParser.swift      # Workout GPS track (V1/V2)
│       └── XiaomiActivityFile.swift    # 7-byte id metadata + routing
│
├── Auth/
│   └── AuthKeyStore.swift        # Keychain: AuthKey read/write/delete
│
├── Models/                       # SwiftData
│   ├── BandDevice.swift          # Paired device
│   ├── SleepSession.swift        # Sleep session + phases (light/deep/REM/awake)
│   └── ActivityDay.swift         # Steps, calories, distance per day
│
├── Health/
│   └── HealthKitManager.swift    # Writing to Apple Health (sleep/activity/workouts/route)
├── Intents/                      # App Intents + Shortcuts (in development)
└── UI/                           # SwiftUI (in development)
```

Full details on architecture, the BLE protocol and conventions in [`CLAUDE.md`](CLAUDE.md).

---

## BLE protocol — Mi Band 10 V2

The Mi Band 10 uses the **XiaomiSppPacketV2** protocol over BLE (confirmed via GadgetBridge).

**Service:** `0000FE95` | **TX (write):** `0000005E` | **RX (notify):** `0000005F`

**Frame (8-byte header; CRC-16/ARC of the payload):**
```
[0xA5][0xA5] preamble
[type][seqNum][lenLo][lenHi][crcLo][crcHi]
[payload...]      # DATA: [channel][opCode][bytes]
```

**Authentication (HMAC-SHA256):**
1. Session config (binary) → band response
2. `CMD_NONCE` (type=1, sub=26) with 16 random bytes from the app
3. Band responds: `watchNonce(16) + HMAC-SHA256(watchNonce+phoneNonce, decKey)(32)`
4. Verify HMAC → derive 4 session keys via HKDF-expand("miwear-auth", 64)
5. `CMD_AUTH` (type=1, sub=27) with `authStep3` (HMAC of the nonces + device info in AES-128-CCM)
6. Post-auth init (time + device info/state/battery) — without it the band re-triggers auth

> **Reliable transport:** every DATA frame received from the band is confirmed with an ACK (same `seqNum`), or the band retransmits the handshake every ~6 s.
> **First pairing:** the band advertises with `auth sub=16` and only emits a verifiable watch-nonce after you accept **on the band and on the iPhone**. The app waits for that acceptance instead of treating the earlier nonces as a wrong key (see [ADR 0003](docs/adr/0003-patient-band-driven-handshake.md)).
> The AuthKey (secretKey) is 16 bytes. It lives **only in the Keychain** — never in logs, SwiftData or UserDefaults.

---

## Interface (UI)

The UI is being built from a **dark-mode-first design system** delivered by Claude Design — *midnight* palette optimized for OLED, Aurora indigo accent, health colors mirroring Apple Health and a sleep-phase ramp. Copy in **English**, focused on glanceable status and quick setup (the app is a background gateway). Details on tokens, components and screens in [`CLAUDE.md`](CLAUDE.md#ui--design-system).

---

## References

- [GadgetBridge](https://codeberg.org/Freeyourgadget/Gadgetbridge) — reference implementation of the Mi Band 10 V2 protocol (auth, activity/workout parsers, watch faces/RPK, time)
- [huami-token](https://github.com/argrento/huami-token) — AuthKey extraction via Xiaomi Cloud
- [homeassistant-okokscale](https://github.com/rrooggiieerr/homeassistant-okokscale) (Apache-2.0) — reference for decoding the OKOK/Chipsea BLE scale (VC0 variant)
- [Open-Meteo](https://open-meteo.com/) — weather forecast sent to the band (free, no key)
- AstroBox-NG — BLE protocol reference for wearables (not included in the public repository)
- [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) / [Semantic Versioning](https://semver.org/spec/v2.0.0.html)

> This project ports protocol excerpts from GadgetBridge and homeassistant-okokscale (reverse engineering of BLE formats). Credit to those projects is given above; no AuthKey, credential or secret is included in the repository.

---

## Changelog

See [`CHANGELOG.md`](CHANGELOG.md).
