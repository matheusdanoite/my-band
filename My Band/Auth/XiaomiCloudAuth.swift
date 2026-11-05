import Foundation

// MARK: - XiaomiCloudAuth
//
// In-app port of token_extractor.py's password login flow (PasswordXiaomiCloudConnector)
// plus the encrypted device API (get_homes / get_dev_cnt / get_devices / get_beaconkey).
//
// Goal: let the user authenticate with their Xiaomi account (username + password, plus a
// captcha or emailed 2FA code if Xiaomi asks for one), then pull the band's `token`/`beaconkey`
// — which IS the BLE AuthKey (secretKey) the band handshake needs.
//
// Flow (mirrors PasswordXiaomiCloudConnector.login):
//   1. GET  serviceLogin                     → `_sign` (or, rarely, an already-valid session)
//   2. POST serviceLoginAuth2 (user, pass-md5, _sign) → ssecurity + location,
//        or a captchaUrl to solve and retry, or a notificationUrl (email 2FA) to complete
//   3. GET  location                         → serviceToken cookie (skipped if 2FA already got it)
//   4. for each region: encrypted API calls → BLE devices + their beaconkey/token
//
// The username/password only ever live in this object's memory for the duration of the login —
// never persisted, never logged (see `log`, which only traces presence/shape of secrets, not
// their values). This intentionally trades the previous QR flow's "password never touches the
// app" property for not depending on a second device/long-poll — a deliberate choice, not an
// oversight (see CLAUDE.md).
//
// Status: implemented faithfully from the reference, but the Xiaomi endpoints (especially the
// email 2FA hop chain, which chases redirects and a non-standard response header) are fragile
// and account/region-dependent — VALIDATE against a real account, captcha, and 2FA.

@MainActor
@Observable
final class XiaomiCloudAuth {

    // A BLE band discovered in the Xiaomi cloud, carrying its beaconkey (= AuthKey).
    struct CloudBand: Identifiable, Hashable {
        let id: String        // did
        let name: String
        let model: String
        let mac: String
        let beaconKey: String // hex — what we save to the Keychain
        let server: String
    }

    enum Phase: Equatable {
        case idle
        case enteringCredentials    // form shown, waiting for username/password
        case authenticating        // submitted — talking to Xiaomi
        case awaitingCaptcha(URL)  // Xiaomi wants a captcha solved before it'll continue
        case awaiting2FA           // Xiaomi emailed a verification code
        case confirmingLogin       // exchanging the login result for a service token
        case fetchingDevices       // pulling devices + beaconkeys
        case done                  // see `bands`
        case failed(String)
    }

    private(set) var phase: Phase = .idle
    private(set) var bands: [CloudBand] = []

    // Servers a Xiaomi account/device may live on (token_extractor SERVERS).
    private static let servers = ["cn", "de", "us", "ru", "tw", "sg", "in", "i2"]

    private let session: URLSession
    private let agent = XiaomiCloudAuth.generateAgent()
    private let deviceId = XiaomiCloudAuth.generateDeviceId()

    private var username: String?
    private var sign: String?
    private var ssecurity: String?
    private var userId: String?
    private var location: String?
    private var serviceToken: String?

    private var pendingCaptcha: CheckedContinuation<String, Error>?
    private var pending2FACode: CheckedContinuation<String, Error>?

    private var runTask: Task<Void, Never>?

    init() {
        // Ephemeral config already provides an isolated, in-memory cookie jar (nothing persisted to
        // disk). Do NOT replace it with `HTTPCookieStorage()` — that initializer yields a non-functional
        // storage the session never writes to, leaving the jar empty (the serviceToken was lost there).
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = true
        config.httpCookieAcceptPolicy = .always   // serviceToken is a cross-domain (sts.*) cookie
        config.timeoutIntervalForRequest = 35
        session = URLSession(configuration: config)
    }

    // MARK: - Lifecycle

    func start() {
        cancel()
        bands = []
        username = nil
        sign = nil
        ssecurity = nil
        userId = nil
        location = nil
        serviceToken = nil
        phase = .enteringCredentials
    }

    func cancel() {
        runTask?.cancel()
        runTask = nil
        pendingCaptcha?.resume(throwing: CancellationError())
        pendingCaptcha = nil
        pending2FACode?.resume(throwing: CancellationError())
        pending2FACode = nil
    }

