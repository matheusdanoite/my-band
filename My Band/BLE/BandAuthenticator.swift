import Foundation
import CommonCrypto
import SwiftProtobuf

// MARK: - BandAuthenticator
//
// Mi Band 10 BLE V2 authentication protocol (confirmed via GadgetBridge XiaomiAuthService.java).
//
// Flow:
//  1. Phone generates 16-byte nonce
//  2. Send CMD_NONCE (type=1, sub=26) with Command { auth { phoneNonce { nonce } } }
//  3. Band responds: Command { auth { watchNonce { nonce(16), hmac(32) } } }
//       hmac = HMAC-SHA256(key=decryptionKey, data=watchNonce||phoneNonce)
//  4. Compute session keys:
//       prk = HMAC-SHA256(key=phoneNonce||watchNonce, message=secretKey)
//       [dec_key(16) | enc_key(16) | dec_nonce(4) | enc_nonce(4)] = HKDF-expand(prk, "miwear-auth", 64)
//  5. Verify band HMAC using decryptionKey
//  6. Send CMD_AUTH (type=1, sub=27): Command { auth { authStep3 { encryptedNonces, encryptedDeviceInfo } } }
//       encryptedNonces     = HMAC-SHA256(key=encryptionKey, data=phoneNonce||watchNonce)
//       encryptedDeviceInfo = AES-128-CCM(key=encryptionKey, nonce=[encryptionNonce(4)||zeros(4)||0(4)], AuthDeviceInfo)
//  7. Band responds: Command { type=1, sub=27 } — auth success, switch to encrypted comms

enum BandAuthenticator {

    // MARK: - Step 1: Random phone nonce

    static func phoneNonce() -> Data {
        var nonce = Data(count: 16)
        nonce.withUnsafeMutableBytes { _ = SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }
        return nonce
    }

    // MARK: - Step 2: Build CMD_NONCE packet
    //
    // Sends as plaintext DATA packet on the PROTOBUF channel (Authentication mode).

    static func noncePacket(phoneNonce: Data, seqNum: UInt8) -> Data {
        let protoBytes = XiaomiProto.phoneNonceCommand(nonce: phoneNonce)
        return XiaomiSppPacket.buildAuthCommand(protoBytes: protoBytes, seqNum: seqNum)
    }

    // MARK: - Step 3: Parse band WatchNonce response
    //
    // The response is a DATA packet (PLAINTEXT, channel=PROTOBUF) containing a proto Command:
    //   Command { type=1, subtype=26, auth { watchNonce { nonce(16), hmac(32) } } }

    struct WatchNonceResponse {
        let watchNonce: Data   // 16 bytes
        let bandHMAC:   Data   // 32 bytes
    }

    static func parseWatchNonce(from protoBytes: Data) -> WatchNonceResponse? {
        guard let cmd = XiaomiProto.parseCommand(protoBytes),
              cmd.hasAuth else { return nil }
        let wn = cmd.auth.watchNonce
        guard wn.nonce.count == 16, wn.hmac.count == 32 else { return nil }
        return WatchNonceResponse(watchNonce: wn.nonce, bandHMAC: wn.hmac)
    }

    // MARK: - Step 4: Derive session keys (from phone nonce, watch nonce, secret key)

    static func deriveKeys(
        phoneNonce: Data,
        watchNonce: Data,
        secretKey:  Data
    ) -> XiaomiCrypto.SessionKeys {
        XiaomiCrypto.deriveSessionKeys(
            phoneNonce: phoneNonce,
            watchNonce: watchNonce,
            secretKey:  secretKey
        )
    }

    // MARK: - Step 5: Verify band HMAC
    //
    // expected = HMAC-SHA256(key=decryptionKey, data=watchNonce||phoneNonce)
    // Note: GadgetBridge verifies against decryptionKey (derived key), NOT the raw secretKey.

    static func verifyBandHMAC(
        bandHMAC:       Data,
        phoneNonce:     Data,
        watchNonce:     Data,
        sessionKeys:    XiaomiCrypto.SessionKeys
    ) -> Bool {
        let expected = XiaomiCrypto.hmacSHA256(
            message: watchNonce + phoneNonce,
            key:     sessionKeys.decryptionKey
        )
        return expected == bandHMAC
    }

    // MARK: - Step 6: Build CMD_AUTH packet
    //
    // Sends as plaintext DATA packet (auth not yet established at this point).
    //   encryptedNonces    = HMAC-SHA256(key=encryptionKey, data=phoneNonce||watchNonce)
    //   encryptedDeviceInfo = AES-CCM(key=encKey, nonce=[encNonce(4)||0(4)||0(4)], AuthDeviceInfo)

    static func authPacket(
        phoneNonce:  Data,
        watchNonce:  Data,
        sessionKeys: XiaomiCrypto.SessionKeys,
        seqNum:      UInt8
    ) throws -> Data {
        // encryptedNonces: HMAC-SHA256(encryptionKey, phoneNonce||watchNonce) — NOT encrypted despite name
        let encryptedNonces = XiaomiCrypto.hmacSHA256(
            message: phoneNonce + watchNonce,
            key:     sessionKeys.encryptionKey
        )

        // encryptedDeviceInfo: AES-CCM with nonce=[encryptionNonce(4) || zeros(4) || counter=0(4 LE)]
        let ccmNonce: Data = {
            var n = Data()
            n.append(sessionKeys.encryptionNonce)   // 4 bytes
            n.append(contentsOf: [UInt8](repeating: 0, count: 4))  // zeros
            n.append(contentsOf: [UInt8](repeating: 0, count: 4))  // counter = 0, LE
            return n
        }()
        let deviceInfoProto    = XiaomiProto.authDeviceInfo()
        let encryptedDeviceInfo = try XiaomiCrypto.aesCCMEncrypt(
            key:       sessionKeys.encryptionKey,
            nonce:     ccmNonce,
            plaintext: deviceInfoProto
        )

        let protoBytes = XiaomiProto.authStep3Command(
            encryptedNonces:     encryptedNonces,
            encryptedDeviceInfo: encryptedDeviceInfo
        )
        return XiaomiSppPacket.buildAuthCommand(protoBytes: protoBytes, seqNum: seqNum)
    }
}

// MARK: - Auth errors

enum AuthError: LocalizedError {
    case noAuthKey
    case noCharacteristics
    case unexpectedPayload(Int)
    case badHMAC
    case timeout
    case linkDropped
    case retrying
    case wrongAuthKey
    case pairingNotConfirmed
    case staleBond

    var errorDescription: String? {
        switch self {
        case .noAuthKey:                  return "AuthKey not found in the Keychain."
        case .noCharacteristics:          return "BLE characteristics not discovered yet."
        case .unexpectedPayload(let n):   return "Unexpected response from the band: \(n) bytes."
        case .badHMAC:                    return "Invalid HMAC from the band — wrong AuthKey."
        case .timeout:                    return "Timed out during authentication."
        case .linkDropped:                return "The band closed the connection during pairing."
        case .retrying:                   return "Redoing the handshake."
        case .wrongAuthKey:               return "Incorrect AuthKey. Check the key."
        case .pairingNotConfirmed:        return "Pairing was not confirmed in time. Tap connect to try again."
        case .staleBond:                  return "The band has forgotten this iPhone. Open Settings › Bluetooth, tap the (i) next to the band, choose \"Forget This Device\", and connect again."
        }
    }
}
