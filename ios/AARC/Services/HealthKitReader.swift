import Foundation
import HealthKit
import CoreLocation
import AARCKit

/// iPhone-side read-only window into HealthKit. The watch is the writer;
/// the phone reads workouts back to render history and to denormalise
/// snapshot fields onto our local `RunRecord`s.
actor HealthKitReader {
    static let shared = HealthKitReader()

    private let store: HKHealthStore

    init(store: HKHealthStore = HKHealthStore()) {
        self.store = store
    }

    /// A Sendable snapshot of a HealthKit running workout — extracted
    /// inside the actor so the non-Sendable HKWorkout never escapes.
    struct WorkoutSummary: Sendable, Identifiable {
        let uuid: UUID
        let start: Date
        let end: Date
        let distanceMeters: Double
        let energyKcal: Double
        let runTypeRaw: String
        let isTest: Bool
        let aarcRunId: UUID?
        var id: UUID { uuid }
        var durationSeconds: Double { end.timeIntervalSince(start) }
    }

    /// All running workouts in Apple Health from the last `days` days,
    /// newest first. Used by the "Import from Apple Health" recovery to find
    /// runs the watch saved that AARC never recorded (e.g. when the phone↔
    /// watch link broke mid-run).
    func recentRunningWorkouts(days: Int = 60) async -> [WorkoutSummary] {
        let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)
        let datePred = HKQuery.predicateForSamples(withStart: cutoff, end: nil)
        let runPred = HKQuery.predicateForWorkouts(with: .running)
        let pred = NSCompoundPredicate(andPredicateWithSubpredicates: [datePred, runPred])
        guard let samples = try? await sample(
            of: HKObjectType.workoutType(), predicate: pred, limit: HKObjectQueryNoLimit) else { return [] }
        return samples.compactMap { $0 as? HKWorkout }.map { w in
            WorkoutSummary(uuid: w.uuid, start: w.startDate, end: w.endDate,
                           distanceMeters: distanceMeters(w), energyKcal: energyKcal(w),
                           runTypeRaw: runType(w).rawValue, isTest: isTestData(w),
                           aarcRunId: aarcRunId(w))
        }.sorted { $0.start > $1.start }
    }

    /// Try to fetch a specific HK workout by UUID. Returns nil if HK
    /// hasn't yet propagated the workout from the watch (this can take
    /// a few seconds after `finishWorkout`).
    func fetchWorkout(uuid: UUID) async throws -> HKWorkout? {
        let predicate = HKQuery.predicateForObject(with: uuid)
        let workouts = try await sample(of: HKObjectType.workoutType(), predicate: predicate, limit: 1)
        return workouts.first as? HKWorkout
    }

    /// Whether HK currently holds a workout with this UUID. Lets callers
    /// distinguish "workout not yet propagated from the watch" (skip /
    /// retry later) from "workout exists but has no sample series"
    /// (proceed) without taking ownership of the non-Sendable HKWorkout.
    func workoutExists(uuid: UUID) async -> Bool {
        ((try? await fetchWorkout(uuid: uuid)) ?? nil) != nil
    }

    /// Try repeatedly with backoff. The watch's `finishWorkout` returns
    /// the UUID before the workout is necessarily queryable from the
    /// phone over HK sync. ~5s is enough in practice.
    func fetchWorkoutWithRetry(uuid: UUID, attempts: Int = 6) async throws -> HKWorkout? {
        for attempt in 0..<attempts {
            if let w = try? await fetchWorkout(uuid: uuid) {
                return w
            }
            if attempt < attempts - 1 {
                try? await Task.sleep(for: .seconds(1))
            }
        }
        return nil
    }

    /// A single (timestamp, value) point. Used for chart series.
    struct SeriesPoint: Identifiable, Sendable, Hashable {
        public let id = UUID()
        public let timestamp: Date
        public let value: Double
    }

    /// HR samples during a workout, ordered by time. Each sample is a
    /// distinct reading from the watch sensor (typically every few seconds
    /// during an active workout).
    func fetchHeartRateSeries(during workout: HKWorkout) async throws -> [SeriesPoint] {
        let pred = HKQuery.predicateForSamples(
            withStart: workout.startDate,
            end: workout.endDate,
            options: .strictStartDate
        )
        let samples = try await sample(of: HKQuantityType(.heartRate), predicate: pred, limit: HKObjectQueryNoLimit)
        let bpm = HKUnit(from: "count/min")
        return samples
            .compactMap { $0 as? HKQuantitySample }
            .map { SeriesPoint(timestamp: $0.startDate, value: $0.quantity.doubleValue(for: bpm)) }
            .sorted { $0.timestamp < $1.timestamp }
    }

    /// Per-minute bucketed pace (seconds per kilometre), derived from the
    /// HK distance series during the workout. Empty buckets are skipped.
    func fetchPaceSeries(during workout: HKWorkout, bucketSeconds: TimeInterval = 60) async throws -> [SeriesPoint] {
        let pred = HKQuery.predicateForSamples(
            withStart: workout.startDate,
            end: workout.endDate,
            options: .strictStartDate
        )
        let interval = DateComponents(second: Int(bucketSeconds))
        let buckets: [(Date, Double)] = try await withCheckedThrowingContinuation { continuation in
            let q = HKStatisticsCollectionQuery(
                quantityType: HKQuantityType(.distanceWalkingRunning),
                quantitySamplePredicate: pred,
                options: .cumulativeSum,
                anchorDate: workout.startDate,
                intervalComponents: interval
            )
            q.initialResultsHandler = { _, results, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                var out: [(Date, Double)] = []
                results?.enumerateStatistics(from: workout.startDate, to: workout.endDate) { stats, _ in
                    let meters = stats.sumQuantity()?.doubleValue(for: .meter()) ?? 0
                    out.append((stats.startDate, meters))
                }
                continuation.resume(returning: out)
            }
            store.execute(q)
        }
        // Convert per-bucket distance to per-bucket pace (sec/km).
        return buckets.compactMap { (date, meters) in
            guard meters > 1 else { return nil }   // skip standing still
            let secPerKm = bucketSeconds / (meters / 1000)
            return SeriesPoint(timestamp: date, value: secPerKm)
        }
    }

    /// Per-km pace + HR splits, derived from HealthKit. Returns two
    /// arrays of equal length — one entry per *completed* kilometre.
    ///
    /// Algorithm:
    /// 1. Bucket the workout's distance-walking-running samples every
    ///    15 seconds (cumulative-sum statistics query) and accumulate
    ///    into a (time, cumulativeDistance) trace.
    /// 2. For each km boundary (1 km, 2 km, …, floor(totalDistance/1000) km)
    ///    linearly interpolate to find the time the runner crossed it.
    /// 3. paceSplits[i] = seconds between the (i-1)th and ith crossing
    ///    (or the workout start for i=0). That's literal sec/km.
    /// 4. hrSplits[i] = mean HR of all HR samples whose timestamp falls
    ///    inside that km's time window. 0 when no HR samples landed
    ///    (HR strap dropout, indoor watch off-wrist, etc.).
    ///
    /// Returns empty arrays for runs shorter than 1 km — there's no
    /// completed km to summarise.
    func fetchPerKmSplits(workout: HKWorkout) async throws -> (pace: [Double], hr: [Double]) {
        let totalDistance = distanceMeters(workout)
        guard totalDistance >= 1000 else { return ([], []) }

        // 1. Cumulative distance over time, finely bucketed for
        //    interpolation accuracy.
        let pred = HKQuery.predicateForSamples(
            withStart: workout.startDate,
            end: workout.endDate,
            options: .strictStartDate
        )
        let interval = DateComponents(second: 15)
        let buckets: [(Date, Double)] = try await withCheckedThrowingContinuation { continuation in
            let q = HKStatisticsCollectionQuery(
                quantityType: HKQuantityType(.distanceWalkingRunning),
                quantitySamplePredicate: pred,
                options: .cumulativeSum,
                anchorDate: workout.startDate,
                intervalComponents: interval
            )
            q.initialResultsHandler = { _, results, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                var out: [(Date, Double)] = []
                results?.enumerateStatistics(from: workout.startDate, to: workout.endDate) { stats, _ in
                    let meters = stats.sumQuantity()?.doubleValue(for: .meter()) ?? 0
                    out.append((stats.startDate, meters))
                }
                continuation.resume(returning: out)
            }
            store.execute(q)
        }

        // Compute cumulative.
        var cumulative: [(Date, Double)] = []
        var sum: Double = 0
        for (date, m) in buckets {
            sum += m
            cumulative.append((date, sum))
        }
        guard cumulative.count >= 2 else { return ([], []) }

        // 2. Interpolate time-of-crossing for each completed km.
        let totalKm = Int(totalDistance / 1000)
        guard totalKm >= 1 else { return ([], []) }
        var kmCrossings: [Date] = []
        for kmIdx in 1...totalKm {
            let target = Double(kmIdx) * 1000
            for i in 0..<(cumulative.count - 1) {
                let a = cumulative[i]
                let b = cumulative[i + 1]
                if a.1 < target && target <= b.1 {
                    let spanMeters = max(1, b.1 - a.1)
                    let frac = (target - a.1) / spanMeters
                    let dt = b.0.timeIntervalSince(a.0)
                    kmCrossings.append(a.0.addingTimeInterval(frac * dt))
                    break
                }
            }
        }
        guard !kmCrossings.isEmpty else { return ([], []) }

        // 3. Pace per km = time between crossings.
        var pace: [Double] = []
        var prev = workout.startDate
        for crossing in kmCrossings {
            pace.append(crossing.timeIntervalSince(prev))
            prev = crossing
        }

        // 4. HR per km = mean HR samples within each km's time window.
        let hrSamples = try await fetchHeartRateSeries(during: workout)
        var hr: [Double] = []
        var lastBoundary = workout.startDate
        for crossing in kmCrossings {
            let inWindow = hrSamples.filter { $0.timestamp >= lastBoundary && $0.timestamp < crossing }
            let avg: Double = inWindow.isEmpty
                ? 0
                : inWindow.map(\.value).reduce(0, +) / Double(inWindow.count)
            hr.append(avg)
            lastBoundary = crossing
        }

        return (pace, hr)
    }

    /// Fine-grained pace + HR splits, one entry per `bucketMeters` of
    /// distance (default 100 m). Spans the FULL run distance —
    /// including the partial last bucket — so the widget chart can
    /// extend all the way to the right edge instead of stopping at
    /// the last completed km.
    ///
    /// Algorithm is the same shape as fetchPerKmSplits but with finer
    /// distance bins and a denser 5-second time bucket on the
    /// underlying HK statistics query for accurate interpolation.
    /// Returns empty arrays for runs shorter than one bucket.
    func fetchFineSplits(
        workout: HKWorkout,
        bucketMeters: Double = 100
    ) async throws -> (pace: [Double], hr: [Double]) {
        let totalDistance = distanceMeters(workout)
        guard totalDistance >= bucketMeters else { return ([], []) }

        // 1. Cumulative distance over time at 5-second resolution.
        let pred = HKQuery.predicateForSamples(
            withStart: workout.startDate,
            end: workout.endDate,
            options: .strictStartDate
        )
        let interval = DateComponents(second: 5)
        let buckets: [(Date, Double)] = try await withCheckedThrowingContinuation { continuation in
            let q = HKStatisticsCollectionQuery(
                quantityType: HKQuantityType(.distanceWalkingRunning),
                quantitySamplePredicate: pred,
                options: .cumulativeSum,
                anchorDate: workout.startDate,
                intervalComponents: interval
            )
            q.initialResultsHandler = { _, results, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                var out: [(Date, Double)] = []
                results?.enumerateStatistics(from: workout.startDate, to: workout.endDate) { stats, _ in
                    let meters = stats.sumQuantity()?.doubleValue(for: .meter()) ?? 0
                    out.append((stats.startDate, meters))
                }
                continuation.resume(returning: out)
            }
            store.execute(q)
        }
        var cumulative: [(Date, Double)] = []
        var sum: Double = 0
        for (date, m) in buckets {
            sum += m
            cumulative.append((date, sum))
        }
        guard cumulative.count >= 2 else { return ([], []) }

        // 2. Interpolate the time of crossing each 100m boundary, AND
        //    the workout end as the trailing partial boundary. This
        //    way the last sub-km segment shows up in the chart.
        let bucketCount = Int(ceil(totalDistance / bucketMeters))
        var crossings: [Date] = []  // crossings[i] = end of bucket i (1-indexed boundary)
        for idx in 1...bucketCount {
            let target = min(Double(idx) * bucketMeters, totalDistance)
            var found: Date?
            for i in 0..<(cumulative.count - 1) {
                let a = cumulative[i]
                let b = cumulative[i + 1]
                if a.1 < target && target <= b.1 {
                    let spanMeters = max(1, b.1 - a.1)
                    let frac = (target - a.1) / spanMeters
                    let dt = b.0.timeIntervalSince(a.0)
                    found = a.0.addingTimeInterval(frac * dt)
                    break
                }
            }
            crossings.append(found ?? workout.endDate)
        }
        guard !crossings.isEmpty else { return ([], []) }

        // 3. Pace per bucket — time taken to cover that bucket's
        //    distance. For the last (possibly partial) bucket the
        //    distance < bucketMeters; we normalise it to sec/km the
        //    same way so the Y axis stays apples-to-apples.
        var pace: [Double] = []
        var prev = workout.startDate
        for (i, crossing) in crossings.enumerated() {
            let bucketStart = Double(i) * bucketMeters
            let bucketEnd = min(Double(i + 1) * bucketMeters, totalDistance)
            let bucketDistance = max(1, bucketEnd - bucketStart)
            let dt = crossing.timeIntervalSince(prev)
            // sec/km = dt / (bucketDistance / 1000) = dt * 1000 / bucketDistance
            pace.append(dt * 1000 / bucketDistance)
            prev = crossing
        }

        // 4. HR per bucket — mean of HR samples whose timestamp falls
        //    in the bucket's time window.
        let hrSamples = try await fetchHeartRateSeries(during: workout)
        var hr: [Double] = []
        var lastBoundary = workout.startDate
        for crossing in crossings {
            let inWindow = hrSamples.filter { $0.timestamp >= lastBoundary && $0.timestamp < crossing }
            let avg: Double = inWindow.isEmpty
                ? 0
                : inWindow.map(\.value).reduce(0, +) / Double(inWindow.count)
            hr.append(avg)
            lastBoundary = crossing
        }

        return (pace, hr)
    }

    /// One timestamped performance sample for the cloud-dashboard
    /// backfill: cumulative distance at time `t` (seconds since the
    /// workout start), with pace / speed / HR for that window when
    /// available. Any of pace / hr / speed may be nil (HR strap
    /// dropout, treadmill with no GPS speed, standing still, etc.).
    struct MetricsSample: Sendable {
        public let t: Double
        public let distanceMeters: Double
        public let paceSecPerKm: Double?
        public let speedMps: Double?
        public let hr: Double?
    }

    /// Convenience overload: look the workout up by UUID first (so the
    /// non-Sendable `HKWorkout` never leaves this actor) and return its
    /// metrics timeline. Returns [] when the workout isn't (yet) in HK.
    func fetchMetricsTimeline(
        uuid: UUID,
        bucketSeconds: TimeInterval = 30
    ) async throws -> [MetricsSample] {
        guard let workout = try await fetchWorkout(uuid: uuid) else { return [] }
        return try await fetchMetricsTimeline(workout: workout, bucketSeconds: bucketSeconds)
    }

    /// Build a coarse timestamped metrics timeline for a FINISHED
    /// workout, suitable for backfilling the dashboard's performance
    /// charts. Buckets the workout into `bucketSeconds` windows
    /// (default 30s) via a cumulative-sum distance statistics query,
    /// accumulates distance, derives per-bucket pace + speed from the
    /// distance covered in the window, and attaches the mean HR of any
    /// HR samples that fall inside the window.
    ///
    /// Resilient to sparse data: a window with no distance still emits
    /// (carrying forward cumulative distance, pace/speed nil) as long as
    /// it has HR; a workout with only HR and no distance still yields a
    /// usable HR trace. Returns [] only when neither distance nor HR is
    /// available at all.
    func fetchMetricsTimeline(
        workout: HKWorkout,
        bucketSeconds: TimeInterval = 30
    ) async throws -> [MetricsSample] {
        let start = workout.startDate
        let end = workout.endDate
        let pred = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)

        // Per-bucket distance (meters in that window) keyed by bucket start.
        let interval = DateComponents(second: Int(bucketSeconds))
        let distanceBuckets: [(Date, Double)] = (try? await withCheckedThrowingContinuation { continuation in
            let q = HKStatisticsCollectionQuery(
                quantityType: HKQuantityType(.distanceWalkingRunning),
                quantitySamplePredicate: pred,
                options: .cumulativeSum,
                anchorDate: start,
                intervalComponents: interval
            )
            q.initialResultsHandler = { _, results, error in
                if let error { continuation.resume(throwing: error); return }
                var out: [(Date, Double)] = []
                results?.enumerateStatistics(from: start, to: end) { stats, _ in
                    let meters = stats.sumQuantity()?.doubleValue(for: .meter()) ?? 0
                    out.append((stats.startDate, meters))
                }
                continuation.resume(returning: out)
            }
            store.execute(q)
        }) ?? []

        let hrSamples = (try? await fetchHeartRateSeries(during: workout)) ?? []

        // If we have no distance windows but DO have HR, synthesise
        // windows from HR sample times so we still emit an HR trace.
        var windowStarts: [Date] = distanceBuckets.map(\.0)
        if windowStarts.isEmpty {
            guard !hrSamples.isEmpty else { return [] }
            var cursor = start
            while cursor < end {
                windowStarts.append(cursor)
                cursor = cursor.addingTimeInterval(bucketSeconds)
            }
        }
        let distanceByStart = Dictionary(distanceBuckets, uniquingKeysWith: { a, _ in a })

        var out: [MetricsSample] = []
        var cumulative: Double = 0
        for (i, windowStart) in windowStarts.enumerated() {
            let windowEnd = (i + 1 < windowStarts.count) ? windowStarts[i + 1] : end
            let windowMeters = distanceByStart[windowStart] ?? 0
            cumulative += windowMeters
            let dt = max(1, windowEnd.timeIntervalSince(windowStart))

            let pace: Double? = windowMeters > 1 ? dt * 1000 / windowMeters : nil
            let speed: Double? = windowMeters > 1 ? windowMeters / dt : nil

            let inWindow = hrSamples.filter { $0.timestamp >= windowStart && $0.timestamp < windowEnd }
            let hr: Double? = inWindow.isEmpty
                ? nil
                : inWindow.map(\.value).reduce(0, +) / Double(inWindow.count)

            // Skip windows that carry no signal at all.
            if pace == nil && hr == nil && windowMeters <= 1 { continue }

            out.append(MetricsSample(
                t: windowStart.timeIntervalSince(start),
                distanceMeters: cumulative,
                paceSecPerKm: pace,
                speedMps: speed,
                hr: hr
            ))
        }
        return out
    }

    /// All locations on the workout's route, ordered by time.
    func fetchRoute(for workout: HKWorkout) async throws -> [CLLocation] {
        // 1. Find the route series associated with this workout.
        let routePredicate = HKQuery.predicateForObjects(from: workout)
        let routeType = HKSeriesType.workoutRoute()
        let routes = try await sample(of: routeType, predicate: routePredicate, limit: HKObjectQueryNoLimit)
        guard let route = routes.first as? HKWorkoutRoute else { return [] }

        // 2. Stream all CLLocations off that series.
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[CLLocation], Error>) in
            var collected: [CLLocation] = []
            let query = HKWorkoutRouteQuery(route: route) { _, locations, done, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                if let locations { collected.append(contentsOf: locations) }
                if done {
                    continuation.resume(returning: collected.sorted(by: { $0.timestamp < $1.timestamp }))
                }
            }
            store.execute(query)
        }
    }

    // MARK: - Helpers

    /// Read distance from a finished workout (post-iOS 16 API).
    nonisolated func distanceMeters(_ workout: HKWorkout) -> Double {
        workout
            .statistics(for: HKQuantityType(.distanceWalkingRunning))?
            .sumQuantity()?
            .doubleValue(for: .meter()) ?? 0
    }

    nonisolated func energyKcal(_ workout: HKWorkout) -> Double {
        workout
            .statistics(for: HKQuantityType(.activeEnergyBurned))?
            .sumQuantity()?
            .doubleValue(for: .kilocalorie()) ?? 0
    }

    /// "outdoor" / "treadmill" derived from the workout's HK metadata.
    nonisolated func runType(_ workout: HKWorkout) -> RunType {
        let isIndoor = (workout.metadata?[HKMetadataKeyIndoorWorkout] as? Bool) ?? false
        return isIndoor ? .treadmill : .outdoor
    }

    /// True if AARC stamped this workout with the test-data marker.
    nonisolated func isTestData(_ workout: HKWorkout) -> Bool {
        (workout.metadata?[HKMetadataKeys.testData] as? Bool) ?? false
    }

    /// AARC's runId stamped at finalise, if present.
    nonisolated func aarcRunId(_ workout: HKWorkout) -> UUID? {
        guard let s = workout.metadata?[HKMetadataKeys.runId] as? String else { return nil }
        return UUID(uuidString: s)
    }

    /// Delete the workout (and any associated route / samples HK
    /// cascades) by UUID. Returns true if a workout was found and the
    /// delete succeeded; false if HK couldn't find it (e.g. the user
    /// already removed it from Apple Fitness or Health).
    @discardableResult
    func deleteWorkout(uuid: UUID) async throws -> Bool {
        guard let workout = try await fetchWorkout(uuid: uuid) else {
            return false
        }
        try await store.delete(workout)
        return true
    }

    private func sample(of type: HKSampleType, predicate: NSPredicate, limit: Int) async throws -> [HKSample] {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[HKSample], Error>) in
            let query = HKSampleQuery(
                sampleType: type,
                predicate: predicate,
                limit: limit,
                sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)]
            ) { _, samples, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                continuation.resume(returning: samples ?? [])
            }
            store.execute(query)
        }
    }
}
