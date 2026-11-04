import Foundation

/// Textual's app-wide controlled vocabulary. Not a copied BISAC code database.
/// Shared by Archive, Stats, and reader profiles; no account-specific rules.
/// Map subject phrases and narrower genres to broad, nonexclusive filters.
enum GenreTaxonomy {
    static let version = 1

    private struct Rule {
        let name: String
        let aliases: [String]
        let exact: [String]
        let excluding: [String]
        init(_ name: String, aliases: [String], exact: [String] = [], excluding: [String] = []) {
            self.name = name
            self.aliases = Array(Set(aliases.map(GenreTaxonomy.key)))
            self.exact = exact.map(GenreTaxonomy.key)
            self.excluding = excluding.map(GenreTaxonomy.key)
        }
        func matches(_ segment: String) -> Bool {
            if exact.contains(segment) { return true }
            var padded = " " + segment + " "
            for phrase in excluding {
                padded = padded.replacingOccurrences(of: " " + phrase + " ", with: " ")
            }
            return aliases.contains { padded.range(of: " " + $0 + " ", options: .literal) != nil }
        }
    }

    private static let rules: [Rule] = [
        Rule("Fantasy", aliases: ["Fantasy", "fantasy", "fantasy fiction", "fantasies", "romantasy", "epic fantasy", "high fantasy", "low fantasy", "urban fantasy", "dark fantasy", "magical realism", "magic realism", "fairy tales", "fairy tale", "sword and sorcery", "sword & sorcery"]),
        Rule("Romance", aliases: ["Romance", "romance", "romance fiction", "love stories", "romances", "romantic fiction", "romantic suspense", "romantasy", "love story"], excluding: ["romance languages", "romance language"]),
        Rule("Memoir", aliases: ["Memoir", "memoir", "memoirs", "personal memoirs", "autobiography", "autobiographies", "autobiographical", "personal narratives", "personal narrative"]),
        Rule("Biography", aliases: ["Biography", "biography", "biographies", "biography & autobiography", "biographical", "life writing"]),
        Rule("Young adult", aliases: ["Young adult", "young adult", "young adult fiction", "young adult nonfiction", "young adults", "teen fiction", "teenage fiction", "teen literature"]),
        Rule("Middle grade", aliases: ["Middle grade", "middle grade", "middle grades", "middle school fiction"]),
        Rule("Historical", aliases: ["historical fiction", "historical romance", "historical fantasy", "historical mystery", "historical mysteries", "historical thriller", "alternate history", "alternative history"], exact: ["historical"]),
        Rule("Literary", aliases: ["literary fiction", "literary novels"], exact: ["literary"]),
        Rule("Thriller", aliases: ["Thriller", "thriller", "thrillers", "suspense", "suspense fiction", "suspenseful fiction", "psychological thrillers", "psychological thriller", "techno thriller", "technothriller"]),
        Rule("Mystery", aliases: ["Mystery", "mystery", "mystery & detective", "mystery fiction", "detective and mystery stories", "mysteries", "detective fiction", "detective stories", "whodunit", "whodunits", "cozy mysteries", "cozy mystery"]),
        Rule("Crime", aliases: ["Crime", "crime", "crime fiction", "criminal fiction", "noir", "heist fiction"], excluding: ["true crime", "true crimes"]),
        Rule("True crime", aliases: ["True crime", "true crime", "true crimes", "truecrime", "criminal cases", "murder cases"]),
        Rule("Self help", aliases: ["Self help", "self help", "self-help", "self help books", "self-help techniques", "self improvement", "personal development", "personal growth", "self care", "selfcare"]),
        Rule("LGBTQIA+", aliases: ["LGBTQIA+", "lgbt", "lgbtq", "lgbtq+", "lgbtqia+", "gay", "lesbian", "queer fiction", "lgbtqia", "lgbtqiap", "lgbtq2", "lgbtq2s", "lgbtqi", "lgbtqa", "2slgbtqia", "gender nonconforming", "gender non conforming", "queer", "gays", "lesbians", "lesbianism", "bisexual", "bisexuals", "bisexuality", "transgender", "transsexual", "nonbinary", "non binary", "genderqueer", "gender queer", "genderfluid", "gender fluid", "intersex", "asexual", "asexuality", "aromantic", "pansexual", "pansexuality", "same sex", "homosexual", "homosexuality", "sapphic", "two spirit", "two spirited", "indigiqueer"], excluding: ["asexual reproduction", "bisexual reproduction"]),
        Rule("Feminism", aliases: ["Feminism", "feminism", "feminist theory", "feminist", "feminist fiction", "womens studies", "women studies"]),
        Rule("Science fiction", aliases: ["Science fiction", "science fiction", "sci-fi", "sci fi", "scifi", "sf fiction", "cyberpunk", "steampunk", "space opera", "time travel fiction", "speculative science fiction"]),
        Rule("Poetry", aliases: ["Poetry", "poetry", "poems", "poetic works", "verse", "sonnets", "haiku"]),
        Rule("Dystopian", aliases: ["Dystopian", "dystopian", "dystopia", "dystopias", "dystopian fiction", "post apocalyptic", "postapocalyptic"]),
        Rule("Contemporary", aliases: ["contemporary fiction", "contemporary romance", "contemporary literature", "contemporary fantasy"], exact: ["contemporary"]),
        Rule("Horror", aliases: ["Horror", "horror", "horror fiction", "horror tales", "horrors", "horror stories", "ghost stories", "ghost fiction", "supernatural horror", "gothic horror"]),
        Rule("Adventure", aliases: ["Adventure", "adventure", "action & adventure", "adventure stories", "adventures", "adventure fiction", "action adventure"]),
        Rule("Art", aliases: ["Art", "art", "arts", "fine arts", "visual arts", "painting", "paintings", "sculpture", "art history", "photography"]),
        Rule("Essays", aliases: ["Essays", "essays", "essay collections", "essay", "personal essays", "collected essays"]),
        Rule("Classics", aliases: ["classic literature", "classic fiction", "classical literature", "literary classics"], exact: ["classics"]),
        Rule("Health", aliases: ["Health", "health", "health & fitness", "fitness", "wellness", "medicine", "medical", "nutrition", "mental health"]),
        Rule("Politics", aliases: ["Politics", "politics", "political science", "politics and government", "political", "government", "governments", "geopolitics", "public policy"]),
        Rule("Philosophy", aliases: ["Philosophy", "philosophy", "philosophical", "ethics", "metaphysics", "epistemology", "existentialism"]),
        Rule("Psychology", aliases: ["Psychology", "psychology", "psychological", "psychoanalysis", "psychotherapy", "cognitive psychology"], excluding: ["psychological thriller", "psychological thrillers", "psychological fiction", "psychological suspense"]),
        Rule("History", aliases: ["History", "history", "world history", "social history", "military history", "ancient history"], excluding: ["natural history", "alternate history", "alternative history"]),
        Rule("Business", aliases: ["Business", "business", "business & economics", "economics", "finance", "financial", "economic", "entrepreneurship", "management", "marketing", "investing"]),
        Rule("Science", aliases: ["Science", "science", "natural sciences", "sciences", "physics", "chemistry", "biology", "astronomy", "mathematics", "math", "neuroscience"], excluding: ["science fiction", "political science", "social science", "social sciences", "computer science", "library science"]),
        Rule("Religion", aliases: ["Religion", "religion", "religious", "spirituality", "religions", "spiritual", "theology", "christian", "christianity", "buddhist", "buddhism", "islam", "islamic", "judaism", "jewish religion", "hinduism"]),
        Rule("Travel", aliases: ["Travel", "travel", "travel writing", "travels", "travelogues", "travelogue", "journeys", "guidebooks"]),
        Rule("Cooking", aliases: ["Cooking", "cooking", "cookbooks", "food writing", "cookery", "cookbook", "recipes", "gastronomy", "culinary"]),
        Rule("Humor", aliases: ["Humor", "humor", "humour", "humorous fiction", "humorous", "humourous", "comedy", "comedies", "comic fiction", "satire", "satirical"]),
        Rule("Graphic novels", aliases: ["Graphic novels", "graphic novels", "comics", "comics & graphic novels", "manga", "graphic novel", "comic books", "comic book", "manhwa", "manhua", "sequential art"]),
        Rule("Short stories", aliases: ["Short stories", "short stories", "short stories (single author)", "short story", "short fiction", "story collections"]),
        Rule("Drama", aliases: ["Drama", "drama", "plays", "dramatic works", "playwriting", "theater", "theatre"]),
        Rule("Music", aliases: ["Music", "music", "musical", "musicians", "songwriting", "songs"]),
        Rule("Sports", aliases: ["Sports", "sports", "sports & recreation", "sport", "athletics", "athletes", "recreation"]),
        Rule("Nature", aliases: ["Nature", "nature", "natural history", "wildlife", "ecology", "environment", "environmental", "animals", "conservation"], excluding: ["human nature", "nature of"]),
        Rule("Technology", aliases: ["Technology", "technology", "computers", "technology & engineering", "technological", "computer", "computing", "computer science", "software", "programming", "engineering", "artificial intelligence"]),
        Rule("Education", aliases: ["Education", "education", "educational", "teaching", "learning", "pedagogy", "schools"]),
        Rule("Children’s", aliases: ["Children’s", "juvenile fiction", "juvenile literature", "childrens fiction", "childrens stories", "childrens literature", "picture books", "picture book", "early readers"]),
        Rule("Erotica", aliases: ["Erotica", "erotic fiction", "erotic romance", "erotica"]),
        Rule("Western", aliases: ["Western", "western fiction", "western stories", "westerns"])
    ]

    static func normalized(_ categories: [String], isOpenLibrary: Bool) -> Set<String> {
        var result = Set<String>()
        for category in categories {
            let rawSegments = category.components(separatedBy: "/")
            let segments = rawSegments.map(key)
            let matches = rules.filter { rule in segments.contains(where: rule.matches) }
            result.formUnion(matches.map(\.name))
            // Preserve an unfamiliar publisher category, but never turn arbitrary
            // Open Library places, names, or unrecognized subjects into genres.
            if matches.isEmpty, !isOpenLibrary,
               let leaf = rawSegments.last?.trimmingCharacters(in: .whitespacesAndNewlines),
               !key(leaf).isEmpty,
               !["general", "fiction", "nonfiction", "non fiction", "juvenile nonfiction"].contains(key(leaf)) {
                result.insert(leaf.lowercased().capitalized)
            }
        }
        return result
    }

    private static func key(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .replacingOccurrences(of: "’", with: "")
            .replacingOccurrences(of: "'", with: "")
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }.joined(separator: " ")
    }
}
