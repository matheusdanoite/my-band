import Foundation
import OSLog
import CoreLocation

// MARK: - WeatherSyncService
//
// Fetches weather from Open-Meteo (free, no API key) and pushes it to the band (app → band,
// encrypted), mirroring GadgetBridge XiaomiWeatherService:
//   1. CMD_ADD_LOCATION   (weather.location)  — register the location
//   2. CMD_SET_CURRENT_WEATHER (weather.current)
//   3. CMD_UPDATE_DAILY_FORECAST (weather.forecast)
//
// Default location is Guarapuava, PR. Best-effort: no network / decode failure just skips.

@MainActor
final class WeatherSyncService: NSObject {

    /// Default location (Guarapuava, PR) — used for the proactive push and as a fallback when the
    /// band asks about a location name that can't be geocoded.
    private let latitude  = -25.3935
    private let longitude = -51.4562
    private let locationName = "Guarapuava"

    private let geocodeCacheKey = "myband.weatherGeocodeCache"
    /// Administrative context appended to disambiguate local names (see coordinates(forLocationNamed:)).
    private let homeContext = "Guarapuava, Paraná, Brazil"
    /// A result this close to the default counts as "the home area" (Guarapuava is ~50 km across).
    private let homeAreaRadius: CLLocationDistance = 60_000

    private weak var bandManager: BandManager?
    private let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.myband", category: "Weather")

    /// Conditions from the last successful band-sync weather fetch. Reused for workout metadata so
    /// the health sync doesn't fire its own Open-Meteo request per workout (which was timing out and
    /// tripping the background watchdog). nil until the first fetch of the session succeeds.
    private(set) var lastConditions: WorkoutWeather?

    // iPhone GPS so the band's weather follows where the user actually is (every request uses it).
    private let locationManager = CLLocationManager()
    private var lastFix: (location: CLLocation, at: Date)?
    private let fixTTL: TimeInterval = 5 * 60           // reuse a fix across back-to-back requests
    private var isRequestingFix = false
    private var fixWaiters: [CheckedContinuation<CLLocation?, Never>] = []
    private var placeNameCache: [String: String] = [:]  // rounded "lat,lon" → reverse-geocoded city

    // The proactive push at the end of every sync would re-fetch and re-send on each sync (minutes
    // apart). Weather doesn't change that fast, so throttle it. Band-initiated requests
    // (onWeatherConditionsRequest) bypass this — the band's weather screen is waiting on that answer.
    private let proactiveThrottle: TimeInterval = 30 * 60
    private let lastProactivePushKey = "myband.lastWeatherPush"

    func setup(manager: BandManager) {
        bandManager = manager
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyKilometer   // city-level is enough for weather
        // The band pulls weather on its own schedule (on connect, when its weather screen opens). It's
        // the trigger the band's UI actually waits on, so respond to it — a proactive push alone won't
        // populate the widget. Echo the location the band asked for so it binds our data correctly.
        manager.onWeatherConditionsRequest = { [weak self] key, name in
            Task { await self?.pushWeather(requestedKey: key, requestedName: name) }
        }
    }

    // MARK: - Push entry point

