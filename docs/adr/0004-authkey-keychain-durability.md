---
status: accepted
---

# The AuthKey must survive updates, renames and relaunches

The AuthKey is the band's pairing secret and the only state the app **cannot** rebuild on its own: losing it means sending the user back through the whole onboarding (extraction via Xiaomi Cloud or manually copying the 32 hex characters). The `BandDevice` in SwiftData is disposable — the band is rediscovered by scanning. The key is not.

The original `AuthKeyStore` treated the Keychain as a simple dictionary, and three discreet details could erase or hide the key:

1. **The item was indexed by the bundle id read at runtime** (`Bundle.main.bundleIdentifier`). Renaming the bundle or the target would make the app present itself as unpaired, with the key still intact in the Keychain under the old name.
2. **`save` did `delete` + `add`.** If the `add` failed, the key was already gone — a transient Keychain error turned into a re-pairing.
3. **`isStored` was `(try? load()) != nil`.** That collapses "doesn't exist" and "can't be read right now" into the same answer. On a background relaunch — CoreBluetooth state restoration when the band comes back into range — **before the first unlock after boot**, a `kSecAttrAccessibleAfterFirstUnlock` item exists but is unreadable. The app answered "no key" and routed an already-paired user back to setup.

## Decision

- **Fixed `service`** (`com.myband.authkey`), deliberately decoupled from `Bundle.main`, with automatic migration of the legacy (bundle id) item on first read.
- **`save` updates in place** (`SecItemUpdate`, with `SecItemAdd` only when the item doesn't exist).
- **Item pinned as non-synchronizable** (`kSecAttrSynchronizable: false`, also in the query), so that no iCloud Keychain entry can shadow or replace the local one.
- **`AuthKeyError.locked` kept separate from `.notFound`**: `isStored` answers `true` for a locked Keychain. The safe direction — the app behaves as paired and the real read tries again later.
- `kSecAttrAccessibleAfterFirstUnlock` stays, and stays mandatory: without it background sync cannot read the key.

## Consequences

- **The fixed `service` is now a compatibility constant**, not a detail. Changing it without a migration is the same class of bug it fixes.
- **There is no `kSecAttrAccessGroup`.** The key is still lost if the app is re-signed with a different Team ID. A multi-target split (e.g. an extension that needs the key) requires choosing an explicit access group and migrating again.
- **A genuinely broken Keychain now shows up as a connection error**, not as "set up the key". This is the trade-off of point 3 and it is the right behavior: sending a paired user to setup is data loss disguised as a screen.
