---
status: accepted
---

# The handshake waits for the band and the user, instead of retrying

Until 2026-09-05 the Mi Band 10 handshake was driven by the app: any watch-nonce that failed the HMAC check meant "wrong AuthKey", and the reaction was to drop the link and reconnect (`retryAuthAfterReconnect`, `maxAuthRetries = 4`). The premise came from the first hardware test (2026-06-19), where the first nonce did fail and a clean reconnection authenticated.

The 2026-09-05 hardware logs showed the premise was too narrow. A nonce that doesn't verify has at least four causes, and only one of them is a wrong key:

1. **The band is still waiting for the user.** On first pairing it sends `auth sub=16` and only emits a verifiable nonce after the user accepts on the band **and** confirms the iOS Bluetooth pairing sheet. Before that it signs with a bond that doesn't exist.
2. **The nonce arrived late.** After our `CMD_AUTH`, the band re-emits a nonce of its own. Verifying it against the already-superseded phone-nonce always fails — but it confirms the original handshake anyway.
3. **Nonce race.** A nonce that was already in the air when our `CMD_NONCE` went out was signed against a phone-nonce it hasn't seen yet.
4. **The AuthKey really is wrong.**

Dropping the link in cases 1–3 is actively destructive: in case 1 it dismisses the very prompt we are waiting for, and in case 2 it kills a handshake one packet away from success (the same late nonce, when it arrived after `sub=27`, was harmless — both cases appear in the same log).

## Decision

The app now keeps pace with the band and the user, not the other way around:

- `sub=16` enters `.awaitingPairingConfirmation`, with a 120 s watchdog window. HMAC mismatches during that wait are logged and ignored — the link stays up, and the UI tells the user to accept on both sides.
- Nonces received with `CMD_AUTH` in flight are ignored; `sub=27` decides.
- Outside pairing, up to 2 mismatches per nonce exchange are tolerated before escalating to a reconnection.
- A `session-config-accept` received in `.connected` redoes the handshake instead of being ignored (see the next section).
- The retry teardown now has an increasing delay (1–4 s) instead of reconnecting immediately.

### Following GadgetBridge on session restart

`XiaomiBleProtocolV2.processPacket` calls `startEncryptedHandshake()` on **every** session-config packet, regardless of state. That looked careless and the app had an idempotency guard — but the band uses that packet to open a new session (resets the sequence counter, new nonce, new `sub=27`), and when it does so the old keys die on its side. Ignoring the packet left the app encrypting with dead keys: the band ACKed the transport frame and silently discarded the command, and the sync hung until the timeout with the link looking healthy.

We now follow GadgetBridge, with **one deliberate deviation**: a repeat that arrives while the handshake is still in flight (`.authenticating`) stays ignored. This protects against the 005F failure (the same accept delivered twice, microseconds apart, triggered two `CMD_NONCE`s with different phone-nonces and the band answered neither). The root cause of that bug has since been fixed — 005F is no longer subscribed for notify — so the guard is belt-and-braces, and it is the first place to look if the handshake diverges from GadgetBridge again.

## Consequences

- **A wrong AuthKey takes longer to surface.** It used to fail in seconds; now it has to exhaust 2 mismatches per nonce exchange plus 4 retries with increasing delay, or the 120 s pairing window. This is the price of not confusing "wait for the user" with "wrong key", and the final error path is still `AuthError.badHMAC`.
- **Session restart is bounded** (`maxBandSessionRestarts = 3` per connection). A band that restarts in a loop becomes noisy logs, not a re-handshake loop.
- **There is now a real auth watchdog** (20 s, 120 s while pairing). Before, `AuthError.timeout` only came out of a disconnection — "Timed out" in practice meant "the link dropped" (now `AuthError.linkDropped`), and a band that went silent hung indefinitely.
- **`.awaitingPairingConfirmation` is a first-class UI state**, not an internal detail: the user needs to know the ball is in their court.

