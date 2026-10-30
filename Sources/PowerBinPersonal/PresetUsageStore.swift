import Combine
import Foundation

final class PresetUsageStore: ObservableObject {
    private struct UsageRecord: Codable {
        var count: Int
        var lastUsedAt: Date
    }

    @Published private var records: [String: UsageRecord] = [:]

    private let defaults: UserDefaults
    private let storageKey = "presetUsageRecords.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: storageKey),
           let decoded = try? JSONDecoder().decode([String: UsageRecord].self, from: data) {
            records = decoded
        }
    }

    func recordUse(_ item: LibraryPreset) {
        var record = records[item.id] ?? UsageRecord(count: 0, lastUsedAt: .distantPast)
        record.count += 1
        record.lastUsedAt = Date()
        records[item.id] = record
        persist()
    }

    func count(for item: LibraryPreset) -> Int {
        records[item.id]?.count ?? 0
    }

    func lastUsedAt(for item: LibraryPreset) -> Date? {
        records[item.id]?.lastUsedAt
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(records) else { return }
        defaults.set(data, forKey: storageKey)
    }
}
