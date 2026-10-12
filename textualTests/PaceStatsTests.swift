import Foundation
import Testing
@testable import textual

struct PaceStatsTests {
    @Test func paceUsesRecordedCategoryAndSharedHistoryScope() throws {
        let csv = """
        Title,Authors,ISBN/UID,Read Status,Date Added,Dates Read,Read Count,Pace
        First,Author,uid-one,to-read,2024/01/01,2025/01/01-2025/01/02,3, FAST
        Second,Author,uid-two,read,2024/01/01,2025/02/01-2025/02/02,1,slow
        Third,Author,uid-three,did-not-finish,2024/01/01,,0,medium
        Fourth,Author,uid-four,read,2024/01/01,,1,
        Fifth,Author,uid-five,read,2024/01/01,,1,unknown
        """
        let readings = try StoryGraphImporter.parse(Data(csv.utf8)).records.map(\.reading)
        let all = PaceStat.counts(readings: readings, filter: .init(status: "read", year: nil))
        #expect(all.map(\.count) == [3, 0, 1, 2])
        #expect(all[0].fraction(total: 6) == 0.5)
        #expect(all[2].fraction(total: 6) == 1.0 / 6)
        #expect(all[0].fraction(total: 0) == nil)
        let year = PaceStat.counts(readings: readings, filter: .init(status: "read", year: 2025))
        #expect(year.map(\.count) == [1, 0, 1])
        #expect(PaceStat.counts(readings: readings, filter: .init(status: "to-read", year: nil)).map(\.count) == [1, 0, 0])
        #expect(PaceStat.counts(readings: [], filter: .init(status: "read", year: nil)).allSatisfy { $0.count == 0 })
    }
}