    /// Pushes weather to the band. With no arguments it advertises the default location as the current
    /// one (proactive push at the end of a sync). When answering the band's request, the requested
    /// key/name are echoed back so the band associates the data with the location it asked about.
    func pushWeather(requestedKey: String = "", requestedName: String = "") async {
        guard bandManager?.connectionState.isConnected == true else { return }

        let proactive = requestedKey.isEmpty
        if proactive {
            let last = UserDefaults.standard.double(forKey: lastProactivePushKey)
            if last > 0, Date().timeIntervalSince1970 - last < proactiveThrottle {
                log.debug("Weather pushed recently — skipping proactive push")
                return
            }
        }

        let target = await resolveLocation(requestedKey: requestedKey, requestedName: requestedName)
        do {
            let data = try await fetch(latitude: target.lat, longitude: target.lon)
            lastConditions = WorkoutWeather(wmoCode: data.current.weatherCode,
                                            temperatureC: data.current.temperature2M,
                                            humidityPct: data.current.relativeHumidity2M)
            sendToBand(data, name: target.name, code: target.code, isCurrent: target.isCurrent)
            if proactive {
                UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: lastProactivePushKey)
            }
        } catch {
            log.error("Weather fetch failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Location resolution
    //
    // Resolution order (per user choice — the weather always follows where the phone is):
    //   1. iPhone GPS — every request, foreground or background. The band's requested key is echoed so
    //      its waiting tile binds to our reply, but the data and label are the user's real location.
    //   2. GPS denied/unavailable → the band's named location, geocoded (saved-location behaviour).
    //   3. Nothing resolved → the default location (Guarapuava).

    private func resolveLocation(requestedKey: String, requestedName: String)
        async -> (lat: Double, lon: Double, name: String, code: String, isCurrent: Bool) {

        if let loc = await currentLocation() {
            let name = await placeName(for: loc) ?? (requestedName.isEmpty ? "Current location" : requestedName)
            // Echo the requested key so the band binds the reply to the tile it's waiting on; for a
            // proactive push (no request) derive a stable key from the resolved name.
            let code = requestedKey.isEmpty ? locationKey(name) : requestedKey
            log.info("Weather location from GPS: \(name) (\(loc.coordinate.latitude), \(loc.coordinate.longitude))")
            return (loc.coordinate.latitude, loc.coordinate.longitude, name, code, true)
        }

        if !requestedName.isEmpty, let coord = await coordinates(forLocationNamed: requestedName) {
            return (coord.lat, coord.lon, requestedName, requestedKey, requestedKey.isEmpty)
        }

        let name = requestedName.isEmpty ? locationName : requestedName
        let code = requestedKey.isEmpty ? locationKey(locationName) : requestedKey
        return (latitude, longitude, name, code, requestedKey.isEmpty)
    }

    /// A single GPS fix, reusing a recent one across back-to-back requests. Returns nil when location
    /// is denied/restricted; on first use (notDetermined) it asks for When-In-Use and returns nil for
    /// this round (the next request will have the answer).
    private func currentLocation() async -> CLLocation? {
        switch locationManager.authorizationStatus {
        case .notDetermined:
            locationManager.requestWhenInUseAuthorization()
            return nil
        case .authorizedWhenInUse, .authorizedAlways:
            break
        default:
            return nil
        }

        if let fix = lastFix, Date().timeIntervalSince(fix.at) < fixTTL { return fix.location }

        return await withCheckedContinuation { (cont: CheckedContinuation<CLLocation?, Never>) in
            fixWaiters.append(cont)
            guard !isRequestingFix else { return }
            isRequestingFix = true
            locationManager.requestLocation()
            // requestLocation can hang; cap it and fall back to the last cached fix.
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(8))
                self?.finishFix(self?.locationManager.location)
            }
        }
    }

    private func finishFix(_ location: CLLocation?) {
        guard isRequestingFix else { return }
        isRequestingFix = false
        if let location { lastFix = (location, Date()) }
        let result = location ?? lastFix?.location
        let waiters = fixWaiters
        fixWaiters = []
        waiters.forEach { $0.resume(returning: result) }
    }

    /// Reverse-geocodes a fix to a city name for the band's label. Cached by ~1 km cell.
    private func placeName(for loc: CLLocation) async -> String? {
        let cellKey = String(format: "%.2f,%.2f", loc.coordinate.latitude, loc.coordinate.longitude)
        if let cached = placeNameCache[cellKey] { return cached }
        guard let placemarks = try? await CLGeocoder().reverseGeocodeLocation(loc, preferredLocale: Locale(identifier: "en_US")),
              let p = placemarks.first else { return nil }
        let name = p.locality ?? p.subAdministrativeArea ?? p.name
        if let name { placeNameCache[cellKey] = name }
        return name
    }

    // MARK: - Geocoding

