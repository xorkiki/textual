import Foundation
import Testing
@testable import textual

struct GenreStatsTests {
    @Test func categoriesNormalizeWithoutCountingLocationsAsGenres() {
        let genres = GenreStat.normalized(["Fiction / Fantasy / General", "fantasy fiction", "New York", "science fiction"], isOpenLibrary: true)
        #expect(genres == ["Fantasy", "Science fiction"])
        #expect(GenreStat.normalized(["Fiction / Cyberpunk"], isOpenLibrary: false) == ["Science fiction"])
        let counts = GenreStat.counts([(genres, 2), (["Fantasy"], 1), (["Poetry"], 0)])
        #expect(counts.map(\.count) == [3, 2])
    }
    @Test func allGenresHaveProportionalNonoverlappingTiles() {
        let genres = (1...30).map { GenreStat(name: "Genre \($0)", count: $0) }
        let bounds = CGRect(x: 0, y: 0, width: 320, height: 400)
        let tiles = GenreTiles.layout(genres, in: bounds)
        let total = Double(genres.reduce(0) { $0 + $1.count })
        #expect(tiles.count == 30)
        for tile in tiles {
            let share = tile.rect.width * tile.rect.height / (bounds.width * bounds.height)
            #expect(abs(share - Double(tile.genre.count) / total) < 0.00001)
            for other in tiles where other.id != tile.id {
                let overlap = tile.rect.intersection(other.rect)
                #expect(overlap.isNull || overlap.width * overlap.height < 0.00001)
            }
        }
        #expect(GenreTiles.layout([], in: bounds).isEmpty)
    }
}
