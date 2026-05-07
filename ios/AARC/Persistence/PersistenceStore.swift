import Foundation
import SwiftData

/// SwiftData container holding companion-only data. Workout truth lives in HealthKit.
@MainActor
final class PersistenceStore {
    static let shared = PersistenceStore()

    let container: ModelContainer

    private init() {
        let schema = Schema(Self.allModels)
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
        do {
            self.container = try ModelContainer(for: schema, configurations: [config])
        } catch {
            fatalError("Failed to initialise SwiftData container: \(error)")
        }
    }

    private static let allModels: [any PersistentModel.Type] = [
        RunRecord.self,
        ScriptRecord.self,
        ScriptMessageRecord.self,
        VoiceNoteRecord.self,
        AiReplyRecord.self,
        UserMemoryRecord.self,
    ]
}