    /// Kicks off the login with the credentials the user typed. Password is used only to compute
    /// the request's MD5 hash below and is never stored past this call's stack frame.
    func submitCredentials(username: String, password: String) {
        guard phase == .enteringCredentials else { return }
        self.username = username
        phase = .authenticating
        runTask = Task { await run(password: password) }
    }

    func submitCaptcha(_ code: String) {
        pendingCaptcha?.resume(returning: code)
        pendingCaptcha = nil
    }

    func submit2FACode(_ code: String) {
        pending2FACode?.resume(returning: code)
        pending2FACode = nil
    }

    private func run(password: String) async {
        do {
            try await loginStep1()
            try await loginStep2(password: password)
            if serviceToken == nil {
                phase = .confirmingLogin
                try await loginStep3()
            }
            phase = .fetchingDevices
            bands = try await fetchBandDevices()
            phase = .done
        } catch is CancellationError {
            // user dismissed — leave phase as-is
        } catch let error as CloudError {
            phase = .failed(error.localizedDescription)
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    // MARK: - Step 1: serviceLogin — grab the `_sign` the auth POST needs

    private func loginStep1() async throws {
        guard let url = URL(string: "https://account.xiaomi.com/pass/serviceLogin?sid=xiaomiio&_json=true")
        else { throw CloudError.invalidUsername }

        let (data, response) = try await get(url, headers: ["Cookie": "userId=\(username ?? "")"])
        guard response.statusCode == 200, let json = Self.toJSON(data) else { throw CloudError.invalidUsername }

        if let sign = json["_sign"] as? String {
            self.sign = sign
        } else if let ssec = json["ssecurity"] as? String {
            // Rare: an already-valid session came back directly.
            self.ssecurity = ssec
            self.userId = Self.stringy(json["userId"])
            self.location = json["location"] as? String
        } else {
            throw CloudError.invalidUsername
        }
    }

    // MARK: - Step 2: serviceLoginAuth2 — the actual credential check

    private func loginStep2(password: String) async throws {
        let url = "https://account.xiaomi.com/pass/serviceLoginAuth2"
        var fields: [(String, String)] = [
            ("sid", "xiaomiio"),
            ("hash", XiaomiCloudCrypto.md5Hex(Data(password.utf8)).uppercased()),
            ("callback", "https://sts.api.io.mi.com/sts"),
            ("qs", "%3Fsid%3Dxiaomiio%26_json%3Dtrue"),
            ("user", username ?? ""),
            ("_json", "true"),
        ]
        if let sign { fields.append(("_sign", sign)) }

        var json = try await postForm(url, fields: fields)

        // Xiaomi wants a captcha solved before it'll evaluate the credentials.
        if let captchaPath = json?["captchaUrl"] as? String, !captchaPath.isEmpty {
            let full = captchaPath.hasPrefix("/") ? "https://account.xiaomi.com" + captchaPath : captchaPath
            guard let captchaURL = URL(string: full) else { throw CloudError.captchaFailed }
            let code = try await requestCaptcha(imageURL: captchaURL)
            fields.append(("captCode", code))
            json = try await postForm(url, fields: fields)
            if let code = json?["code"] as? Int, code == 87001 { throw CloudError.invalidCaptcha }
        }

        if let ssec = json?["ssecurity"] as? String, ssec.count > 4 {
            self.ssecurity = ssec
            self.userId = Self.stringy(json?["userId"])
            self.location = json?["location"] as? String
            return
        }

        if let notificationURL = json?["notificationUrl"] as? String {
            try await do2FAEmailFlow(notificationURL: notificationURL)
            return
        }

        throw CloudError.invalidCredentials
    }

    // MARK: - Step 3: exchange the login location for a service token

    private func loginStep3() async throws {
        guard let loc = location, let url = URL(string: loc) else { throw CloudError.noServiceToken }
        let (_, response) = try await get(url, headers: ["content-type": "application/x-www-form-urlencoded"])

        if let fields = response.allHeaderFields as? [String: String], let responseURL = response.url {
            let cookies = HTTPCookie.cookies(withResponseHeaderFields: fields, for: responseURL)
            serviceToken = cookies.first { $0.name == "serviceToken" }?.value
        }
        if serviceToken == nil { serviceToken = cookieValue(named: "serviceToken") }
        Self.log("serviceToken present=\(serviceToken != nil)")
        if serviceToken == nil { throw CloudError.noServiceToken }
    }

    // MARK: - Email 2FA
    //
    // Ported from `do_2fa_email_flow`. Several hops here read the `Location`/`extension-pragma`
    // headers of a redirect *response itself*, so those specific requests must not auto-follow the
    // redirect (`getWithoutRedirect`) — the same reason the Python side passes `allow_redirects=False`.

    private func do2FAEmailFlow(notificationURL: String) async throws {
        guard let notifURL = URL(string: notificationURL),
              let comps = URLComponents(url: notifURL, resolvingAgainstBaseURL: false),
              let context = comps.queryItems?.first(where: { $0.name == "context" })?.value
        else { throw CloudError.twoFactorFailed }

        _ = try? await get(notifURL)   // authStart — establishes the identity session cookie

        var listComps = URLComponents(string: "https://account.xiaomi.com/identity/list")!
        listComps.queryItems = [.init(name: "sid", value: "xiaomiio"), .init(name: "context", value: context),
                                 .init(name: "_locale", value: "en_US")]
        _ = try? await get(listComps.url!)

        let ick = cookieValue(named: "ick") ?? ""
        let sendQuery = "_dc=\(Int(Date().timeIntervalSince1970 * 1000))&sid=xiaomiio&context=\(Self.quotePlus(context))&mask=0&_locale=en_US"
        guard let sendURL = URL(string: "https://account.xiaomi.com/identity/auth/sendEmailTicket?\(sendQuery)")
        else { throw CloudError.twoFactorFailed }
        var sendRequest = URLRequest(url: sendURL)
        sendRequest.httpMethod = "POST"
        sendRequest.setValue(agent, forHTTPHeaderField: "User-Agent")
        sendRequest.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        sendRequest.httpBody = Data("retry=0&icode=&_json=true&ick=\(Self.quotePlus(ick))".utf8)
        _ = try? await session.data(for: sendRequest)

        // Suspends until the UI calls `submit2FACode`.
        let code = try await request2FACode()

        let verifyQuery = "_flag=8&_json=true&sid=xiaomiio&context=\(Self.quotePlus(context))&mask=0&_locale=en_US"
        guard let verifyURL = URL(string: "https://account.xiaomi.com/identity/auth/verifyEmail?\(verifyQuery)")
        else { throw CloudError.twoFactorFailed }
        var verifyRequest = URLRequest(url: verifyURL)
        verifyRequest.httpMethod = "POST"
        verifyRequest.setValue(agent, forHTTPHeaderField: "User-Agent")
        verifyRequest.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        verifyRequest.httpBody = Data("_flag=8&ticket=\(Self.quotePlus(code))&trust=false&_json=true&ick=\(Self.quotePlus(ick))".utf8)
        let (verifyData, verifyResponse) = try await session.data(for: verifyRequest)
        guard (verifyResponse as? HTTPURLResponse)?.statusCode == 200 else { throw CloudError.twoFactorFailed }

        var finishLocation = Self.toJSON(verifyData)?["location"] as? String

        if finishLocation == nil {
            guard let checkURL = URL(string: "https://account.xiaomi.com/identity/result/check?sid=xiaomiio&context=\(Self.quotePlus(context))&_locale=en_US")
            else { throw CloudError.twoFactorFailed }
            let (_, checkResponse) = try await getWithoutRedirect(checkURL)
            if (checkResponse.statusCode == 301 || checkResponse.statusCode == 302),
               let loc = checkResponse.value(forHTTPHeaderField: "Location") {
                finishLocation = loc
            }
        }
        guard var endURLString = finishLocation else { throw CloudError.twoFactorFailed }

        if endURLString.contains("identity/result/check"), let checkURL = URL(string: endURLString) {
            let (_, r) = try await getWithoutRedirect(checkURL)
            guard let loc = r.value(forHTTPHeaderField: "Location") else { throw CloudError.twoFactorFailed }
            endURLString = loc
        }
        guard let endURL = URL(string: endURLString) else { throw CloudError.twoFactorFailed }

        var (endData, endResponse) = try await getWithoutRedirect(endURL)
        // Some servers return a 200 "Tips" interstitial first, then the real 302 on the next call.
        if endResponse.statusCode == 200, String(decoding: endData, as: UTF8.self).contains("Xiaomi Account - Tips") {
            (endData, endResponse) = try await getWithoutRedirect(endURL)
        }

        if let pragma = endResponse.value(forHTTPHeaderField: "extension-pragma"),
           let pragmaJSON = (try? JSONSerialization.jsonObject(with: Data(pragma.utf8))) as? [String: Any],
           let ssec = pragmaJSON["ssecurity"] as? String {
            ssecurity = ssec
        }
        guard ssecurity != nil else { throw CloudError.twoFactorFailed }

        var stsURLString = endResponse.value(forHTTPHeaderField: "Location")
        if stsURLString == nil {
            let body = String(decoding: endData, as: UTF8.self)
            if let range = body.range(of: "https://sts.api.io.mi.com/sts") {
                let rest = body[range.lowerBound...]
                stsURLString = String(rest[rest.startIndex..<(rest.firstIndex(of: "\"") ?? rest.index(rest.startIndex, offsetBy: min(300, rest.count)))])
            }
        }
        guard let stsURLFinal = stsURLString, let stsURL = URL(string: stsURLFinal) else { throw CloudError.twoFactorFailed }

        let (_, stsResponse) = try await get(stsURL)
        guard stsResponse.statusCode == 200 else { throw CloudError.twoFactorFailed }

        guard let token = cookieValue(named: "serviceToken") else { throw CloudError.twoFactorFailed }
        serviceToken = token
        installServiceTokenCookies(token)
        if userId == nil { userId = cookieValue(named: "userId") }
    }

    private func requestCaptcha(imageURL: URL) async throws -> String {
        phase = .awaitingCaptcha(imageURL)
        return try await withCheckedThrowingContinuation { pendingCaptcha = $0 }
    }

    private func request2FACode() async throws -> String {
        phase = .awaiting2FA
        return try await withCheckedThrowingContinuation { pending2FACode = $0 }
    }

    private func installServiceTokenCookies(_ token: String) {
        guard let storage = session.configuration.httpCookieStorage else { return }
        for domain in [".api.io.mi.com", ".io.mi.com", ".mi.com"] {
            for name in ["serviceToken", "yetAnotherServiceToken"] {
                if let cookie = HTTPCookie(properties: [.domain: domain, .path: "/", .name: name, .value: token]) {
                    storage.setCookie(cookie)
                }
            }
        }
    }

    private func cookieValue(named name: String) -> String? {
        session.configuration.httpCookieStorage?.cookies?.first { $0.name == name }?.value
    }

    // MARK: - Step 4: discover BLE bands and their beaconkeys across regions
    //
    // Unchanged from the previous QR flow — once `ssecurity`/`userId`/`serviceToken` are set, the
    // rest of the pipeline doesn't care how they were obtained.

    private func fetchBandDevices() async throws -> [CloudBand] {
        guard ssecurity != nil else { throw CloudError.noServiceToken }
        var found: [String: CloudBand] = [:]   // dedupe by did across regions

        for server in Self.servers {
            try Task.checkCancellation()

            var homes: [(homeId: String, ownerId: String)] = []
            if let homesResp = try await getHomes(server: server),
               let result = homesResp["result"] as? [String: Any],
               let list = result["homelist"] as? [[String: Any]] {
                for h in list {
                    if let id = Self.stringy(h["id"]), let owner = userId {
                        homes.append((id, owner))
                    }
                }
            }
            if let cntResp = try await getDeviceCount(server: server),
               let result = cntResp["result"] as? [String: Any],
               let share = result["share"] as? [String: Any],
               let family = share["share_family"] as? [[String: Any]] {
                for h in family {
                    if let id = Self.stringy(h["home_id"]), let owner = Self.stringy(h["home_owner"]) {
                        homes.append((id, owner))
                    }
                }
            }
            Self.log("server=\(server) homes=\(homes.count)")

            for home in homes {
                try Task.checkCancellation()
                guard let devicesResp = try await getDevices(server: server, homeId: home.homeId, ownerId: home.ownerId),
                      let result = devicesResp["result"] as? [String: Any],
                      let info = result["device_info"] as? [[String: Any]]
                else { continue }

                let bltCount = info.filter { (Self.stringy($0["did"]) ?? "").contains("blt") }.count
                Self.log("server=\(server) home=\(home.homeId) devices=\(info.count) blt=\(bltCount)")

                for device in info {
                    guard let did = Self.stringy(device["did"]) else { continue }
                    let model = device["model"] as? String ?? ""
                    let name = device["name"] as? String ?? ""
                    Self.log("device did=\(did) model=\(model) name=\(name)")

                    // The Mi Band 10 is a `miwear.watch.*` device with a NUMERIC did — it does NOT
                    // carry "blt" like older BLE devices, so the token_extractor filter misses it.
                    guard Self.isWearable(did: did, model: model, name: name) else { continue }

                    // The device's `token` IS the BLE pairing AuthKey (token_extractor prints it as
                    // TOKEN; confirmed on hardware = dd33411e… for the Mi Band 10). This is the key
                    // the handshake needs — NOT the beaconkey, which is the separate MiBeacon key
                    // (different secret, rejected by the HMAC). Fall back to the beaconkey endpoint
                    // only for legacy blt.* devices that don't carry a token inline.
                    var key = (device["token"] as? String) ?? ""
                    if key.isEmpty {
                        let beaconResp = try await getBeaconKey(server: server, did: did)
                        key = (beaconResp?["result"] as? [String: Any])?["beaconkey"] as? String ?? ""
                    }
                    Self.log("key for did=\(did): found=\(!key.isEmpty) len=\(key.count) fromToken=\(device["token"] != nil)")
                    guard !key.isEmpty else { continue }

                    found[did] = CloudBand(
                        id: did,
                        name: name.isEmpty ? "Mi Band" : name,
                        model: model,
                        mac: (device["mac"] as? String) ?? "",
                        beaconKey: key,
                        server: server
                    )
                }
            }
        }

        let result = Array(found.values).sorted { $0.name < $1.name }
        if result.isEmpty { throw CloudError.noBandFound }
        return result
    }

    // MARK: - Encrypted API endpoints

    private func getHomes(server: String) async throws -> [String: Any]? {
        try await apiCall(server: server, path: "/v2/homeroom/gethome",
                          data: #"{"fg": true, "fetch_share": true, "fetch_share_dev": true, "limit": 300, "app_ver": 7}"#)
    }

    private func getDeviceCount(server: String) async throws -> [String: Any]? {
        try await apiCall(server: server, path: "/v2/user/get_device_cnt",
                          data: #"{ "fetch_own": true, "fetch_share": true}"#)
    }

    private func getDevices(server: String, homeId: String, ownerId: String) async throws -> [String: Any]? {
        let data = "{\"home_owner\": \(ownerId),\"home_id\": \(homeId),  \"limit\": 200,  \"get_split_device\": true, \"support_smart_home\": true}"
        return try await apiCall(server: server, path: "/v2/home/home_device_list", data: data)
    }

    private func getBeaconKey(server: String, did: String) async throws -> [String: Any]? {
        try await apiCall(server: server, path: "/v2/device/blt_get_beaconkey",
                          data: "{\"did\":\"\(did)\",\"pdid\":1}")
    }

    // MARK: - Encrypted API plumbing (execute_api_call_encrypted)

    private func apiCall(server: String, path: String, data: String) async throws -> [String: Any]? {
        guard let ssecurity else { throw CloudError.noServiceToken }
        let url = Self.apiURL(server: server) + path

        let millis = Int(Date().timeIntervalSince1970 * 1000)
        let nonce = Self.generateNonce(millis: millis)
        let signed = signedNonce(nonce: nonce, ssecurity: ssecurity)
        let params = encParams(url: url, method: "POST", signedNonce: signed, nonce: nonce,
                               params: [("data", data)], ssecurity: ssecurity)

        // Params travel as a percent-encoded query string (quote_plus semantics), like requests.
        let query = params.map { "\($0.0)=\(Self.quotePlus($0.1))" }.joined(separator: "&")
        guard let requestURL = URL(string: url + "?" + query) else { return nil }

        var request = URLRequest(url: requestURL)
        request.httpMethod = "POST"
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        request.setValue(agent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("PROTOCAL-HTTP2", forHTTPHeaderField: "x-xiaomi-protocal-flag-cli")
        request.setValue("ENCRYPT-RC4", forHTTPHeaderField: "MIOT-ENCRYPT-ALGORITHM")
        request.setValue(apiCookieHeader(), forHTTPHeaderField: "Cookie")

        let (body, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        let rawText = String(decoding: body, as: UTF8.self)
        guard status == 200 else {
            Self.log("apiCall \(path)@\(server) status=\(status) body=\(rawText.prefix(160))")
            return nil
        }

        // Body is base64(RC4(json)); decrypt with the same signed nonce.
        guard let cipher = Data(base64Encoded: rawText), let keyData = Data(base64Encoded: signed) else {
            // Not encrypted base64 — usually a plaintext error envelope (e.g. bad signature/token).
            Self.log("apiCall \(path)@\(server) not-encrypted body=\(rawText.prefix(160))")
            return nil
        }
        let plain = XiaomiCloudCrypto.rc4(key: keyData, data: cipher)
        let json = (try? JSONSerialization.jsonObject(with: plain)) as? [String: Any]
        Self.log("apiCall \(path)@\(server) code=\(json?["code"] ?? "?") msg=\(json?["message"] ?? "?")")
        return json
    }

    private func apiCookieHeader() -> String {
        let pairs = [
            "userId": userId ?? "",
            "yetAnotherServiceToken": serviceToken ?? "",
            "serviceToken": serviceToken ?? "",
            "locale": "en_GB",
            "timezone": "GMT+02:00",
            "is_daylight": "1",
            "dst_offset": "3600000",
            "channel": "MI_APP_STORE",
        ]
        return pairs.map { "\($0)=\($1)" }.joined(separator: "; ")
    }

    // MARK: - Signature / nonce (generate_enc_params, generate_enc_signature, signed_nonce)

    private func signedNonce(nonce: String, ssecurity: String) -> String {
        let sec = Data(base64Encoded: ssecurity) ?? Data()
        let non = Data(base64Encoded: nonce) ?? Data()
        return XiaomiCloudCrypto.sha256(sec + non).base64EncodedString()
    }

    /// Builds the ordered, RC4-encrypted param list with its trailing signature/ssecurity/_nonce.
    private func encParams(url: String, method: String, signedNonce: String, nonce: String,
                           params: [(String, String)], ssecurity: String) -> [(String, String)] {
        var p = params
        // 1) hash over the PLAINTEXT params
        p.append(("rc4_hash__", encSignature(url: url, method: method, signedNonce: signedNonce, params: p)))
        // 2) encrypt every value
        let key = Data(base64Encoded: signedNonce) ?? Data()
        p = p.map { ($0.0, XiaomiCloudCrypto.rc4(key: key, data: Data($0.1.utf8)).base64EncodedString()) }
        // 3) signature over the ENCRYPTED params, then the untouched trailers
        p.append(("signature", encSignature(url: url, method: method, signedNonce: signedNonce, params: p)))
        p.append(("ssecurity", ssecurity))
        p.append(("_nonce", nonce))
        return p
    }

    private func encSignature(url: String, method: String, signedNonce: String, params: [(String, String)]) -> String {
        // path = everything after the first "com", with the "/app/" prefix stripped.
        let afterCom = url.components(separatedBy: "com").count > 1
            ? url.components(separatedBy: "com")[1].replacingOccurrences(of: "/app/", with: "/")
            : url
        var parts = [method.uppercased(), afterCom]
        parts.append(contentsOf: params.map { "\($0.0)=\($0.1)" })
        parts.append(signedNonce)
        let signatureString = parts.joined(separator: "&")
        return XiaomiCloudCrypto.sha1(Data(signatureString.utf8)).base64EncodedString()
    }

    // MARK: - HTTP helpers

    @discardableResult
    private func get(_ url: URL, headers: [String: String] = [:]) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url)
        request.setValue(agent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw CloudError.network }
        return (data, http)
    }

    /// POST with the fields glued into the query string (`requests.post(url, params=fields)`
    /// semantics — Xiaomi's login endpoints read form fields from there, not the body).
    private func postForm(_ urlString: String, fields: [(String, String)]) async throws -> [String: Any]? {
        let query = fields.map { "\($0.0)=\(Self.quotePlus($0.1))" }.joined(separator: "&")
        guard let url = URL(string: urlString + "?" + query) else { throw CloudError.network }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(agent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse) != nil else { throw CloudError.network }
        return Self.toJSON(data)
    }

    /// A GET that does NOT follow redirects, so the caller can read the redirect response's own
    /// headers (`Location`, or Xiaomi's non-standard `extension-pragma`) instead of the destination's.
    private func getWithoutRedirect(_ url: URL) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url)
        request.setValue(agent, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request, delegate: RedirectBlocker())
        guard let http = response as? HTTPURLResponse else { throw CloudError.network }
        return (data, http)
    }

    // Completion-handler form, not the async variant: the async flavor of this delegate method
    // crashes the Swift 27 compiler's ObjC thunk codegen (SIL emitNativeToForeignThunk) on this
    // toolchain. `session.data(for:delegate:)` bridges either style fine.
    private final class RedirectBlocker: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest,
                        completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }

    // MARK: - Static helpers (mirror the Python module functions)

    private static func apiURL(server: String) -> String {
        "https://" + (server == "cn" ? "" : server + ".") + "api.io.mi.com/app"
    }

    private static func generateNonce(millis ms: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: 8)
        _ = SecRandomCopyBytes(kSecRandomDefault, 8, &bytes)
        let minutes = UInt32(ms / 60000)
        bytes.append(UInt8((minutes >> 24) & 0xFF))
        bytes.append(UInt8((minutes >> 16) & 0xFF))
        bytes.append(UInt8((minutes >> 8) & 0xFF))
        bytes.append(UInt8(minutes & 0xFF))
        return Data(bytes).base64EncodedString()
    }