    /// Resolves a band-supplied location name to coordinates via CLGeocoder. Results are cached
    /// (persisted) because the band re-requests on every connect and Apple rate-limits geocoding.
    ///
    /// The hard case is that the band's locations are usually *neighbourhoods* of the home city
    /// ("Santa Cruz" is a bairro of Guarapuava), and a bare geocode of such a name matches a far
    /// same-named city (Santa Cruz do Sul, Santa Cruz de la Sierra…) — worse than the old default.
    /// So we try the name qualified with the home city first and accept it only when it lands in the
    /// home area; otherwise we fall back to the bare name (a genuinely different, possibly distant,
    /// configured city), and finally to nil (caller uses the default).
    private func coordinates(forLocationNamed name: String) async -> (lat: Double, lon: Double)? {
        let cacheKey = name.lowercased()
        if let hit = (UserDefaults.standard.dictionary(forKey: geocodeCacheKey) as? [String: [Double]])?[cacheKey],
           hit.count == 2 {
            return (hit[0], hit[1])
        }

        let home = CLLocation(latitude: latitude, longitude: longitude)
        let qualified = await geocode("\(name), \(homeContext)")
        let resolved: CLLocation?
        if let q = qualified, q.distance(from: home) < homeAreaRadius {
            resolved = q                                   // a local neighbourhood of the home city
        } else {
            resolved = await geocode(name) ?? qualified    // a different city; else the qualified hit
        }

        guard let loc = resolved else {
            log.info("Could not geocode \"\(name)\" — using default location")
            return nil
        }
        let coord = (lat: loc.coordinate.latitude, lon: loc.coordinate.longitude)
        // Re-read before writing: a concurrent request (the band can ask about two locations at once)
        // may have added its own entry during the awaits above, which a stale copy would clobber.
        var cache = UserDefaults.standard.dictionary(forKey: geocodeCacheKey) as? [String: [Double]] ?? [:]
        cache[cacheKey] = [coord.lat, coord.lon]
        UserDefaults.standard.set(cache, forKey: geocodeCacheKey)
        log.info("Geocoded \"\(name)\" → \(coord.lat), \(coord.lon)")
        return coord
    }

    /// One geocoding pass, biased toward the home region. A fresh geocoder per call: CLGeocoder
    /// rejects concurrent requests on a single instance, and the band can ask about two locations
    /// back-to-back.
    private func geocode(_ query: String) async -> CLLocation? {
        let region = CLCircularRegion(center: CLLocationCoordinate2D(latitude: latitude, longitude: longitude),
                                      radius: 2_000_000, identifier: "weather-hint")
        guard let placemarks = try? await CLGeocoder().geocodeAddressString(query, in: region, preferredLocale: Locale(identifier: "en_US")) else {
            return nil
        }
        return placemarks.first?.location
    }

    // MARK: - Open-Meteo fetch

    private func fetch(latitude: Double, longitude: Double) async throws -> OpenMeteoResponse {
        var comps = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        comps.queryItems = [
            .init(name: "latitude",  value: String(latitude)),
            .init(name: "longitude", value: String(longitude)),
            .init(name: "current",   value: "temperature_2m,relative_humidity_2m,weather_code,surface_pressure,wind_speed_10m,wind_direction_10m"),
            .init(name: "daily",     value: "weather_code,temperature_2m_max,temperature_2m_min,sunrise,sunset,uv_index_max"),
            .init(name: "timezone",  value: "auto"),
            .init(name: "timeformat", value: "unixtime"),
            .init(name: "wind_speed_unit", value: "kmh"),
            // 7 days: today + 6 ahead, matching GadgetBridge's entry coverage (today reconstructed
            // from current conditions, then 6 forecast days).
            .init(name: "forecast_days", value: "7"),
        ]
        let bytes = try await fetchData(comps.url!)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(OpenMeteoResponse.self, from: bytes)
    }

    /// GETs a URL with a short per-attempt timeout and one retry. The default URLSession timeout is
    /// 60 s, which — on a flaky link — hangs the sync long enough to trip the "background task over
    /// 30 s" watchdog. Failing fast (8 s) and retrying once keeps weather best-effort without
    /// stalling the health sync it piggybacks on.
    private func fetchData(_ url: URL, timeout: TimeInterval = 8, retries: Int = 1) async throws -> Data {
        var attempt = 0
        while true {
            var request = URLRequest(url: url)
            request.timeoutInterval = timeout
            do {
                let (bytes, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                    throw URLError(.badServerResponse)
                }
                return bytes
            } catch {
                attempt += 1
                if attempt > retries { throw error }
                log.debug("Weather fetch retry \(attempt) after: \(error.localizedDescription)")
            }
        }
    }