None of this was exercised on a genuinely fresh pairing — the logs came from an already-paired band and from attempts that failed. The 120 s window and the post-accept session-restart path remain **to be validated on hardware**.

## Addendum (2026-09-09) — the wait is a window, not a connection state

The decision above treats the wait as a state of the live connection. Reviewing the real flow, that doesn't cover the shape of the problem: **the initial pairing asks for two confirmations, on different screens, and the link doesn't survive intact between them.** The band raises its own dialog; only after that does iOS raise the Bluetooth pairing sheet — and to establish the bond iOS **drops the connection**. A per-connection state dies exactly there, in the middle of the sequence, with the user still sitting in front of a prompt.

The mismatch between the two sides produced four wrong endings, all with the same UI signature (the screen looks stuck and then blames the key):

1. `resetState` cleared `awaitingPairingConfirmation` on the bonding disconnect; the reconnection came back with a 20 s watchdog and normal tolerance, with the band's dialog still lit.
2. When `sub=16` came **with** a parseable nonce, `beginPairingConfirmationWait` was never called — two mismatches later the link dropped, dismissing the dialog.
3. `beginPairingConfirmationWait` returned early on repeats, so the `sub=16` re-emitted every ~6 s extended nothing and the 120 s watchdog expired underneath a band that was still asking.
4. `didWriteValueFor` called `failAuth` on `CBATTError.insufficientAuthentication` — that is, it killed the handshake **the instant** iOS raised the sheet, since that error is iOS's way of saying "I'm going to ask for pairing".

### Decision

The wait becomes a **180 s deadline that spans connections** (`pairingDeadline`), not a state of the current connection:

- It survives the bonding teardown. `resetState` clears only the per-connection flag; `startNonceExchange` restores the patient posture if the window is still open.
- It is **extended** by any evidence that the human is still mid-flow (repeated `sub=16`, pre-bond nonce, ATT security error).
- An HMAC mismatch on a band we have **never** authenticated against (`everAuthenticated`, persisted) starts the wait instead of counting as a wrong key — before the bond, the band has no way to sign a verifiable nonce.
- Inside the window, the `retryAuthAfterReconnect` budget is **not spent** and the watchdog re-arms; only the window's expiry fails, with `AuthError.pairingNotConfirmed` (actionable) instead of `badHMAC` ("Incorrect AuthKey").
- `CBATTError.insufficientAuthentication` stops being a failure and becomes the signal that the second prompt is with the user.

`PairingStage` (`.band` → `.phone`, **only advances**) exists so the UI can say where to look: the connection screen shows the two steps as a checklist with the active one highlighted and the time remaining. The stage is inferred — from `sub=16`, from the ATT error, and (heuristically) from a link drop during the wait — and **never** decides protocol logic, only copy.

`CBError.peerRemovedPairingInformation` got its own handling: the band forgot a bond the iPhone still keeps, and no reconnection fixes that — `AuthError.staleBond` tells the user to forget the device in Settings › Bluetooth. `CBError.encryptionTimedOut` (sheet dismissed or expired) keeps the window open.

### Consequences

- **A wrong AuthKey takes even longer to surface on a new device** — the 180 s window has to expire before any escalation. On an already-paired device (`everAuthenticated`) nothing changes: a mismatch escalates as before.
- **`everAuthenticated` is new state in `UserDefaults`**, keyed by the `CBPeripheral` UUID. Deleting the app zeroes it, which only costs one extra waiting window on a reconnection.
- **Advancing to `.phone` on a clean drop is a heuristic.** We assume a disconnection during the wait means "the band was accepted, iOS is doing the bond". If wrong, the consequence is premature copy, not a lost handshake.
- Everything remains **to be validated on hardware** — including, now, whether the iOS sheet actually produces an observable `insufficientAuthentication` in this flow, or whether it appears without any write of ours being rejected.
