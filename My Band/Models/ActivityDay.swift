import Foundation
import SwiftData

@Model
final class ActivityDay {

    var id: UUID
    /// Stored as midnight UTC of the day
    var date: Date
    var steps: Int
    var calories: Double
    var distanceMeters: Double
    var activeMinutes: Int
    var walkingHeartRateAvg: Int? = nil
    var healthKitSynced: Bool

    var device: BandDevice?

    init(date: Date, steps: Int = 0, calories: Double = 0, distanceMeters: Double = 0, activeMinutes: Int = 0, walkingHeartRateAvg: Int? = nil) {
        self.id = UUID()
        self.date = Calendar.current.startOfDay(for: date)
        self.steps = steps
        self.calories = calories
        self.distanceMeters = distanceMeters
        self.activeMinutes = activeMinutes
        self.walkingHeartRateAvg = walkingHeartRateAvg
        self.healthKitSynced = false
    }
}
