import Foundation
import SwiftData

// Phase 0 placeholder schema, fleshed out in §1.9.
// See docs/data-model.md for the full target shape.

@Model
final class RunRecord {
    @Attribute(.unique) var id: UUID
    var startedAt: Date
    var endedAt: Date?
    var personality: String
    /// Apple Health's UUID for the corresponding workout. Source of
    /// truth for sample data (route, HR series, etc.) — fetched on
    /// demand rather than duplicated locally.
    var healthKitWorkoutUUID: UUID?
    /// True for runs recorded while either safety mode was on (D19).
    /// Drives the "TEST" badge in History and is the link key for cleanup.
    var isTestData: Bool = false

    /// "outdoor" or "treadmill". Stored as raw string for SwiftData
    /// schema simplicity; convert to/from `AARCKit.RunType` at the edges.
    var runTypeRaw: String = "outdoor"

    // Denormalised snapshot from HealthKit, for fast list rendering
    // without re-querying HK on every row. Refreshed on save.
    var cachedDistanceMeters: Double = 0
    var cachedDurationSeconds: Double = 0
    var cachedAvgPaceSecPerKm: Double = 0
    var cachedEnergyKcal: Double = 0

    init(
        id: UUID = UUID(),
        startedAt: Date = .now,
        endedAt: Date? = nil,
        personality: String,
        isTestData: Bool = false,
        healthKitWorkoutUUID: UUID? = nil,
        runTypeRaw: String = "outdoor",
        cachedDistanceMeters: Double = 0,
        cachedDurationSeconds: Double = 0,
        cachedAvgPaceSecPerKm: Double = 0,
        cachedEnergyKcal: Double = 0
    ) {
        self.id = id
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.personality = personality
        self.isTestData = isTestData
        self.healthKitWorkoutUUID = healthKitWorkoutUUID
        self.runTypeRaw = runTypeRaw
        self.cachedDistanceMeters = cachedDistanceMeters
        self.cachedDurationSeconds = cachedDurationSeconds
        self.cachedAvgPaceSecPerKm = cachedAvgPaceSecPerKm
        self.cachedEnergyKcal = cachedEnergyKcal
    }
}

@Model
final class ScriptRecord {
    @Attribute(.unique) var id: UUID
    var runId: UUID
    var personality: String
    var generatedAt: Date
    var model: String

    init(id: UUID = UUID(), runId: UUID, personality: String, model: String) {
        self.id = id
        self.runId = runId
        self.personality = personality
        self.generatedAt = .now
        self.model = model
    }
}

@Model
final class ScriptMessageRecord {
    @Attribute(.unique) var id: UUID
    var scriptId: UUID
    var text: String
    var triggerSpec: String
    var priority: Int
    var playOnce: Bool

    init(id: UUID = UUID(), scriptId: UUID, text: String, triggerSpec: String, priority: Int = 50, playOnce: Bool = true) {
        self.id = id
        self.scriptId = scriptId
        self.text = text
        self.triggerSpec = triggerSpec
        self.priority = priority
        self.playOnce = playOnce
    }
}

@Model
final class VoiceNoteRecord {
    @Attribute(.unique) var id: UUID
    var runId: UUID
    var recordedAt: Date
    var audioFilePath: String
    var transcript: String?

    init(id: UUID = UUID(), runId: UUID, audioFilePath: String) {
        self.id = id
        self.runId = runId
        self.recordedAt = .now
        self.audioFilePath = audioFilePath
    }
}

@Model
final class AiReplyRecord {
    @Attribute(.unique) var id: UUID
    var voiceNoteId: UUID
    var replyText: String
    var requestedAt: Date
    var respondedAt: Date?
    var model: String

    init(id: UUID = UUID(), voiceNoteId: UUID, replyText: String, model: String) {
        self.id = id
        self.voiceNoteId = voiceNoteId
        self.replyText = replyText
        self.requestedAt = .now
        self.model = model
    }
}

@Model
final class UserMemoryRecord {
    @Attribute(.unique) var id: UUID
    var key: String
    var value: String
    var confidence: Double
    var source: String
    var updatedAt: Date

    init(id: UUID = UUID(), key: String, value: String, confidence: Double = 1.0, source: String = "user") {
        self.id = id
        self.key = key
        self.value = value
        self.confidence = confidence
        self.source = source
        self.updatedAt = .now
    }
}
