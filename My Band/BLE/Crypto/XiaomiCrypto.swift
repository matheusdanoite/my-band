import Foundation
import CommonCrypto

// MARK: - XiaomiCrypto
//
// Cryptographic primitives for the Mi Band 10 BLE V2 protocol.
// All operations use CommonCrypto — zero external dependencies.
//
// Auth crypto (from GadgetBridge XiaomiAuthService.java):
//   PRK derivation:   HMAC-SHA256(key=phoneNonce||watchNonce, data=secretKey)   ← key/data order matters!
//   HKDF-expand:      T(n) = HMAC-SHA256(PRK, T(n-1) || "miwear-auth" || n)
//   Post-auth encrypt (encryptV2): AES-CTR(key=encryptionKey, IV=encryptionKey, data)
//   Post-auth decrypt (decryptV2): AES-CTR(key=decryptionKey, IV=decryptionKey, data)
//   Auth step 3 encrypt (encrypt):  AES-128-CCM, 4-byte MAC, 12-byte nonce, no AAD

enum XiaomiCrypto {

    // MARK: - HMAC-SHA256

    static func hmacSHA256(message: Data, key: Data) -> Data {
        var digest = Data(count: Int(CC_SHA256_DIGEST_LENGTH))
        digest.withUnsafeMutableBytes { digestBuf in
            message.withUnsafeBytes { msgBuf in
                key.withUnsafeBytes { keyBuf in
                    CCHmac(
                        CCHmacAlgorithm(kCCHmacAlgSHA256),
                        keyBuf.baseAddress,  key.count,
                        msgBuf.baseAddress,  message.count,
                        digestBuf.baseAddress
                    )
                }
            }
        }
        return digest
    }

    // MARK: - HKDF-Expand (RFC 5869 §2.3, HMAC-SHA256)
    // T(0) = empty
    // T(n) = HMAC-SHA256(key=prk, data=T(n-1) || info || n)

    static func hkdfExpand(prk: Data, info: Data, outputLength: Int) -> Data {
        var output = Data()
        var t = Data()
        var counter: UInt8 = 1
        while output.count < outputLength {
            t = hmacSHA256(message: t + info + Data([counter]), key: prk)
            output.append(t)
            counter += 1
        }
        return Data(output.prefix(outputLength))
    }

    // MARK: - Session key derivation (GadgetBridge computeAuthStep3Hmac)
    //
    // PRK = HMAC-SHA256(key=phoneNonce||watchNonce, data=secretKey)
    //       ↑ key is phoneNonce+watchNonce, message is secretKey — order differs from RFC5869 extract
    //
    // expanded[0..15]  = decryptionKey
    // expanded[16..31] = encryptionKey
    // expanded[32..35] = decryptionNonce
    // expanded[36..39] = encryptionNonce

    struct SessionKeys {
        let decryptionKey:   Data   // 16 bytes
        let encryptionKey:   Data   // 16 bytes
        let decryptionNonce: Data   // 4 bytes
        let encryptionNonce: Data   // 4 bytes
    }

    static func deriveSessionKeys(
        phoneNonce: Data,
        watchNonce: Data,
        secretKey:  Data
    ) -> SessionKeys {
        let prk      = hmacSHA256(message: secretKey, key: phoneNonce + watchNonce)
        let info     = Data("miwear-auth".utf8)
        let expanded = hkdfExpand(prk: prk, info: info, outputLength: 64)
        return SessionKeys(
            decryptionKey:   expanded[0  ..< 16],
            encryptionKey:   expanded[16 ..< 32],
            decryptionNonce: expanded[32 ..< 36],
            encryptionNonce: expanded[36 ..< 40]
        )
    }

    // MARK: - AES-ECB (single-block, internal building block)

    static func aesECBEncrypt(block: Data, key: Data) throws -> Data {
        guard key.count == kCCKeySizeAES128, block.count == kCCBlockSizeAES128 else {
            throw CryptoError.invalidKeyLength(key.count)
        }
        var output = Data(count: kCCBlockSizeAES128 * 2)
        let capacity = output.count
        var moved = 0
        let status: CCCryptorStatus = output.withUnsafeMutableBytes { outBuf in
            block.withUnsafeBytes { inBuf in
                key.withUnsafeBytes { keyBuf in
                    CCCrypt(
                        CCOperation(kCCEncrypt),
                        CCAlgorithm(kCCAlgorithmAES128),
                        CCOptions(kCCOptionECBMode),
                        keyBuf.baseAddress, kCCKeySizeAES128,
                        nil,
                        inBuf.baseAddress, block.count,
                        outBuf.baseAddress, capacity,
                        &moved
                    )
                }
            }
        }
        guard status == kCCSuccess else { throw CryptoError.cryptoFailed(status: status) }
        return output.prefix(moved)
    }

    // MARK: - AES-CTR (encryptV2 / decryptV2)
    //
    // "I wish I was kidding" — GadgetBridge XiaomiAuthService comment.
    // IV (counter initial value) = key itself.
    //
    // Used for:
    //   encrypt outgoing commands: key=sessionKeys.encryptionKey, IV=encryptionKey
    //   decrypt incoming commands: key=sessionKeys.decryptionKey, IV=decryptionKey

