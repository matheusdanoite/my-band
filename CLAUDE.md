# CLAUDE.md — My Band

Architecture guide and guidelines for the **My Band** project: a universal iOS/macOS app that connects the Mi Band 10 via BLE using an AuthKey, syncs health data with Apple Health and supports Shortcuts via App Intents. No health-data visualization on its own screen — Apple Health is the only data surface; the app is just sync, configuration and status.

---

## Project Overview

| Item | Detail |
|---|---|
| Platforms | iOS 26+ (a single Xcode target; runs on the Mac via "Designed for iPad and iPhone", it is not a native macOS target — `IPHONEOS_DEPLOYMENT_TARGET` in the pbxproj is the source of truth) |
| Language | Swift 5.10+ |
| UI | SwiftUI, Liquid Glass on chrome/status (`MBStatusPill` etc.) |
| Persistence | SwiftData |
| Bluetooth | CoreBluetooth (BLE only — the Mi Band 10 does not use Classic BT) |
| Health | HealthKit — the only data visualization surface (see ADR 0001) |
| Automation | App Intents + Shortcuts |
| Distribution | Personal use — sideload via a personal Apple Developer Program account (no App Store) |

---

## Module Architecture

```
My Band/
├── App/
│   ├── My_BandApp.swift          # Entry point, global dependency injection
│   └── AppDelegate.swift         # BLE background lifecycle on iOS
│
├── BLE/
│   ├── BandManager.swift         # Central BLE orchestrator (@Observable @MainActor NSObject)
│   ├── BandScanner.swift         # Discovery and filtering of Mi Band devices
│   ├── BandAuthenticator.swift   # AES-128 handshake with AuthKey
│   ├── BandProtocol.swift        # Mi Band protocol packet encoder/decoder
│   ├── BandSyncer.swift          # Historical data sync (sleep, steps, HR)
│   ├── WorkoutGpsService.swift   # GPS handshake during workouts (band→app workoutOpenWatch)
│   ├── FindPhoneService.swift    # "Find phone": alarm on the iPhone (band→app CMD_FIND_PHONE)
│   ├── CalendarSyncService.swift # Push app→band: language, calendar and reminders (EventKit)
│   ├── WeatherSyncService.swift  # Push app→band: current weather + forecast (Open-Meteo)
│   ├── Scale/                    # OKOK/Chipsea BLE scale (independent of the band)
│   │   ├── ScaleManager.swift    # Listens to the advertisement (broadcast-only) and writes weight to Apple Health
│   │   └── ScaleWeightParser.swift # Weight decode (VC0 variant)
│   └── Services/
│       ├── MiBandUUID.swift      # GATT service UUID constants
│       └── PacketParser/         # Parsers by type (sleep, daily, manual, workouts+GPS, intra-workout HR)
│
├── Auth/
│   ├── AuthKeyStore.swift        # Secure AuthKey storage in the Keychain
│   ├── XiaomiCloudAuth.swift     # AuthKey extraction via Xiaomi Cloud (username/password login → beaconkey/token)
│   └── XiaomiCloudCrypto.swift   # RC4/SHA-1/SHA-256 of the account API (separate from the BLE XiaomiCrypto)
│
├── Health/
│   ├── HealthKitManager.swift    # Authorization and writing to Apple Health
│   └── HealthSyncService.swift  # Conversion of Mi Band data → HealthKit types
│
├── Intents/
│   ├── SyncBandIntent.swift      # App Intent: sync data now
│   ├── GetSleepStateIntent.swift # App Intent: "am I asleep?" (pull, not push — see note)
│   ├── CheckBandBatteryIntent.swift # App Intent: notifies only if the battery is below the threshold
│   └── BandShortcuts.swift       # AppShortcutsProvider with Siri phrases
│
├── MiniApp/                      # (Future phase) Mini app on the band
│   └── README.md                 # Mini app protocol documentation
│
├── Models/
│   ├── BandDevice.swift          # SwiftData model of the paired device
│   ├── SleepSession.swift        # SwiftData model of a sleep session
│   ├── ActivityDay.swift         # SwiftData model of daily activity
│   └── HeartRateSample.swift     # SwiftData model of HR samples
│
└── UI/
    ├── Dashboard/                # Main screen with data summary
    ├── Setup/                    # Setup flow (AuthKey + HA)
    ├── Sleep/                    # Detailed sleep visualization
    ├── Profile/                  # User profile (height → BMI in Apple Health)
    ├── Customize/                # Watch faces and RPK apps
    └── Settings/                 # General settings
```

---

## Mi Band 10 BLE Protocol

> **Protocol confirmed via GadgetBridge** (`XiaomiSppPacketV2`, `XiaomiAuthService`, `MiBand10Coordinator`).
> The earlier implementation (AES-128-ECB + UUIDs FEE0/FEE1) was for the Mi Band 5/6 and was discarded.

### Services and Characteristics (BLE V2)

| UUID | Function |
|---|---|
| `0000FE95-0000-1000-8000-00805F9B34FB` | Xiaomi BLE V2 Service (the only relevant service) |
| `0000005E-0000-1000-8000-00805F9B34FB` | TX — write (app → band, without response) |
| `0000005F-0000-1000-8000-00805F9B34FB` | RX — notify (band → app) |
| `0000180D-0000-1000-8000-00805F9B34FB` | Heart Rate Service (standard GATT) |
| `0000180F-0000-1000-8000-00805F9B34FB` | Battery Service (standard GATT) — what iOS reads for the Batteries widget |
| `00002A19-0000-1000-8000-00805F9B34FB` | Battery Level — `UInt8` 0–100, read + notify (read **only post-auth**, see `CheckBandBatteryIntent`) |

### Frame Format — XiaomiSppPacketV2

8-byte header (confirmed in `XiaomiSppPacketV2.java`; see `BandProtocol.swift`):

```
[0xA5][0xA5]   preamble (2 bytes)
[type]         lower 4 bits = packetType: 1=ACK, 2=SESSION_CONFIG, 3=DATA
[seqNum]       sequence counter (UInt8)
[lenLo][lenHi] payload length (UInt16 LE)
[crcLo][crcHi] CRC-16/ARC of the PAYLOAD only (poly=0x8005, refin/refout, init=0)
[payload...]   payload bytes
```

Payload of a DATA packet (inside the payload above):
```
[channel]  lower 4 bits: 1=PROTOBUF, 2=DATA, 5=ACTIVITY
[opCode]   1=PLAINTEXT, 2=ENCRYPTED (AES-CTR, encryptV2/decryptV2 with IV=key)
[bytes...] Command protobuf (or ciphered bytes, if opCode=2)
```

**Reliable transport (window/ACK).** SPP V2 negotiates `TX_WIN` and numbers the packets. **Every DATA frame received from the band must be confirmed** with an ACK packet (`type=1`) carrying the same `seqNum` (`BandManager.sendAck`). Without an ACK, the band assumes loss and retransmits the entire handshake every ~6 s. DATA packets sent by the app use their own incrementing counter (`nextSeq`).