    // MARK: - Build + send

    private func sendToBand(_ w: OpenMeteoResponse, name: String, code: String, isCurrent: Bool) {
        guard let manager = bandManager else { return }
        let tz = TimeZone(secondsFromGMT: w.utcOffsetSeconds) ?? .current

        let metadata = makeMetadata(timestamp: w.current.time, tz: tz, name: name, code: code, isCurrent: isCurrent)

        // 1. Location
        manager.sendEncryptedCommand(protoBytes: XiaomiProto.weatherAddLocationCommand(code: code, name: name))

        // 2. Current conditions
        var current = Xiaomi_WeatherCurrent()
        current.metadata         = metadata
        current.weatherCondition = UInt32(Self.xiaomiCondition(wmo: w.current.weatherCode))
        current.temperature = XiaomiProto.weatherUnit(Int32(w.current.temperature2M.rounded()), "℃")
        current.humidity    = XiaomiProto.weatherUnit(Int32(w.current.relativeHumidity2M.rounded()), "%")
        current.wind        = XiaomiProto.weatherUnit(Self.beaufort(kmh: w.current.windSpeed10M),
                                                      String(Int(w.current.windDirection10M.rounded())))
        current.uv          = XiaomiProto.weatherUnit(Int32((w.daily.uvIndexMax.first ?? 0).rounded()), "")
        current.aqi         = XiaomiProto.weatherUnit(0, "Unknown")
        current.warning     = Xiaomi_WeatherWarnings()
        current.pressure    = Float(w.current.surfacePressure) * 100   // hPa → Pa (GadgetBridge)
        manager.sendEncryptedCommand(protoBytes: XiaomiProto.currentWeatherCommand(current))

        // 3. Daily forecast (today + up to 6 days ahead)
        var entries = Xiaomi_ForecastEntries()
        let days = min(7, w.daily.time.count)
        for i in 0..<days {
            var entry = Xiaomi_ForecastEntry()
            entry.aqi = XiaomiProto.weatherUnit(0, "Unknown")
            var condition = Xiaomi_WeatherRange()
            let c = Int32(Self.xiaomiCondition(wmo: w.daily.weatherCode[i]))
            condition.from = c; condition.to = c
            entry.conditionRange = condition
            var temp = Xiaomi_WeatherRange()
            temp.from = Int32(w.daily.temperature2MMax[i].rounded())   // GadgetBridge: from=max, to=min
            temp.to   = Int32(w.daily.temperature2MMin[i].rounded())
            entry.temperatureRange  = temp
            entry.temperatureSymbol = "℃"
            var sun = Xiaomi_WeatherSunriseSunset()
            sun.sunrise = iso(w.daily.sunrise[i], tz: tz)
            sun.sunset  = iso(w.daily.sunset[i], tz: tz)
            entry.sunriseSunset = sun
            entries.entry.append(entry)
        }
        var forecast = Xiaomi_WeatherForecast()
        forecast.metadata = metadata
        forecast.entries  = entries
        manager.sendEncryptedCommand(protoBytes: XiaomiProto.dailyForecastCommand(forecast))

        log.info("Weather pushed: \(name), \(Int(w.current.temperature2M))℃, \(days)-day forecast")
    }

    private func makeMetadata(timestamp: Int, tz: TimeZone, name: String, code: String, isCurrent: Bool) -> Xiaomi_WeatherMetadata {
        var m = Xiaomi_WeatherMetadata()
        m.publicationTimestamp = iso(timestamp, tz: tz)
        m.cityName          = ""
        m.locationName      = name
        m.locationKey       = code
        m.isCurrentLocation = isCurrent
        return m
    }

    // MARK: - Helpers