    // NOTE: re-runs AES-ECB per 16-byte block and appends byte-by-byte. Fine for the small command
    // protobufs this handles (the only ciphered path — file uploads go plaintext on the DATA
    // channel). If a large payload is ever routed through here, switch to a buffered keystream.
    static func aesCTR(data: Data, key: Data) throws -> Data {
        guard key.count == kCCKeySizeAES128 else {
            throw CryptoError.invalidKeyLength(key.count)
        }
        var counter = Array(key)     // initial counter = key (the V2 quirk)
        var output = Data()
        var offset = 0
        while offset < data.count {
            let keystream = try aesECBEncrypt(block: Data(counter), key: key)
            let blockEnd = min(offset + kCCBlockSizeAES128, data.count)
            for i in offset ..< blockEnd {
                output.append(data[i] ^ keystream[i - offset])
            }
            incrementCounterBE(&counter)
            offset += kCCBlockSizeAES128
        }
        return output
    }

    private static func incrementCounterBE(_ counter: inout [UInt8]) {
        var i = counter.count - 1
        while i >= 0 {
            counter[i] = counter[i] &+ 1
            if counter[i] != 0 { break }
            i -= 1
        }
    }

    // MARK: - AES-CCM (auth step 3 encrypt)
    //
    // GadgetBridge uses BouncyCastle CCMBlockCipher with macSizeBits=32 (4-byte MAC).
    // Nonce: 12 bytes → L = 15 - 12 = 3.
    // Implemented here manually using AES-ECB.
    //
    // Algorithm (no AAD):
    //   B_0 = [flags][nonce(12)][Q(3)] — 16 bytes
    //   CBC-MAC over B_0 then plaintext blocks (zero-padded)
    //   A_i = [L-1][nonce(12)][counter(3 LE)] — 16 bytes
    //   S_i = AES_ECB(key, A_i)
    //   tag     = S_0[0..3] XOR mac[0..3]
    //   output  = (each plaintext[i] XOR S_ceil(i/16)[i%16]) || tag

    static func aesCCMEncrypt(key: Data, nonce: Data, plaintext: Data, tagSize: Int = 4) throws -> Data {
        guard key.count   == kCCKeySizeAES128 else { throw CryptoError.invalidKeyLength(key.count) }
        guard nonce.count == 12               else { throw CryptoError.invalidKeyLength(nonce.count) }

        let L: Int = 15 - nonce.count  // = 3
        let M: Int = tagSize           // = 4

        // B_0 flags: Adata=0, M'=(M-2)/2=1, L'=L-1=2
        let b0Flags = UInt8(((M - 2) / 2) << 3) | UInt8(L - 1)  // = 0x0A
        var B0 = Data([b0Flags])
        B0.append(nonce)
        var q = plaintext.count
        var qBytes = [UInt8](repeating: 0, count: L)
        for j in (0 ..< L).reversed() { qBytes[j] = UInt8(q & 0xFF); q >>= 8 }
        B0.append(contentsOf: qBytes)
        // B0 is exactly 16 bytes

        // CBC-MAC
        var mac = Data(count: 16)
        mac = try aesECBEncrypt(block: xor16(mac, B0), key: key)
        var off = 0
        while off < plaintext.count {
            var blk = Data(count: 16)
            let end = min(off + 16, plaintext.count)
            blk.replaceSubrange(0 ..< (end - off), with: plaintext[off ..< end])
            mac = try aesECBEncrypt(block: xor16(mac, blk), key: key)
            off += 16
        }

        // Counter block flags (no Adata, no M')
        let ctrFlags = UInt8(L - 1)  // = 0x02

        func counterBlock(_ i: Int) throws -> Data {
            var A = Data([ctrFlags])
            A.append(nonce)
            var c = i
            var cBytes = [UInt8](repeating: 0, count: L)
            for j in (0 ..< L).reversed() { cBytes[j] = UInt8(c & 0xFF); c >>= 8 }
            A.append(contentsOf: cBytes)
            return A  // 16 bytes
        }

        // Encrypt MAC with A_0 → authentication tag
        let S0  = try aesECBEncrypt(block: counterBlock(0), key: key)
        let tag = Data((0 ..< tagSize).map { S0[$0] ^ mac[$0] })

        // Encrypt plaintext with A_1, A_2, ...
        var ciphertext = Data()
        var blockIdx = 1
        off = 0
        while off < plaintext.count {
            let Si  = try aesECBEncrypt(block: counterBlock(blockIdx), key: key)
            let end = min(off + 16, plaintext.count)
            for k in off ..< end { ciphertext.append(plaintext[k] ^ Si[k - off]) }
            off += 16; blockIdx += 1
        }
        return ciphertext + tag
    }

    private static func xor16(_ a: Data, _ b: Data) -> Data {
        var result = Data(count: 16)
        for i in 0 ..< 16 { result[i] = (i < a.count ? a[i] : 0) ^ (i < b.count ? b[i] : 0) }
        return result
    }

    // MARK: - Errors

    enum CryptoError: LocalizedError {
        case invalidKeyLength(Int)
        case cryptoFailed(status: CCCryptorStatus)

        var errorDescription: String? {
            switch self {
            case .invalidKeyLength(let n): return "Invalid key/nonce: \(n) bytes."
            case .cryptoFailed(let s):     return "Cryptographic operation failed (CCCryptorStatus \(s))."
            }
        }
    }
}
