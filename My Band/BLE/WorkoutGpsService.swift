import CoreLocation
import OSLog

// MARK: - WorkoutGpsService
//
// Handles the GPS handshake between the band and the phone during workouts.
//
// Protocol (GadgetBridge XiaomiHealthService):
//   Band → app : workoutOpenWatch  (type=8, subtype=30)  — repeated every ~1 s while waiting
//   App  → band: workoutOpenReply  (type=8, subtype=30)  — {3,2,10} = no GPS / {0,2,2} = GPS fix ready
//   App  → band: workoutLocation   (type=8, subtype=48)  — streamed once per fix, only after workout started
//   Band → app : workoutStatusWatch(type=8, subtype=26)  — status 0=started, 1=resumed, 2=paused, 3=finished
//
// Without a reply to workoutOpenWatch the band hangs indefinitely at "waiting for GPS".

@Observable
@MainActor
final class WorkoutGpsService: NSObject {

    private(set) var isActive = false

    /// Fired when the band reports a workout has finished (workoutStatusWatch, status=finished).
    /// Carries the workout's activity file ids straight from the status message (concatenated
    /// 7-byte ids; empty if the firmware omitted them) so BandSyncer can fetch exactly those
    /// files instead of re-listing the whole backlog.
    var onWorkoutFinished: ((Data) -> Void)?

    /// Fired ~3 minutes after a strength workout finishes, carrying the strength workout's start (to
    /// correlate with the workout) plus the continuously-measured post-workout heart-rate recovery
    /// samples. BandSyncer appends them to the (window-extended) strength workout's HR graph.
    var onRecoveryHRRecorded: ((_ strengthStart: Date?, _ samples: [WorkoutHRSample]) -> Void)?

    /// The just-finished strength workout's start, set at finish and cleared when the recovery
    /// capture completes. BandSyncer reads it during the post-workout sync to extend that workout's
    /// window by the recovery length, so the recovery HR (appended later) falls inside it.
    private(set) var recoveryPendingStrengthStart: Date?

    private weak var bandManager: BandManager?
    private let locationManager = CLLocationManager()
    private let log = AppLogger(category: "GPS")

    private var gpsFixAcquired = false
    private var workoutStarted = false

    // MARK: - Local recording (app-owned, not streamed to the band)
    //
    // Two app-owned captures for strength training (which has no band-side GPS file), entirely
    // separate from the outdoor path (isActive/streamToBand) — for strength we still reply "GPS
    // disabled" to the band, so its handshake is untouched:
    //   .strength — a SPARSE GPS route during the workout (1 recorded point / 10 min).
    //   .recovery — after the workout, 3 min of continuous HEART RATE (realtime stats), NOT GPS.
    //               Location stays on only as a background keep-alive; it is not recorded.

    private enum LocalMode { case none, strength, recovery }
    private var localMode: LocalMode = .none
    private var localStart: Date?
    private var localRoute: [WorkoutTrackPoint] = []
    private var recoveryHR: [WorkoutHRSample] = []
    private var pendingStrengthStart = false
    private var recoveryTimer: Task<Void, Never>?

    /// Sparse strength routes stashed at finish, keyed by the app-side start epoch, for BandSyncer to
    /// attach to the strength HKWorkout during the sync that same finish triggers.
    private(set) var recordedStrengthRoutes: [Int: [WorkoutTrackPoint]] = [:]

    /// The sparse-GPS cadence for strength: one recorded point every 10 minutes.
    private let strengthFixInterval: TimeInterval = 600
    static let recoveryDuration: TimeInterval = 180
    private var recoveryDuration: TimeInterval { Self.recoveryDuration }

    // MARK: - Setup

