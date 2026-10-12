import Foundation
import Testing
@testable import textual

struct MoodStatsTests {
    @Test func moodCountsRespectHistoryFiltersAndDeduplicateTags() throws {
        let csv = """
        Title,Authors,ISBN/UID,Read Status,Date Added,Dates Read,Read Count,Moods
        First,Author,uid-one,to-read,2024/01/01,2025/01/01-2025/01/02,2,"dark, Dark, emotional"
        Second,Author,uid-two,read,2024/01/01,2025/02/01-2025/02/02,1,dark
        Third,Author,uid-three,did-not-finish,2024/01/01,,0,dark
        Fourth,Author,uid-four,read,2024/01/01,,1,unlisted
        """
        let readings = try StoryGraphImporter.parse(Data(csv.utf8)).records.map(\.reading)
        let all = MoodStat.counts(readings: readings, filter: .init(status: "read", year: nil))
        #expect(all.first { $0.name == "Dark" }?.count == 3)
        #expect(all.first { $0.name == "Emotional" }?.count == 2)
        #expect(all.count == 11)
        #expect(all.first { $0.name == "Unlisted" }?.count == 1)
        let year = MoodStat.counts(readings: readings, filter: .init(status: "read", year: 2025))
        #expect(year.first { $0.name == "Dark" }?.count == 2)
        let tbr = MoodStat.counts(readings: readings, filter: .init(status: "to-read", year: 2024))
        #expect(tbr.first { $0.name == "Dark" }?.count == 1)
        #expect(MoodStat.counts(readings: readings, filter: .init(status: "read", year: 2026)).allSatisfy { $0.count == 0 })
    }
    @Test func packingPreservesAreaRatiosAndDoesNotOverlap() {
        let values = [("Large", 100), ("Medium", 25), ("Small", 1)] + (0..<7).map { ("Mood \($0)", $0 + 1) }
        let packed = MoodBubblePacking.pack(values)
        #expect(packed.count == 10)
        for bubble in packed {
            let count = values.first { $0.0 == bubble.id }!.1
            #expect(abs(bubble.radius * bubble.radius - Double(count)) < 0.0001)
            for other in packed where other.id != bubble.id {
                #expect(hypot(bubble.center.x - other.center.x, bubble.center.y - other.center.y) >= bubble.radius + other.radius)
            }
        }
        #expect(MoodBubblePacking.pack([("Zero", 0)]).isEmpty)
        #expect(MoodBubblePacking.pack([("Only", 1)]).first?.center == .zero)
    }
}