    /// ISO 8601 with a colon in the timezone offset (e.g. "2026-06-21T07:12:00-03:00"), matching
    /// GadgetBridge's unixTimestampToISOWithColons.
    private func iso(_ unix: Int, tz: TimeZone) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = tz
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZZZZZ"
        return f.string(from: Date(timeIntervalSince1970: TimeInterval(unix)))
    }

    /// Location key in the band's "accu:<n>" form. The band only needs a stable key for the name;
    /// we replicate Java's String.hashCode so the value matches GadgetBridge's scheme.
    private func locationKey(_ name: String) -> String {
        var h: Int32 = 0
        for u in name.utf16 { h = h &* 31 &+ Int32(u) }
        let n = Int(h == Int32.min ? Int32.max : abs(h)) % 1_000_000
        return "accu:\(n)"
    }

    /// km/h → Beaufort scale (0–12).
    private static func beaufort(kmh: Double) -> Int32 {
        switch kmh {
        case ..<1:    return 0
        case ..<6:    return 1
        case ..<12:   return 2
        case ..<20:   return 3
        case ..<29:   return 4
        case ..<39:   return 5
        case ..<50:   return 6
        case ..<62:   return 7
        case ..<75:   return 8
        case ..<89:   return 9
        case ..<103:  return 10
        case ..<118:  return 11
        default:      return 12
        }
    }

    /// WMO weather code (Open-Meteo) → Xiaomi condition code (GadgetBridge XiaomiWeatherConditions).
    /// Unknown codes fall back to OVERCAST (2) — a safe, always-mappable icon.
    private static func xiaomiCondition(wmo: Int) -> Int {
        switch wmo {
        case 0:            return 0   // CLEAR_SKY
        case 1, 2:         return 1   // CLOUDY (mainly clear / partly cloudy)
        case 3:            return 2   // OVERCAST
        case 45, 48:       return 18  // MIST (fog)
        case 51, 53, 55:   return 3   // SHOWER (drizzle)
        case 56, 57:       return 19  // FREEZING_RAIN
        case 61:           return 7   // LIGHT_RAIN
        case 63:           return 8   // MODERATE_RAIN
        case 65:           return 9   // HEAVY_RAINFALL
        case 66, 67:       return 19  // FREEZING_RAIN
        case 71, 77:       return 14  // LIGHT_SNOW
        case 73:           return 15  // MODERATE_SNOW
        case 75:           return 16  // HEAVY_SNOW
        case 80, 81:       return 3   // SHOWER
        case 82:           return 9   // HEAVY_RAINFALL
        case 85, 86:       return 13  // SNOW_SHOWERS
        case 95, 96, 99:   return 4   // THUNDERSTORM
        default:           return 2   // OVERCAST
        }
    }
}

// MARK: - CLLocationManagerDelegate
//
// Callbacks are nonisolated (CoreLocation calls on an arbitrary queue) and hop to the main actor to
// settle the in-flight one-shot fix. A new authorization grant retries any waiter immediately.

extension WeatherSyncService: CLLocationManagerDelegate {

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let last = locations.last
        Task { @MainActor in self.finishFix(last) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in self.finishFix(self.locationManager.location) }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            if status == .authorizedWhenInUse || status == .authorizedAlways, self.isRequestingFix {
                self.locationManager.requestLocation()
            }
        }
    }
}

// MARK: - Workout weather

/// Raw conditions for an HKWorkout. The WMO code is mapped to HKWeatherCondition in HealthKitManager
/// (which owns the HealthKit dependency); this stays framework-agnostic.
struct WorkoutWeather {
    let wmoCode: Int
    let temperatureC: Double
    let humidityPct: Double
}

// MARK: - Open-Meteo response model

private struct OpenMeteoResponse: Decodable {
    let utcOffsetSeconds: Int
    let current: Current
    let daily: Daily

    struct Current: Decodable {
        let time: Int
        let temperature2M: Double
        let relativeHumidity2M: Double
        let weatherCode: Int
        let surfacePressure: Double
        let windSpeed10M: Double
        let windDirection10M: Double
    }

    struct Daily: Decodable {
        let time: [Int]
        let weatherCode: [Int]
        let temperature2MMax: [Double]
        let temperature2MMin: [Double]
        let sunrise: [Int]
        let sunset: [Int]
        let uvIndexMax: [Double]
    }
}