    func setup(manager: BandManager) {
        bandManager = manager

        manager.onWorkoutOpenWatch = { [weak self] sport in
            Task { @MainActor in self?.handleWorkoutOpen(sport: sport) }
        }
        manager.onWorkoutStatusWatch = { [weak self] status, fileIds in
            Task { @MainActor in self?.handleWorkoutStatus(status, fileIds: fileIds) }
        }
        manager.onRealtimeStats = { [weak self] hr in
            Task { @MainActor in self?.ingestRecoveryHR(hr) }
        }

        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyBest
        // No distance gate: deliver every fix CoreLocation computes (~1 Hz) so the band records a
        // smooth, time-uniform track. A distance filter (e.g. 5 m) ties the cadence to pace and
        // emits nothing while stopped/slow, which left the recorded route sparse.
        locationManager.distanceFilter  = kCLDistanceFilterNone
        // Required so the GPS stream keeps flowing while the user looks at the band, not the
        // phone. Only takes effect once the user grants "Always Allow"; with "While Using" the
        // stream pauses when the app backgrounds and the band shows "GPS lost".
        locationManager.allowsBackgroundLocationUpdates = true
        locationManager.pausesLocationUpdatesAutomatically = false
        locationManager.showsBackgroundLocationIndicator = true
    }

    // MARK: - Incoming band commands

    private func handleWorkoutOpen(sport: UInt32) {
        log.debug("Workout open request (sport=\(sport))")

        // Skip GPS for indoor / stationary sports (strength, yoga, pool, machines…). Reply "GPS
        // disabled" so the band starts immediately without waiting for a fix it won't record, and
        // never start CoreLocation. Unknown sport codes fall through to the GPS path — safer to give
        // an unrecognised outdoor sport its route than to silently drop it.
        if let kind = WorkoutSummaryParser.workoutKind(fromCode: Int(sport)), !kind.usesGps {
            log.info("Workout sport=\(sport) (\(String(describing: kind))) doesn't use GPS — replying disabled")
            replyGpsDisabled()
            // Strength training still gets an app-recorded sparse route + a cooldown trace, without
            // ever telling the band we have GPS (the reply above stays "disabled"). The band re-sends
            // workoutOpenWatch every ~5 s; startStrengthRecording is idempotent.
            if kind == .strengthTraining { startStrengthRecording() }
            return
        }

        let authStatus = locationManager.authorizationStatus

        switch authStatus {
        case .notDetermined:
            // Two-step prompt: must ask `WhenInUse` first, and iOS only allows the upgrade to
            // `Always` once the WhenInUse prompt has been answered. We trigger the first prompt
            // here; the upgrade is requested in locationManagerDidChangeAuthorization once iOS
            // moves to `authorizedWhenInUse`. The band keeps re-sending workoutOpenWatch every
            // ~1 s, so a new handleWorkoutOpen call will reach the .authorizedAlways branch
            // below shortly after the user accepts.
            log.info("Location not determined — requesting WhenInUse authorization")
            isActive       = true
            gpsFixAcquired = false
            workoutStarted = false
            locationManager.requestWhenInUseAuthorization()

        case .authorizedWhenInUse:
            log.info("Have WhenInUse — requesting upgrade to Always for background GPS stream")
            locationManager.requestAlwaysAuthorization()
            if !isActive {
                isActive       = true
                gpsFixAcquired = false
                workoutStarted = false
                locationManager.startUpdatingLocation()
            }

        case .authorizedAlways:
            if !isActive {
                isActive       = true
                gpsFixAcquired = false
                workoutStarted = false
                log.info("Starting CoreLocation for workout (sport=\(sport))")
                locationManager.startUpdatingLocation()
            }
            // No reply yet — wait for first fix; onLocation sends the GPS-ready reply.

        case .denied, .restricted:
            log.info("Location denied/restricted — replying GPS disabled")
            replyGpsDisabled()

        @unknown default:
            replyGpsDisabled()
        }
    }

    private func handleWorkoutStatus(_ status: UInt32, fileIds: Data) {
        // Proto WorkoutStatusWatch.status: 0=started, 1=resumed, 2=paused, 3=finished
        switch status {
        case 0, 1:
            if localMode == .strength {
                // Anchor the workout start; the continuous stream (already running) records the first
                // point now and then one every strengthFixInterval.
                if localStart == nil {
                    localStart = Date()
                    log.info("Strength workout started — recording sparse GPS")
                }
            } else {
                log.info("Workout started/resumed — GPS stream active")
                workoutStarted = true
            }
        case 2:
            // Paused — keep CoreLocation running so a resume gets an instant fix, but stop
            // forwarding locations so the band doesn't fold paused-period drift into the
            // workout's distance and route. Strength (sparse) just keeps recording — harmless.
            if localMode == .none {
                log.info("Workout paused — holding GPS stream")
                workoutStarted = false
            }
        case 3:
            if localMode == .strength {
                finalizeStrengthAndStartRecovery(fileIds: fileIds)
            } else {
                log.info("Workout finished — stopping GPS")
                stopGps()
                onWorkoutFinished?(fileIds)
            }
        default:
            break
        }
    }