    private static func generateAgent() -> String {
        let agentId = String((0..<13).map { _ in Character(UnicodeScalar(UInt8.random(in: 65...69))) })
        let randomText = String((0..<18).map { _ in Character(UnicodeScalar(UInt8.random(in: 97...122))) })
        return "\(randomText)-\(agentId) APP/com.xiaomi.mihome APPV/10.5.201"
    }

    private static func generateDeviceId() -> String {
        String((0..<6).map { _ in Character(UnicodeScalar(UInt8.random(in: 97...122))) })
    }

    /// Strips Xiaomi's "&&&START&&&" guard prefix and parses JSON.
    private static func toJSON(_ data: Data) -> [String: Any]? {
        var text = String(decoding: data, as: UTF8.self)
        text = text.replacingOccurrences(of: "&&&START&&&", with: "")
        guard let clean = text.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: clean)) as? [String: Any]
    }

    /// Coerces a JSON number-or-string id into a String (Xiaomi mixes the two).
    private static func stringy(_ value: Any?) -> String? {
        if let s = value as? String { return s }
        if let n = value as? Int { return String(n) }
        if let n = value as? Int64 { return String(n) }
        if let n = value as? Double { return String(Int64(n)) }
        return nil
    }

    /// Whether a Mi Home device is a wearable whose BLE pairing key we can try to fetch.
    /// Covers legacy "blt.*" devices and the Mi Band 8/9/10 family (`miwear.watch.*`, numeric did).
    private static func isWearable(did: String, model: String, name: String) -> Bool {
        let m = model.lowercased(), n = name.lowercased()
        return did.contains("blt")
            || m.hasPrefix("miwear") || m.contains("watch") || m.contains("band") || m.contains("mibfs")
            || n.contains("band") || n.contains("watch")
    }

    /// Debug-only tracing of the cloud handshake. Never logs the username, password, serviceToken,
    /// or beaconkey values — only their presence and non-sensitive structure (status codes, cookie
    /// names, response codes).
    private static func log(_ message: @autoclosure () -> String) {
        #if DEBUG
        print("[XiaomiCloud] \(message())")
        #endif
    }

    /// urlencode/quote_plus-equivalent: keep unreserved chars, percent-encode the rest. Needed
    /// because several login/API values are base64 (`_sign`, RC4 output) and can contain `+`, `/`,
    /// `=` — `URLComponents`' own query encoding leaves `+` as a literal plus, which a form-encoded
    /// parser on the other end reads back as a space, silently corrupting the value.
    private static func quotePlus(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "_.-")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    // MARK: - Errors

    enum CloudError: LocalizedError {
        case network
        case invalidUsername
        case invalidCredentials
        case captchaFailed
        case invalidCaptcha
        case twoFactorFailed
        case noServiceToken
        case noBandFound

        var errorDescription: String? {
            switch self {
            case .network:             return "Network error while talking to Xiaomi."
            case .invalidUsername:     return "Username not recognized."
            case .invalidCredentials:  return "Incorrect username or password."
            case .captchaFailed:       return "Couldn't load the captcha. Please try again."
            case .invalidCaptcha:      return "Incorrect captcha."
            case .twoFactorFailed:     return "Couldn't confirm the verification code."
            case .noServiceToken:      return "Login not completed — Xiaomi did not confirm the session."
            case .noBandFound:         return "No band found on this Xiaomi account."
            }
        }
    }
}
