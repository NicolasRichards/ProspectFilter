import Foundation
import Combine

struct FilterSet: Codable, Equatable {
    var minPA: Double = 50
    var minIP: Double = 20
    var batterFilters: [BatterFilter] = []
    var pitcherFilters: [PitcherFilter] = []
}

final class FilterStore: ObservableObject {
    @Published var filters: FilterSet {
        didSet { save() }
    }

    private static var fileURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("prospect_filters.json")
    }

    init() {
        if let data = try? Data(contentsOf: Self.fileURL),
           let decoded = try? JSONDecoder().decode(FilterSet.self, from: data) {
            filters = decoded
        } else {
            filters = FilterSet()
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(filters) {
            try? data.write(to: Self.fileURL)
        }
    }
}