    // MARK: - Strength recording + cooldown

    private func startStrengthRecording() {
        guard localMode == .none else { return }   // already recording (band re-sends open every ~5 s)
        switch locationManager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            beginStrengthRecording()
        case .notDetermined:
            pendingStrengthStart = true
            locationManager.requestWhenInUseAuthorization()
        default:
            log.info("Location denied — strength workout recorded without GPS")
        }
    }

    private func beginStrengthRecording() {
        localMode = .strength
        localStart = nil                 // set at status=started
        localRoute = []
        // Continuous updates — NOT requestLocation. One-shot requestLocation doesn't deliver reliably
        // in the background (phone in pocket during the workout), which left the route with a single
        // point; startUpdatingLocation (the mechanism the cooldown already proved) keeps delivering
        // via allowsBackgroundLocationUpdates. Recording is throttled to strengthFixInterval, so the
        // cadence stays sparse even though the stream is continuous. Coarse accuracy saves power.
        locationManager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        log.info("Strength GPS armed — recording one point every \(Int(self.strengthFixInterval / 60)) min")
        locationManager.startUpdatingLocation()
    }

    private func finalizeStrengthAndStartRecovery(fileIds: Data) {
        // Close the sparse GPS route with a final fix so even a short workout (shorter than the
        // 10-min cadence) has a start + end point — the throttle records only the first point
        // otherwise, and an HKWorkoutRoute needs 2. The continuous stream keeps locationManager
        // .location fresh, so this end point has a distinct timestamp.
        let strengthStart = localStart
        if let last = locationManager.location, localStart != nil {
            localRoute.append(WorkoutTrackPoint(date: last.timestamp,
                                                latitude: last.coordinate.latitude,
                                                longitude: last.coordinate.longitude,
                                                hdop: nil,
                                                speed: last.speed >= 0 ? last.speed : nil))
        }
        if let start = strengthStart, localRoute.count >= 2 {
            recordedStrengthRoutes[Int(start.timeIntervalSince1970)] = localRoute
            log.info("Strength GPS: stashed \(self.localRoute.count) point(s) for the workout")
        } else {
            log.info("Strength GPS: \(self.localRoute.count) point(s) — too few for a route (no fix / very short)")
        }

        // recoveryPendingStrengthStart lets the post-workout sync extend this workout's window so the
        // recovery HR (appended when the capture completes) falls inside it.
        recoveryPendingStrengthStart = strengthStart
        onWorkoutFinished?(fileIds)
        startRecoveryCapture(strengthStart: strengthStart)
    }

    private func startRecoveryCapture(strengthStart: Date?) {
        // 3 minutes of continuous post-workout HEART RATE via realtime stats — the recovery curve.
        // No GPS is recorded here; location stays on ONLY as a background keep-alive (the proven way
        // to keep the app running for 3 min in the background), and recordLocalFix ignores .recovery.
        localMode = .recovery
        localStart = Date()
        recoveryHR = []
        locationManager.startUpdatingLocation()
        bandManager?.setRealtimeStats(enabled: true)
        log.info("Strength finished — recording \(Int(self.recoveryDuration))-s HR recovery (realtime)")
        recoveryTimer?.cancel()
        recoveryTimer = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(self?.recoveryDuration ?? 180))
            guard let self, !Task.isCancelled else { return }
            let samples = self.recoveryHR
            self.bandManager?.setRealtimeStats(enabled: false)
            self.stopLocalRecording()
            self.recoveryPendingStrengthStart = nil
            self.log.info("HR recovery done — \(samples.count) sample(s)")
            self.onRecoveryHRRecorded?(strengthStart, samples)
        }
    }

    /// Live realtime HR while a recovery capture is running — timestamped on receipt (the events
    /// carry no timestamp). Physiological guard drops obviously bad values.
    private func ingestRecoveryHR(_ hr: Int) {
        guard localMode == .recovery, (30...240).contains(hr) else { return }
        recoveryHR.append(WorkoutHRSample(date: Date(), bpm: hr))
    }

    private func recordLocalFix(_ loc: CLLocation) {
        // Only the strength workout records GPS; .recovery keeps location on purely as a keep-alive.
        guard localMode == .strength, localStart != nil else { return }
        // Sparse cadence: the first point, then one every strengthFixInterval.
        if let last = localRoute.last,
           loc.timestamp.timeIntervalSince(last.date) < strengthFixInterval { return }
        localRoute.append(WorkoutTrackPoint(
            date: loc.timestamp,
            latitude: loc.coordinate.latitude,
            longitude: loc.coordinate.longitude,
            hdop: nil,
            speed: loc.speed >= 0 ? loc.speed : nil))
    }

    private func stopLocalRecording() {
        recoveryTimer?.cancel(); recoveryTimer = nil
        locationManager.stopUpdatingLocation()
        localMode = .none
        localStart = nil
        localRoute = []
        recoveryHR = []
    }

    /// Hands the stashed strength routes to BandSyncer and clears them (one-shot).
    func consumeStrengthRoutes() -> [Int: [WorkoutTrackPoint]] {
        let routes = recordedStrengthRoutes
        recordedStrengthRoutes = [:]
        return routes
    }

    // MARK: - GPS reply helpers

    private func replyGpsDisabled() {
        bandManager?.sendEncryptedCommand(protoBytes: XiaomiProto.workoutOpenReplyCommand(gpsReady: false))
    }

    private func replyGpsReady() {
        bandManager?.sendEncryptedCommand(protoBytes: XiaomiProto.workoutOpenReplyCommand(gpsReady: true))
    }

    private func stopGps() {
        isActive       = false
        gpsFixAcquired = false
        workoutStarted = false
        locationManager.stopUpdatingLocation()
    }
}