**Protobuf via SwiftProtobuf.** The `Command`, `Auth`, `WatchNonce`, `Health`, `System`, etc. messages come from the types generated in `BLE/Protocol/xiaomi.pb.swift` (generated from GadgetBridge's `xiaomi.proto`). `XiaomiProto.swift` is just the thin layer of builders/parsers.

### Authentication Flow (HMAC-SHA256 V2)

1. **Connect** to the BLE device (name `Xiaomi Smart Band 10 XXXX`)
2. **Discover** service `FE95` → characteristics `005E` (TX) and `005F` (RX)
3. **Enable notifications** on `005F`
4. **Session config**: send `Command{type=0, sub=1, payload={mtu=512, version=2}}` on the COMMAND channel
5. **CMD_NONCE** (type=1, sub=26): send 16 bytes of random nonce from the app
6. **Band responds**: `watchNonce(16) + HMAC-SHA256(watchNonce+phoneNonce, secretKey)(32)`
7. **Verify the band's HMAC**
8. **Derive session keys**:
   ```
   prk = HMAC-SHA256(phoneNonce + watchNonce, secretKey)
   keys[0..63] = HKDF-expand(prk, "miwear-auth", 64)
   decryptionKey  = keys[0..15]
   encryptionKey  = keys[16..31]
   decryptionNonce = keys[32..35]
   encryptionNonce = keys[36..39]
   ```
9. **CMD_AUTH** (type=1, sub=27): `authStep3 { encryptedNonces = HMAC-SHA256(phoneNonce+watchNonce, encKey), encryptedDeviceInfo = AES-128-CCM(authDeviceInfo) }`
   - CCM nonce = `encryptionNonce(4) || zeros(4) || counter=0(4)`
   - Post-auth communication uses AES-CTR with a V2 peculiarity: **IV = key** (GadgetBridge: "I wish I was kidding")
10. **Band responds** `sub=27` → **Authenticated**, encrypted communication
11. **Mandatory post-auth init** (`sendPostAuthInit`): `setCurrentTime` + `device info (2/2)` + `device state (2/78)` + `battery (2/1)`. Without it the band re-triggers auth every ~6 s.

> **First pairing — the app waits for the user, through two prompts and across the link drop between them** (decision and trade-offs in `docs/adr/0003-patient-band-driven-handshake.md`, including the 2026-09-09 addendum)**.** The first connection asks for **two** confirmations, in order and on different screens: the band raises its own dialog (`auth sub=16`, a subtype GadgetBridge doesn't even handle) and only then does iOS raise the Bluetooth pairing sheet — and to establish the bond **iOS drops the connection**. That is why the wait is a **180 s deadline (`pairingDeadline`) that spans connections**, not a state of the current connection: `resetState` clears only the per-connection flag and `startNonceExchange` restores the wait when reconnecting within the window. While it is open: a mismatched HMAC is expected (the band signs with a bond that doesn't exist yet) and only extends the window, the watchdog re-arms, and the `retryAuthAfterReconnect` budget is **not spent** — a long pairing cannot end in `badHMAC` ("Incorrect AuthKey"). A mismatch on a band we have never authenticated against (`everAuthenticated`, `UserDefaults`) starts the wait instead of counting it. `CBATTError.insufficientAuthentication` on a write is **not a failure**: it is iOS warning that it is going to ask for pairing — the only concrete signal of the second prompt, and it used to kill the handshake the instant the sheet came up. `CBError.peerRemovedPairingInformation` → `AuthError.staleBond` (forget the device in Settings › Bluetooth; reconnecting never fixes it). `PairingStage` (`.band` → `.phone`, only advances) feeds the two-step checklist on the connection screen and **does not decide protocol logic**. `sub=16` and the pre-accept mismatches are confirmed on hardware (Mi Band 10, 2026-06-19 and 2026-09-05); the **complete accept path** has **not** yet been exercised — the logs came from an already-paired band and from attempts that failed.

> **The band reopens the session on its own — and that invalidates the keys.** Right after the post-auth init it sends a new `session-config-accept`, resets its own sequence counter and redoes the handshake (new watch-nonce, new `sub=27`). GadgetBridge (`XiaomiBleProtocolV2.processPacket`, `PACKET_TYPE_SESSION_CONFIG`) calls `startEncryptedHandshake()` on **every** session-config packet, regardless of state — that's why. Ignoring this packet leaves the app with the old keys: the band ACKs the transport frame and **silently discards the command**, so the sync hangs until the timeout with the link looking perfect. `handleSessionConfigResponse` redoes the handshake when the state is `.connected` (limit `maxBandSessionRestarts`), and only ignores a repeat that arrives with the handshake still in flight (`.authenticating`) — which is where the 005F bug lived. Confirmed on hardware (2026-09-05).
>
> **The restart lands exactly where the sync begins.** `ensureConnected` resolves on the first auth, so a sync that opened the link sends `FETCH_TODAY` in the restart window — and it gets lost. `BandManager.onSessionRestart` notifies the `BandSyncer`, which makes the in-flight command exchange fail immediately (`SyncError.sessionRestarted`) and resends it after the re-handshake (`surviveSessionRestart` + `BandManager.awaitSession`), for listings and files. `ensureConnected` called with a handshake in progress only waits (reconnecting on top of it redid service discovery and fired a second `authenticate()`). Past `maxBandSessionRestarts`, the link is dropped so the standing reconnect starts clean.

> **Late nonce ≠ failure.** After `CMD_AUTH`, the band re-emits a watch-nonce of its own — a handshake restart on its side, not a response to ours. Verifying it against the already-superseded phone-nonce **always** fails; the band confirms the original handshake anyway. `authStep3Sent` makes the app ignore nonces with `CMD_AUTH` in flight and wait for `sub=27`. For the same reason (a nonce already in the air when our `CMD_NONCE` went out was signed against a phone-nonce the band hasn't seen yet), `maxNonceMismatches` tolerates 2 mismatches per nonce exchange before escalating — a genuinely wrong AuthKey always diverges and still ends in `AuthError.badHMAC`. Without that, the same packet brought down a handshake one step from success (2026-09-05 hardware log, where both orders appear: the late nonce before `sub=27` killed the connection, after `sub=27` it was harmless).

> **Auth watchdog.** `armAuthWatchdog()` — 20 s normal, 120 s during pairing — re-armed by every auth packet that makes progress. Before, `AuthError.timeout` only came out of a disconnection: "Timed out" actually meant "the link dropped" (now `AuthError.linkDropped`) and a band that went silent hung. When it fires **outside** a pairing, the watchdog drops the link so the standing reconnect takes over; inside the pairing window it only re-arms (silence there is a person reading a dialog) and only fails when the window expires, with `AuthError.pairingNotConfirmed`. `retryAuthAfterReconnect` postpones the teardown with an increasing delay (1–4 s) — reconnecting immediately burned the 4 attempts in seconds.

> The AuthKey (secretKey) is 16 bytes (32 hex chars). Keychain with `kSecAttrAccessibleAfterFirstUnlock`. Never in SwiftData/UserDefaults/logs. Nonces and HMACs **may** be logged in debug (they are not secrets); session keys and the AuthKey, never.

> **The key must survive updates, renames and relaunches** (see `docs/adr/0004-authkey-keychain-durability.md`)**.** `AuthKeyStore` indexes the item by a **fixed** `service` (`com.myband.authkey`), not by the bundle id read at runtime — otherwise a bundle/target rename would make the app present itself as unpaired with the key intact under the old name; the legacy item (bundle id) is migrated on first read. `save` updates in place (the earlier `delete`+`add` lost the key if the add failed) and the item is pinned as **non-synchronizable**, so that no iCloud Keychain entry shadows the local one. `isStored` distinguishes `errSecItemNotFound` from `errSecInteractionNotAllowed`: on a background relaunch **before the first unlock after boot** the key exists but is unreadable, and answering "no key" there sent an already-paired user back to setup.

### Sync Commands

| Command | type | subtype | Description |
|---|---|---|---|
| Fetch today | 8 | 1 | Lists the day's pending activity file-ids |
| Fetch past | 8 | 2 | Lists the backlog of days not yet synced |
| Fetch request | 8 | 3 | Requests the content of a file-id (streamed in chunks) |
| Fetch ACK | 8 | 5 | Marks a file-id as synced |

### Band-initiated commands (band → app)

Some features are **push** from the band: it sends the command and the app reacts. `BandManager` decodes them after auth and fires callbacks (`onWorkoutOpenWatch`, `onWorkoutStatusWatch`, `onFindPhone`, `onWeatherConditionsRequest`), consumed by dedicated services.

| Command | type | subtype | Handled by | Reaction |
|---|---|---|---|---|
| `CMD_FIND_PHONE` | 2 (SYSTEM) | 17 | `FindPhoneService` | `system.findDevice` 0=start / ≠0=stop. Alarm: `AVAudioSession.playback` + synthesized looping siren + vibration + notification. Auto-stop after 45 s. |
| `workoutOpenWatch` | 8 (HEALTH) | 30 | `WorkoutGpsService` | Starts CoreLocation and replies GPS ready/disabled |
| `workoutStatusWatch` | 8 (HEALTH) | 26 | `WorkoutGpsService` | started/resumed/paused/finished → controls the GPS stream (paused stops transmitting); on **finished** it fires `onWorkoutFinished(fileIds)` → `BandSyncer.syncWorkoutFiles` fetches the named files (summary + GPS route) |
| `CMD_REQUEST_CONDITIONS_FOR_LOCATION` | 10 (WEATHER) | 3 | `WeatherSyncService` | Band asks for the weather (on connect / opening the weather screen) → app replies with a weather push, echoing the requested location key/name. See "Configuration sent to the band". |

> **The end of a workout triggers an automatic, targeted sync.** `workoutStatusWatch` status=finished **carries the `activityFileIds`** of the workout just recorded (summary + GPS route). `BandManager` passes them on in the callback (`onWorkoutStatusWatch(status, fileIds)`) → `WorkoutGpsService.onWorkoutFinished(fileIds)` → `BandSyncer` waits ~8 s (the band flushing the file) and runs `syncWorkoutFiles(_:)` if still connected, fetching/parsing/writing/ACKing **exactly** those files — without relisting the backlog (FETCH_TODAY/PAST). Firmware that omits the ids falls back to the full `syncToHealth()`. The per-file processing loop is shared in `BandSyncer.processActivityFiles`. Daily totals, which the workout also updates, are left for the next regular sync.
>
> **There is no equivalent trigger for "waking up".** The Mi Band 10 does not send a sleep-end event; sleep is only fetched when the app runs the fetch (foreground or `BackgroundSyncManager`). Outside the end of a workout, the model remains **pull**: the app reconnects and fetches the pending file-ids.

### Configuration sent to the band (app → band)

`CalendarSyncService` (language/calendar/reminders) and `WeatherSyncService` (weather, via Open-Meteo) do an encrypted push at the end of `BandSyncer.syncToHealth()`, together with the health/exercise data and while the link is up (best-effort — it does not bring down the health sync). Each section is independent — a denied permission or a lack of network does not block the others.

| Data | type | subtype | Proto | Source / notes |
|---|---|---|---|---|
| Language | 2 (SYSTEM) | 6 `CMD_LANGUAGE` | `system.language.code` | `Locale` → lowercase `"pt_br"` |
| Calendar | 12 | 1 `CMD_CALENDAR_SET` | `calendar.calendarSync.event[]` | EventKit, next 30 days, ≤50, **replaces** the set on the band |
| Reminder (create) | 17 (SCHEDULE) | 15 `CMD_REMINDERS_CREATE` | `schedule.createReminder` | EventKit, with a due date, ≤20 |
| Reminder (delete) | 17 | 18 `CMD_REMINDERS_DELETE` | `schedule.deleteReminder.id[]` | deletes the previous sync's ids before recreating |
| Weather (location) | 10 | 7 `CMD_ADD_LOCATION` | `weather.location` | `WeatherSyncService`, key `accu:<hash>` |
| Weather (current) | 10 | 0 `CMD_SET_CURRENT_WEATHER` | `weather.current` | Open-Meteo, Guarapuava |
| Weather (forecast) | 10 | 1 `CMD_UPDATE_DAILY_FORECAST` | `weather.forecast` | 7 days (today + 6) |

> **Weather is request-driven — the band asks, the app answers.** The Mi Band 10 sends `CMD_REQUEST_CONDITIONS_FOR_LOCATION` (type=10, subtype=3) on connect and when opening the weather screen; the screen **waits for the response to that request**, so the proactive push (at the end of `syncToHealth()`) alone does not populate the widget. `BandManager.handleWeatherCommand` routes subtype=3 to the `onWeatherConditionsRequest` callback, and `WeatherSyncService` replies with a full push (location → current → forecast). The reply **echoes the location key/name the band asked for** (`requestedKey`/`requestedName`) so it can bind the data; without a request, the push uses the default location with `isCurrentLocation=true`. Status≠0 in the band's responses to our pushes (subtypes 0/1/7) is logged. Mirrors GadgetBridge's `XiaomiWeatherService.onConditionRequestReceived`.

> **The reminder id is assigned by the band.** The create carries no id; the band replies with `schedule.ackId` (type=17). `BandManager.onScheduleAck` captures those ids, which `CalendarSyncService` persists (`UserDefaults`) and uses to delete on the next sync — without that, reminders would pile up on the band.

> **Frames > MTU.** A calendar with many events exceeds the ATT MTU. `BandManager.writeSPP` fragments the frame into MTU-sized chunks (`maximumWriteValueLength`); the band reassembles using the length declared in the frame. Auth/init packets fit in one chunk — the handshake path is unchanged.

The same file-id mechanism serves **all** data types — each 7-byte id (`XiaomiActivityFileMeta`) declares its type/subtype/detailType, and `BandSyncer.syncToHealth()` routes to the right parser:

| File type | subtype | Parser |
|---|---|---|
| Daily summary | `0x00` SUMMARY | `DailySummaryParser` |
| Daily detail (per minute) | `0x00` DETAILS | `DailyDetailsParser` |
| Sleep (by duration) | `0x08` (any detail) | `SleepDetailsParser` (see note) |
| Sleep (by transition) | `0x03` DETAILS | `SleepStagesParser` (see note) |
| Manual measurements | `0x06` | `ManualSamplesParser` |
| Workout (summary) | SPORTS · SUMMARY | `WorkoutSummaryParser` |
| Workout (GPS route) | SPORTS · GPS | `WorkoutGpsParser` |
| Workout (per-second HR detail) | SPORTS · DETAILS | `WorkoutDetailsParser` |

> **Per-second workout HR series (`WorkoutDetailsParser`).** During a workout the band records a `SPORTS · DETAILS` file (subtype `0x08`) with **one HR sample per second**. GadgetBridge does **not** parse this (`XiaomiActivityParser.createForSports` only handles `SUMMARY`/`GPS_TRACK` and discards the rest), so the layout was reverse-engineered from a real capture (Mi Band 10, 2026-06-23, version 3) and validated by CRC-32: `[id:7][pad:1][header:11]` with the duration (s) in `u16@10` (== number of samples), followed by `duration` samples `[hr:u8][flag:u8][00][00]`, 1 Hz from the start (hr=0 during the ~18 s of sensor acquisition; `flag=1` every ~12 samples, a keyframe — ignored). `BandSyncer` matches the series to the workout by timestamp (same as the GPS route) and `HealthKitManager.writeWorkouts` attaches the samples to the `HKWorkout` (in the builder, before `finishWorkout`, sync-id per sample). Only version 3 is confirmed; other versions → empty series (the file is still ACKed). For other `SPORTS · DETAILS` subtypes/versions (e.g. `0x16`, version 5) the parser returns empty and the `else` branch of `processActivityFiles` just ACKs — without the ACK the band re-offers the file on every connection (perpetual re-download; one of them was 12 KB). New fixtures: `dumpActivityFileFixture` (DEBUG).

Sleep `0x08`: each stage entry is UInt16 BE — bits[15:12]=stage (0=awake,1=light,2=deep,3=rem), bits[11:0]=duration_min.

> **Two sleep formats.** GadgetBridge uses `SleepStagesParser` for `0x03` (ACTIVITY_SLEEP_STAGES, **transition-event** layout, stage codes `2=deep,3=light,4=rem,5=awake`) and `SleepDetailsParser` for `0x08` (**duration** layout). **Validated on hardware (Mi Band 10, 2026-06-21): the real sleep fetch works with `SleepDetailsParser` — the band emits `0x08`.** The `0x03` used to fall into the same parser, which read the bytes at the wrong offsets; it now goes to the ported `SleepStagesParser` (version 2 only, as in GadgetBridge; covered by a synthetic file, **not** by a real capture). `0x08` versions outside 1–5 return empty instead of guessing the layout. `BandSyncer` logs one line per sleep file (`Sleep file … N session(s), N phase(s), N HR, N SpO₂`) — that is how you can see, in the console, whether a night arrived and in what format.
>
> **A sleep file is never confirmed without being read, nor does it bring down the rest.** If the band answers a fetch with another file still without an ACK, that file is routed normally and only then ACKed (before, it was ACKed blindly, losing the content). Writing the sleep data runs isolated in `processActivityFiles`: if it throws, only the sleep files stay without an ACK and come back on the next sync — manual measurements, workouts and daily detail carry on. Each file's fetch uses an **inactivity** timeout (10 s without a chunk), not a fixed cap.

### Watch face and app installation (app → band)

Customization feature (`BLE/Upload/`), ported from GadgetBridge. The proto messages were already in `xiaomi.pb.swift`. **It does not touch firmware** (`TYPE_FIRMWARE=32`) — brick risk.

| Layer | type | subtypes | Service |
|---|---|---|---|
| Watch faces | 4 | list=0, set=1, delete=2, install=4 | `WatchfaceService` |
| Apps (RPK / quick apps) | 20 | list=0, install=1, installed=2, delete=3 | `AppInstallService` |
| Chunked upload | 22 | uploadStart=0 | `DataUploadService` |

**Install flow (identical for faces and apps, only the type tag changes):**
1. The app announces the file: faces `watchfaceInstallStart{id,size}`; apps `rpkInfo{id,versionCode,size}`.
2. The band replies with a status (faces `watchface.installStatus`; apps `rpk.rpkInstallStart.cmd`). `0` = accepted.
3. The app opens the upload: `CMD_UPLOAD_START{type, md5(file), size}` (type **16**=watchface, **64**=rpk).
4. The band replies `dataUploadAck{unknown2, resumePosition, chunkSize (default 2048)}` — supports resuming.
5. The app builds the envelope and transmits in chunks:
   ```
   envelope = [0x00][type][md5:16][size:u32 LE][file bytes from resumePosition]
   payload  = envelope + crc32(envelope):u32 LE
   chunk    = [totalParts:u16 LE][currentPart:u16 LE][slice of (chunkSize-4) bytes]
   ```
6. Watch face: when done, the app sends `set` (activate) + `list`. RPK app: the band sends `installed` (sub=2) and the app requests `list`.

> **Upload chunks go on the DATA channel (2) in plaintext** — `XiaomiSppPacket.buildDataChunk`, opCode PLAINTEXT (GadgetBridge: `CHANNEL_DATA → OPCODE_SEND_PLAINTEXT`). Unlike commands (PROTOBUF channel, AES-CTR): the envelope protects itself with md5 + crc32. `BandManager.sendDataChunk` does **pacing** against CoreBluetooth's `writeWithoutResponse` buffer via `peripheralIsReady(toSendWriteWithoutResponse:)`, otherwise a large upload overflows the buffer and loses frames.

> **File formats** (`InstallableFile`): watch face = binary, magic `0x5A 0xA5`, NUL-terminated numeric id at `0x28`, name at `0x68`. App = ZIP with `manifest.json` (`package`/`name`/`versionCode`), read by `MiniZip` (Foundation doesn't decompress ZIP entries on iOS) + inflate via the `Compression` framework (`COMPRESSION_ZLIB` = raw deflate).

> **To validate on hardware:** the exact channel of the chunks (DATA=2) and the pacing; and whether the Mi Band 10 accepts community faces (there may be a region/model lock). Import via document picker (Files), download by URL and share sheet (`onOpenURL` + `CFBundleDocumentTypes`).

### Background BLE on iOS

- `bluetooth-central` configured via `INFOPLIST_KEY_UIBackgroundModes = "bluetooth-central"` in `project.pbxproj` (not in a separate Info.plist — see "Known Pitfalls")
- `CBCentralManager` instantiated with `CBCentralManagerOptionRestoreIdentifierKey: "com.myband.central"` for state restoration
- Implement `centralManager(_:willRestoreState:)` to reconnect after the app is suspended
- Automatic reconnect via `connect(_:options:)` on receiving `didDisconnectPeripheral`, with exponential backoff (max. 5 attempts)

### Sync orchestration

`BackgroundSyncManager` is the **single entry point** of every sync (foreground or background). All triggers go through `syncNow(disconnectWhenDone:)`, which **coalesces** concurrent calls into a single in-flight `Task` — the Dashboard button, App Intent/Siri, BGTask and the BLE wake-up never fire two fetches at the same time. `disconnectWhenDone`: `nil` = only disconnect if the sync itself opened the link (a live foreground link stays); `true`/`false` forces (background wake-ups pass `true` to release the radio). `syncToHealth()`/`syncWorkoutFiles()` also have a re-entrancy guard (`!isSyncing`), serialized by `@MainActor` (guard + set before the first `await`).

Background triggers, in order of frequency/reliability:
1. **BLE wake-up (state restoration).** When the band comes back into range, CoreBluetooth relaunches the app; on authenticating, `BandSyncer.onAuthenticated` calls `syncOnBackgroundWakeIfStale()` — it only runs if in the background, throttled by `lastHealthSync` (15 min) and disconnecting at the end. This is the most reliable path (the BLE event is what wakes the app).
2. **`BGAppRefreshTask`** (`com.myband.refresh`) — light, scheduled frequently by the OS.
3. **`BGProcessingTask`** (`com.myband.sync`) — heavy/deferrable, usually runs while charging.

Both BGTasks are registered in `register()` (from `AppDelegate.didFinishLaunching` — the only window allowed by `BGTaskScheduler.register`) and rescheduled in `scheduleNext()` when going to the background (`scenePhase`). `Info.plist`: both ids in `BGTaskSchedulerPermittedIdentifiers` and the `fetch` (app-refresh) + `processing` background modes. On a cold launch triggered by a task, `awaitDependencies()` waits for the UI's `configure()`. The `expirationHandler` is installed **inside the `register` closure itself**, on the scheduler's queue, before the hop to the main actor — that hop once took 6 s in a freshly resumed app, and a task that expires without a handler is completed as a failure by iOS (which then schedules fewer). `finish(_:success:)` guarantees a single `setTaskCompleted`, whether it comes from the sync or from the expiration.

> The end of a workout has its own path (`handleWorkoutFinished`): it waits ~8 s for the file flush and fetches the named file-ids via `syncWorkoutFiles`, without going through `syncNow` (but protected by the same `!isSyncing` guard).

---

## AuthKey Extraction

The onboarding (`UI/Setup/SetupView.swift`) is a state machine of steps: `intro → choose → (xiaomi | key) → connection`. The `choose` screen offers both methods; both end up producing a 32-char hex that goes through `AuthKeyStore.saveHex` (validation + Keychain) and proceeds to `ConnectingView` (same `onConnect` in `RootView`).

### Method 1 — Manual Input (`SetupView.keyEntry`)
- The user obtains the AuthKey via external tools (GadgetBridge export, `token_extractor/`, Xiaomi Cloud) and pastes it into the field
- The app shows a 32-character hex field with validation
- Save to the Keychain with `kSecAttrAccessibleAfterFirstUnlock` (accessible in the background)
- It is the **fallback** for every failure of method 2 ("Enter AuthKey manually" link at each step)

### Method 2 — Xiaomi Cloud via username/password (`Auth/XiaomiCloudAuth.swift`, `UI/Setup/XiaomiLoginView.swift`)
Ports `PasswordXiaomiCloudConnector` from `token_extractor/token_extractor.py` — login with the Xiaomi account username and password, typed on this screen. It replaced the earlier QR flow (`QrCodeXiaomiCloudConnector`): a **conscious trade-off** — the QR version never exposed the password to the app (authentication entirely on Xiaomi's side), but depended on a second device or a fragile long-poll while the user left and returned to the app. Username+password is more direct and depends on nothing else, at the cost of the password passing through My Band's process memory — never persisted, never logged, only used to build the MD5 hash and the encrypted body of the login POST. Flow (mirrors the Python steps):

1. `GET serviceLogin` → `_sign` (rarely a ready session with `ssecurity` already comes back)
2. `POST serviceLoginAuth2` with `user` + `hash=MD5(password)` + `_sign` → `ssecurity`, `userId`, `location`
   - If `captchaUrl` comes back: shows the image, the user types the text, the POST is resent with `captCode`
   - If `notificationUrl` comes back: it's email 2FA — follows the chain `identity/list` → `sendEmailTicket` → the user types the received code → `verifyEmail` → `identity/result/check` → `Auth2/end` (reads `ssecurity` from the non-standard `extension-pragma` header, which is why these calls use a delegate that **does not follow redirects** — it's the only way to read the headers of the redirect response itself) → redirect to `sts.api.io.mi.com/sts`, which finally sets the `serviceToken` cookie
3. If step 2 didn't already come with `serviceToken` (no-2FA flow): `GET location` → `serviceToken` cookie — this is the step that **confirms the login really happened**, before moving on to the device search
4. For each region (`cn, de, us, ru, tw, sg, in, i2`), **encrypted** calls: `get_homes` + `get_dev_cnt` → homes; `get_devices` → devices; the Mi Band 10 is `miwear.watch.*` with a numeric `did` (it doesn't contain `blt`) and already carries the AuthKey in the `token` field — it only falls back to `blt_get_beaconkey` for legacy BLE devices without an inline `token`
5. One band → auto-selects; several → the user chooses; the key goes into the same `onConnect`

- **Phase state machine** (`XiaomiCloudAuth.Phase`): `idle → enteringCredentials → authenticating → [awaitingCaptcha | awaiting2FA] → confirmingLogin → fetchingDevices → done`. Captcha and 2FA suspend the login `Task` on a `CheckedContinuation` held on the instance; `submitCaptcha`/`submit2FACode` (called by the UI) resolve it — there is no polling, it is step by step.
- **API crypto** (`Auth/XiaomiCloudCrypto.swift`, separate from the BLE `XiaomiCrypto`): RC4/ARC4 with pycryptodome's **1024-byte keystream discard**, SHA-1, SHA-256 and MD5 (CryptoKit `Insecure.MD5` — only for compatibility with the endpoint's legacy password hash, not a security choice of ours). `signedNonce = base64(SHA256(b64dec(ssecurity) || b64dec(nonce)))`; each param is `base64(RC4(key=b64dec(signedNonce)))`; signature `base64(SHA1("POST&path&k=v&...&signedNonce"))` — **key order preserved** and **`quote_plus`** encoding (a replica of `requests.urlencode`, otherwise `+`/`/`/`=` break the signature or the `_sign`/password hash, which also travel through the login query string). Path = everything after the first `"com"`, with `/app/` → `/`.
- **Ephemeral `URLSession`** with its own in-memory cookie jar — nothing from the login persists to disk.
- Debug logs (`[XiaomiCloud]`, DEBUG only) print status/cookies/token presence — **never** the values of username, password, `serviceToken` or beaconkey/token.
- **To validate (real account):** the Xiaomi Cloud endpoints are fragile and region/account dependent, and the email 2FA chain in particular chases several redirects and a non-standard header — ported faithfully from the reference, but without live validation yet (simple login, with captcha, and with 2FA).
- **Attention**: the token/beaconkey is the pairing secret — treated like the AuthKey (Keychain, never logged/persisted outside it).

---

## HealthKit

### Data Types to Write

| Mi Band data | HealthKit type |
|---|---|
| Sleep (start/end/phases) | `HKCategoryTypeIdentifier.sleepAnalysis` |
| Steps | `HKQuantityTypeIdentifier.stepCount` |
| Heart rate | `HKQuantityTypeIdentifier.heartRate` |
| SpO2 | `HKQuantityTypeIdentifier.oxygenSaturation` |
| Active calories | `HKQuantityTypeIdentifier.activeEnergyBurned` |
| Walking distance | `HKQuantityTypeIdentifier.distanceWalkingRunning` |
| Resting HR | `HKQuantityTypeIdentifier.restingHeartRate` |
| Body temperature (manual measurement) | `HKQuantityTypeIdentifier.bodyTemperature` |
| VO₂ max (workout) | `HKQuantityTypeIdentifier.vo2Max` |
| Cycling / swimming distance (workout) | `HKQuantityTypeIdentifier.distanceCycling` / `.distanceSwimming` |
| Strokes (swimming) | `HKQuantityTypeIdentifier.swimmingStrokeCount` |
| Workout | `HKObjectType.workoutType()` via `HKWorkoutBuilder` (mapped to `HKWorkoutActivityType`) |
| Workout route (GPS) | `HKSeriesType.workoutRoute()` via `HKWorkoutRouteBuilder` |
| Weight (BLE scale) | `HKQuantityTypeIdentifier.bodyMass` (+ `.bodyMassIndex` derived from `.height` read from Health) |
| Physical effort (METs/min: the band's active kcal ÷ weight from Health) | `HKQuantityTypeIdentifier.physicalEffort` |
| Workout effort, 1–10 scale (average HR ÷ age-based max HR, Tanaka) | `.estimatedWorkoutEffortScore` (iOS 18+, via `relateWorkoutEffortSample`) |
| Heart-rate recovery (peak at the end of the workout − HR/min at end+60 s) | `HKQuantityTypeIdentifier.heartRateRecoveryOneMinute` |
| Speed during a workout (V2 GPS points, m/s) | `.runningSpeed` / `.cyclingSpeed` |
| Average running stride (distance ÷ steps) | `HKQuantityTypeIdentifier.runningStrideLength` |
| Rowing distance (iOS 18+; before that it fell back to walking distance) | `HKQuantityTypeIdentifier.distanceRowing` |

> **`appleStandHour` is NOT writable.** `HKCategoryTypeIdentifier.appleStandHour` is reserved (the system derives it from the Apple Watch). Including it in `requestAuthorization(toShare:)` throws `NSInvalidArgumentException`. The band's standing-hours mask stays local only — there is no "stand hour" type writable by third-party apps. The same goes for `appleExerciseTime`, `appleMoveTime`, `appleStandTime` (activity rings) and `walkingHeartRateAverage` — all read-only for third parties, no workaround.
>
> **Heart-rate recovery runs on the daily-file path, not in `writeWorkouts`.** The workout's 1 Hz series ends exactly at the end of the workout (count == duration), so the end+60 s reading only arrives in the next daily detail file. `writeHeartRateRecoveries` queries the app's **own** recent workouts in Health (regardless of which sync wrote the workout), matches the peak of the last minute (1 Hz series, `HKStatisticsQuery` discreteMax) with the per-minute reading closest to end+60 s (±30 s) and writes the delta. Best-effort in `BandSyncer` — it doesn't block the file ACKs.
>
> **Mobility remains exclusive to the iPhone.** `walkingSpeed`/`walkingStepLength` are writable, but they would feed the Mobility metrics that the reconciliation deliberately preserves — that is why the speed series is only written for running/cycling (`speedType(_:)` returns nil for walking/hiking) and the stride uses `runningStrideLength`, not `walkingStepLength`.

### Permissions (Info.plist)
```
NSHealthUpdateUsageDescription
NSHealthShareUsageDescription
```

### Deduplication
- Before writing, query existing samples in the period to avoid duplicates
- Use `HKQueryAnchor` persisted in SwiftData for incremental syncs

> **Reconciliation between sources (steps / distance / active energy).** The iPhone records these same quantities, and Apple Health **sums** every third-party source on top of the iPhone — the private iPhone+Watch dedup does not extend to third parties and there is **no API** to change the aggregation or register the band as a trusted source. Writing the band's raw total doubles the count (a 200 walk → 400). Solution (`HealthKitManager.writeReconciledActivity`): write only the band's **surplus** over the iPhone, per minute — `delta = max(0, band − iPhone)`, with the iPhone sum obtained via `HKStatisticsCollectionQuery` in 1-min buckets and predicate `source ≠ this app`. The per-minute total becomes `max(band, iPhone)`: no double-counting, **iPhone Mobility preserved** (Walking Asymmetry/Step Length/Speed/Steadiness — the band produces none of this and they require Fitness Tracking to be **on**), and steps without the phone still captured. It works because the band reports **already-completed** minutes: when the minute syncs, the iPhone's pedometer has already finalized it, so the delta is stable and the re-sync (idempotent via sync-id) reproduces the same value — no need for an `HKObserverQuery` for the current day.
>
> **The official source of these three quantities is the daily detail file (per minute).** `writeDailySummary` no longer writes steps/energy (it would keep adding up); it only writes band-exclusive extremes (HR/SpO₂, resting HR). If the user **denies read access** in HealthKit, the iPhone sums come back empty and the band's full value is written (safe direction — band as the source). **SpO₂ stays out of the reconciliation** (the iPhone has no sensor) and remains raw per minute in `writeMinuteSamples`, granularity intact.

---

## BLE Scale (OKOK/Chipsea)

`BLE/Scale/` integrates an OKOK/Chipsea BLE scale, **independent of the band** (its own CoreBluetooth). Ports the weight paths of the [homeassistant-okokscale](https://github.com/rrooggiieerr/homeassistant-okokscale) integration (Apache-2.0).

- **`ScaleWeightParser`** — decodes the weight from the BLE advertisement's *manufacturer data* (`[companyId:2 LE][payload]`). **VC0** variant (validated on hardware, "Yoda1" scale): matched by the **low byte of the company id = `0xC0`** (mirrors the integration's `key & 0xFF == 0xC0`); 13-byte payload, weight in `bytes[0..1]` BE, `byte[6]` carries the unit (`(b>>3)&3`: 0=kg, 2=lb, 3=st:lb) and the **final bit** (`b&1`). Normalizes everything to kg.
- **`ScaleManager`** (`@Observable @MainActor NSObject`) — only **scans**, never connects. Writes one weigh-in at a time: any zero/non-final frame **re-arms** (`lastFinalWeight = nil`), and a new non-zero final frame counts as a new weigh-in (stepping on again at the same weight logs again). Writes via `HealthKitManager.writeBodyMass` (`bodyMass` + `bodyMassIndex` when there is a `height` in Health), sync-id by timestamp (idempotent).

> **The scale is broadcast-only.** Confirmed on hardware: it **does not accept a GATT connection** (every `connect` times out, even during the measurement) and **does not advertise a service UUID**. Consequences: (1) listening is **foreground-only** — a scan without a service filter doesn't work in the background on iOS (the band, with UUID-based state restoration, keeps working in the background normally); (2) **only the weight is recoverable**. The impedance **does not reach the phone** — the advertisement carries only the weight (bytes 2-3 are a constant `0x1388`, not impedance) and there is no GATT. The body-composition numbers in the OKOK app (fat %, lean mass, water…) are an **estimate from weight + profile**, not real bioimpedance: validated by observing that all metrics move **monotonically with weight** between two weigh-ins. That is why My Band writes only `bodyMass`/`bodyMassIndex` (measured data), not estimated body composition.

---

## App Intents and Shortcuts

> **Home Assistant was cut from the roadmap** (decision recorded only here, it never had code — see conversation/history). The direct REST integration this document once specified will not be built. In place of the triggers it would have offered (sleep detected, HR above threshold), the app exposes **state via App Intent** and leaves the automation entirely to the user's own Shortcuts Personal Automations — without the app needing to know anything about lights, scenes or third-party scripts.

### Available Intents

| Intent | Parameters | Return |
|---|---|---|
| `SyncBandIntent` | — | Sync status |
| `GetSleepStateIntent` | — | `Bool` (asleep?) + dialog with the age of the data |
| `CheckBandBatteryIntent` | `threshold: Int` (1–100, default 30) | `Int?` (level) + local notification **only** if below the threshold |
| `RunBandMiniAppIntent` | `appId: String` | (Future phase) |

> **`GetSleepStateIntent` is pull, not push.** The band has no "fell asleep"/"woke up" event (see "Band-initiated commands" above) — sleep is only known after the app syncs. The intent forces a sync (`BackgroundSyncManager.shared.syncNow()`, best-effort — failure isn't fatal) before answering, and considers the data "asleep" only if the last synced session ended less than 1h ago and its last phase is not `.awake`. The dialog always states the age of the data ("asleep, data from X min ago"), so a chained Personal Automation never silently acts on a stale state.

> **`CheckBandBatteryIntent` is silent by default.** Designed for a Personal Automation "when the iPhone's charger is connected": remember to put the band on the charger too. A shortcut that spoke on every run would become noise, so it has **no dialog** — it runs the full sync **holding the link** (`syncNow(disconnectWhenDone: false)`; with the default, the sync disconnected the link it had opened itself and the request below became dead code), requests a fresh reading while the link is open (`BandManager.refreshBattery` — the in-memory level may be stale on a long connection), waits for the responses (3 s cap, not a sleep) and only acts if `level < threshold` **and** the band isn't already on the charger, posting a local notification. The level also comes out as a return value, for anyone who wants to chain their own condition. Band out of range → answers with the last known level instead of failing the shortcut (and the whole automation); no reading at all → `nil`, without notifying. The radio is released at the end of the intent, and only if there was no live link before it.
>
> **The level is the same as iOS's Batteries widget.** There is no API to read the widget (it uses the private `BatteryCenter` framework), but the **same source** can be read: the standard GATT Battery Service (`0x180F` / `0x2A19`), which iOS queries on paired BLE accessories. `BandManager` discovers it together with `FE95` and, when it exists, `2A19` owns `batteryLevel`; the protobuf `CMD_BATTERY` is still requested because only it carries the charging state (`battery.state == 1`). Without `180F`, the level goes back to coming from the protobuf. **Reading and subscribing to `2A19` only after auth**: if the characteristic requires encryption, touching it on a link with no bond yet would make iOS raise the pairing sheet *before* the band's dialog, inverting the order of the two prompts that ADR 0003 relies on. Accepted consequence: without auth there is no GATT reading, even if the band exposes it.

### Siri Phrases (AppShortcutsProvider)
- "Sync my band in My Band"
- "I am sleeping in My Band"
- "Check if I am asleep in My Band"
- "Check band battery in My Band"

---

## UI / Design System

The UI is built from the **Claude Design** handoff (`My Band — Design System`, a bundle exported from claude.ai/design). Faithfully recreate in SwiftUI — copy the **visual result**, not the HTML/JSX structure of the prototypes.

> **No health-data visualization on its own screen** (see ADR 0001). The app shows sleep, HR, steps or SpO₂ on no screen — that is the role of Apple Health and the `GetSleepStateIntent` Shortcut. The Dashboard only shows connection state, sync freshness, battery and the sync button; there is no `SleepDetail`/hypnogram screen (nor is one planned).

**The maker's fixed principles:**
1. **Dark-mode first** — "I like night mode".
2. **Simple, direct, glanceable** — the app is a background *gateway*; the UI serves quick status and configuration, not screen time — taken to the extreme: not even the health data itself appears on screen.
3. **Native Apple** — SwiftUI, iOS 26+, Liquid Glass on chrome/status (see ADR 0001), faithful to the HIG.

**Visual foundations:**
- **Midnight palette** (OLED): base `#0A0B10`, cards `#14161F`, elevated surfaces `#1A1D27`. Elevation by *lightness + hairline* `rgba(255,255,255,.07)`, not shadow.
- **Single accent**: Aurora indigo `#7C7FFF` (interaction, selection, focus, glow of an active connection).
- **Health colors** mirror Apple Health: HR `#FF5C7A`, steps `#46E0A0`, SpO₂ `#5BC0F8`, energy `#FF9A4C`.
- **Sleep-phase ramp** dusk→deep-night: awake `#F6A052` → REM `#5BC0F8` → light `#8A8CFF` → deep `#4B45C7`.
- **Status**: ok/connected mint `#46E0A0`, connecting/warning amber `#F6C552`, disconnected/error pink `#FF5C6C`.
- **Type**: iOS scale, SF Pro on-device (Geist in the web kit). Large data numerals (48–64px), tabular. AuthKey and technical values in **mono**.
- **Continuous corners**: cards 16, sheets 20, hero/modal 28, round pills. **4-pt grid**, gutter 20, hit target ≥44.
- **Icons**: SF Symbols (the web kit uses Lucide as a substitute). Status always color + symbol, never color alone.

**Voice & copy (English):** sentence case, no emoji, addressing the user as "you", device = "the band". Calm, factual tone ("Synced 2 min ago", "42 samples in Apple Health"). No health data on screen — the number that appears is always status/sync, never a health metric. Technical honesty: AuthKey/BLE shown in mono, AuthKey masked by default.

**Screens (`ui_kits/app/`):** `Dashboard` (connection status, sync freshness, battery, sync — no health data, see ADR 0001), `Setup` (AuthKey + scan/connection), `Settings`. **There is no `SleepDetail`.** Connection status + sync freshness are first-class on every screen.

**Kit components** (`components/`): core (`Button`, `IconButton`, `StatusPill`, `Badge`), forms (`Switch`, `TextField`, `SegmentedControl`), data (`ListRow`, `Card`, `MetricTile`, `SectionHeader`, `SleepBar`). Each has a `.prompt.md` and a `.d.ts` describing props/variants.

---

## SwiftData — Main Models

```swift
@Model class BandDevice {
    var id: UUID
    var name: String
    var peripheralIdentifier: String  // CBPeripheral UUID
    var lastSyncDate: Date?
    // AuthKey stored IN THE KEYCHAIN, not here
}

@Model class SleepSession {
    var id: UUID
    var startDate: Date
    var endDate: Date
    var phases: [SleepPhase]          // Codable embedded
    var healthKitSynced: Bool
    var device: BandDevice?
}

@Model class ActivityDay {
    var date: DateComponents           // year/month/day only
    var steps: Int
    var calories: Double
    var distanceMeters: Double
    var healthKitSynced: Bool
}
```

---

## Changelog

The project follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

**Every notable change must be recorded in `CHANGELOG.md` before the commit**, in the categories:

| Category | When to use |
|---|---|
| `Added` | New feature |
| `Changed` | Change to existing functionality |
| `Deprecated` | Functionality to be removed in a future version |
| `Removed` | Removed functionality |
| `Fixed` | Bug fix |
| `Security` | Vulnerability fix |

Entries pending release go under `## [Unreleased]`. When releasing a version, move them to `## [X.Y.Z] - YYYY-MM-DD`.

Current version: **1.2.0** — see `CHANGELOG.md` for the full history. Next phase, everything **to be validated on hardware**:

1. Patient pairing on a genuinely **new** pairing (ADR 0003 + addendum) — the 180 s window spanning the bonding link drop, `PairingStage` advancing to `.phone`, whether the iOS sheet really produces an observable `CBATTError.insufficientAuthentication` (or comes up without rejecting any write), and the session restart the band does after the accept. The 2026-09-05 logs came from an already-paired band and from attempts that failed, not from a successful accept.
2. The full sync after the session-restart fix — if the band reopens the session and the app re-derives the keys, `FETCH_TODAY` should finally get a response instead of only ACKs. In the console, a sync on a new connection should show `FETCH_TODAY cut short by a band session restart — re-sending after re-auth` followed by `FETCH_TODAY → N file ID(s)`, and for each night a `Sleep file …` line.
3. The Xiaomi Cloud username/password login with captcha and 2FA (ADR 0002; simple login already confirmed).
4. The `GetSleepStateIntent`.
5. The `CheckBandBatteryIntent` — in particular the on-demand `CMD_BATTERY` outside the post-auth init (the response arrives in the same `handleSystemCommand`, but it has never been exercised with a link that has already been open for a while). And whether the Mi Band 10 exposes the `0x180F` Battery Service to apps (the `Services:` line of the connection log answers), whether `2A19` reads without error post-auth and whether the number matches the Batteries widget — the log prints both (`via GATT 2A19` / `via protobuf — keeping GATT`).

Home Assistant was cut from the roadmap; the UI remains without health-data visualization by decision (see ADR 0001).

---

## Code Conventions

- **No obvious comments** — name things well, don't comment what is evident
- **Comment only non-obvious WHYs**: BLE protocol invariants, hardware workarounds
- **@Observable** instead of ObservableObject (Swift 5.9+)
- **async/await** for all BLE and network operations — no nested callbacks
- **`BandManager` is `@Observable @MainActor NSObject`** — not a pure Swift `actor`. CBCentralManagerDelegate requires NSObject; configuring `CBCentralManager` with `queue: .main` makes the callbacks arrive on the main thread, aligned with `@MainActor` without extra bridging
- **No force-unwrap** — handle errors explicitly
- Minimum iOS 17 / macOS 14 — use modern APIs without compatibility shims

---

## Known Pitfalls

### Xcode 16 — PBXFileSystemSynchronizedRootGroup
The project uses automatic folder synchronization (`PBXFileSystemSynchronizedRootGroup`): **any file created inside `My Band/My Band/` is automatically included in the build**.
- **Do not create an `Info.plist` inside `My Band/My Band/`** — it will cause "Multiple commands produce Info.plist".
- The project's Info.plist lives at **`$(SRCROOT)/Info.plist`** (project root, outside the synchronized folder). `GENERATE_INFOPLIST_FILE = NO` and `INFOPLIST_FILE = "Info.plist"` in the pbxproj.
- When creating subfolders (`BLE/`, `Auth/`, etc.), use `XcodeMakeDir` from the Xcode MCP so they are registered correctly in the project.

### INFOPLIST_KEY_UIBackgroundModes generates `<string>`, not `<array>`
`INFOPLIST_KEY_UIBackgroundModes = "bluetooth-central"` with `GENERATE_INFOPLIST_FILE = YES` generates the wrong type in the plist — `<string>` instead of `<array>`. `CBCentralManager` validates the type at runtime and throws `NSInternalInconsistencyException: State restoration of CBCentralManager is only allowed for applications that have specified the "bluetooth-central" background mode`. **Always use the manual Info.plist** with `<array><string>bluetooth-central</string></array>`.

### CBCentralManagerOptionRestoreIdentifierKey on the Simulator
The iOS Simulator does not support CoreBluetooth state restoration. Wrap it in `#if !targetEnvironment(simulator)` to avoid a crash on the simulator.

### CommonCrypto — Swift exclusive access
When using `Data.withUnsafeMutableBytes`, capture `data.count` in a local variable **before** the closure to avoid the exclusivity error:
```swift
let capacity = output.count          // capture BEFORE
output.withUnsafeMutableBytes { buf in
    CCCrypt(..., buf.baseAddress, capacity, ...)  // use the variable
}
```

### BandManager.startScan() — Race condition with CBCentralManager
`CBCentralManager` is initialized asynchronously. If `startScan()` is called (e.g. from `.onAppear`) before `centralManagerDidUpdateState(.poweredOn)` fires, the `central.state == .poweredOn` guard fails silently and the scan never starts.
Implemented solution: a `pendingScan` flag in `BandManager`. If BT isn't ready, `pendingScan = true`; `centralManagerDidUpdateState` consumes the flag and calls `startScan()` when BT becomes `poweredOn`.

### ModelContainer — fatalError after a watchdog kill
Watchdog kills (app in the background exceeding handler time) can corrupt the SwiftData SQLite file. On the next launch, `ModelContainer(for:configurations:)` fails and the original version called `fatalError` immediately, showing up as "Message from debugger: killed" with no useful log.
Implemented solution: if `ModelContainer` fails, delete the `.store`, `.store-shm` and `.store-wal` files and try again before calling `fatalError`. Loss of local data is acceptable in development; in production replace it with a migration.

### dyld AVPlayerView — Debug error on the Mac
When running the app on the Mac (iOS app via the `/System/iOSSupport/` layer), Xcode's debugger loads `libViewDebuggerSupport.dylib` from the MacOSX platform, which tries to resolve `_OBJC_CLASS_$_AVPlayerView` in the iOS AVKit where the class doesn't exist. It results in "Message from debugger: killed" with no app log.
**It is not an app bug.** Solution: run on the physical iPhone. For BLE, the physical iPhone is mandatory anyway — the Simulator and the Mac don't connect to the Mi Band.

### HealthKit — Reserved Apple Watch Ring Types
HealthKit **expressly forbids** third-party apps from requesting share permission (`toShare`) for the proprietary Apple Watch activity-ring identifiers:
- `HKCategoryTypeIdentifierAppleStandHour`
- `HKQuantityTypeIdentifierAppleExerciseTime`
- `HKQuantityTypeIdentifierAppleMoveTime`

Passing any of these types to `requestAuthorization(toShare:read:)` immediately throws `NSInvalidArgumentException: Authorization to share the following types is disallowed: ...`. Exercise time must be accounted for by the system from the recorded `HKWorkout`s, never written directly.

### Sanitizing Cumulative Mi Band Sleep Packets
The Mi Band 10 sends sleep stages (type 17 packets) cumulatively. If multiple packets are processed without temporal deduplication/merging (`sanitizeStages`), the sleep minutes are added repeatedly in HealthKit, inflating the sessions. In addition, raw Xiaomi timestamps in `firstRecordTime` require unsigned decoding (`u32`) and epoch validation to avoid the years 1928 and 1970.

---

## Build and Tests

```bash
# Build (requires Xcode 16+)
xcodebuild -scheme "My Band" -destination "platform=iOS Simulator,name=iPhone 15 Pro"

# Unit tests (protocol parsers, HealthKit conversion)
xcodebuild test -scheme "My Band" -destination "platform=iOS Simulator,name=iPhone 15 Pro"
```

- Test BLE protocol logic with real captured data (fixtures in `Tests/Fixtures/`)
- Do not mock `CBCentralManager` in unit tests — test only parsing/conversion layers
- BLE integration tests only on a physical device

---

## Agent skills

### Issue tracker

Issues and specs are tracked as GitHub Issues in `matheusdanoite/my-band`, using the `gh` CLI. See `docs/agents/issue-tracker.md`.

### Triage labels

Default label vocabulary (`needs-triage`, `needs-info`, `ready-for-agent`, `ready-for-human`, `wontfix`). See `docs/agents/triage-labels.md`.

### Domain docs

Single-context: `CONTEXT.md` + `docs/adr/` at the repo root. See `docs/agents/domain.md`.

---

## References

- `AstroBox-NG-main/` — BLE protocol reference for wearables and protobuf structure
- [GadgetBridge Mi Band 8/9/10 source](https://codeberg.org/Freeyourgadget/Gadgetbridge) — reference implementation of the protocol
- [OpenWRT Mi Band community docs](https://github.com/argrento/huami-token) — AuthKey extraction via Xiaomi Cloud
- HealthKit Developer Documentation — Apple
- App Intents Developer Documentation — Apple