// MARK: - CLLocationManagerDelegate

extension WorkoutGpsService: CLLocationManagerDelegate {

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else { return }
        Task { @MainActor [weak self] in self?.onLocation(loc) }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor [weak self] in
            guard let self else { return }
            // A strength workout was waiting on this grant to start recording.
            if self.pendingStrengthStart,
               status == .authorizedWhenInUse || status == .authorizedAlways {
                self.pendingStrengthStart = false
                self.beginStrengthRecording()
            }
            switch status {
            case .authorizedWhenInUse:
                // First prompt accepted; immediately ask for the upgrade to Always so the GPS
                // stream survives the screen locking / app backgrounding during the workout.
                if self.isActive {
                    self.log.info("WhenInUse granted — requesting upgrade to Always")
                    manager.requestAlwaysAuthorization()
                    manager.startUpdatingLocation()
                }
            case .authorizedAlways:
                if self.isActive { manager.startUpdatingLocation() }
            case .denied, .restricted:
                if self.isActive { self.replyGpsDisabled() }
                self.pendingStrengthStart = false
            default:
                break
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.log.error("CoreLocation error: \(error.localizedDescription)")
            if self.isActive && !self.gpsFixAcquired { self.replyGpsDisabled() }
        }
    }

    @MainActor
    private func onLocation(_ loc: CLLocation) {
        // Strength/cooldown record locally and never touch the band; the outdoor path is isActive.
        if !isActive {
            if localMode != .none { recordLocalFix(loc) }
            return
        }

        if !gpsFixAcquired {
            gpsFixAcquired = true
            log.info("GPS fix acquired — replying GPS ready to band")
            replyGpsReady()
        }

        guard workoutStarted else { return }

        let ts = UInt32(loc.timestamp.timeIntervalSince1970)
        let proto = XiaomiProto.workoutLocationCommand(
            timestamp: ts,
            latitude:  loc.coordinate.latitude,
            longitude: loc.coordinate.longitude,
            altitude:  loc.altitude,
            speed:     Float(loc.speed >= 0 ? loc.speed : 0),
            bearing:   Float(loc.course >= 0 ? loc.course : 0)
        )
        bandManager?.sendEncryptedCommand(protoBytes: proto)
        log.debug("GPS location sent: (\(loc.coordinate.latitude, privacy: .private), \(loc.coordinate.longitude, privacy: .private))")
    }
}
