import Foundation

/// A meme template as the classic memes row knows it: Imgflip's id and name (`MemeTemplateCatalog` matches on both).
public struct TemplateRef: Equatable, Sendable {
    public let id: String
    public let name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

/// Picks classic meme templates (Distracted Boyfriend, Surprised Pikachu…) for a mood or for typed words, from
/// Imgflip's list of popular templates. Imgflip's list has no tags, so this table says what each famous template is
/// for. Matching runs on the Mac: nothing about the face or the words is sent anywhere.
public enum MemeTemplateCatalog {
    /// One famous template: the names Imgflip has used for it, its Imgflip id when known, the moods it answers
    /// (most fitting first across the table: entries come in order of fame) and words people search it by.
    public struct Entry: Sendable {
        public let names: [String]
        public let id: String?
        public let moods: [Mood]
        public let words: [String]
    }

    /// Up to `limit` indexes into `templates` (Imgflip's order, most popular first) for `mood`: the templates made for
    /// it (those whose first mood it is, then those that list it later; each in table order), then the most popular
    /// others, so the row is never empty. `.reaction` (no face yet) is the popular ones.
    public static func pick(for mood: Mood, from templates: [TemplateRef], limit: Int) -> [Int] {
        guard limit > 0 else { return [] }
        var picked: [Int] = []
        if mood != .reaction {
            let indexes = entryIndexes(for: templates)
            var matching: [(entryIndex: Int, rank: Int)] = []
            for (entryIndex, entry) in entries.enumerated() {
                if let rank = entry.moods.firstIndex(of: mood) {
                    matching.append((entryIndex: entryIndex, rank: rank))
                }
            }
            let ordered = matching.sorted { $0.rank != $1.rank ? $0.rank < $1.rank : $0.entryIndex < $1.entryIndex }
            for match in ordered {
                guard let found = indexes[match.entryIndex], !picked.contains(found) else { continue }
                picked.append(found)
                if picked.count == limit { return picked }
            }
        }
        for index in templates.indices where !picked.contains(index) {
            picked.append(index)
            if picked.count == limit { break }
        }
        return picked
    }

    /// Up to `limit` indexes into `templates` matching typed `terms`, best first: a word of the template's name
    /// starting with a term, a word it is searched by, or a mood the words name ("sad", "lol", "mad"). Only templates
    /// that match at least one term; ties keep Imgflip's order.
    public static func pick(forTerms terms: [String], from templates: [TemplateRef], limit: Int) -> [Int] {
        let cleaned = terms
            .flatMap { $0.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }) }
            .map(String.init)
            .filter { $0.count >= 2 }
        guard limit > 0, !cleaned.isEmpty else { return [] }
        let phrase = cleaned.joined(separator: " ")
        let moods = Set(cleaned.compactMap { moodWords[$0] } + multiWordMoods.filter { phrase.contains($0.key) }.map(\.value))
        let indexes = entryIndexes(for: templates)
        var entryFor: [Int: Entry] = [:]
        for (entryIndex, templateIndex) in indexes {
            entryFor[templateIndex] = entries[entryIndex]
        }

        var scored: [(index: Int, score: Int)] = []
        for (index, template) in templates.enumerated() {
            let nameWords = words(in: template.name)
            let entry = entryFor[index]
            let searchWords = (entry?.words ?? []).flatMap { words(in: $0) }
            var score = 0
            for term in cleaned {
                if nameWords.contains(where: { $0.hasPrefix(term) }) {
                    score += 3
                } else if searchWords.contains(where: { $0.hasPrefix(term) }) {
                    score += 2
                }
            }
            if let entry {
                // A whole phrase it is known by ("change my mind", "first world problems").
                if entry.words.contains(where: { $0.count > 3 && phrase.contains($0) }) {
                    score += 2
                }
                if let rank = entry.moods.firstIndex(where: { moods.contains($0) }) {
                    score += rank == 0 ? 3 : 2
                }
            }
            if score > 0 {
                scored.append((index, score))
            }
        }
        // Stable: equal scores keep Imgflip's (popularity) order.
        let sorted = scored.enumerated().sorted { lhs, rhs in
            lhs.element.score != rhs.element.score ? lhs.element.score > rhs.element.score : lhs.offset < rhs.offset
        }
        return sorted.prefix(limit).map { $0.element.index }
    }

    /// For each entry, the template in `templates` it describes (by Imgflip id, else by name), if Imgflip lists it.
    static func entryIndexes(for templates: [TemplateRef]) -> [Int: Int] {
        var byID: [String: Int] = [:]
        var byName: [String: Int] = [:]
        for (index, template) in templates.enumerated() {
            if byID[template.id] == nil { byID[template.id] = index }
            let key = normalized(template.name)
            if byName[key] == nil { byName[key] = index }
        }
        var found: [Int: Int] = [:]
        for (entryIndex, entry) in entries.enumerated() {
            if let id = entry.id, let index = byID[id] {
                found[entryIndex] = index
            } else if let index = entry.names.lazy.compactMap({ byName[normalized($0)] }).first {
                found[entryIndex] = index
            }
        }
        return found
    }

    /// "Gru's Plan" → "grusplan": names compare without case, spaces or punctuation.
    static func normalized(_ name: String) -> String {
        String(name.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(Character.init))
    }

    private static func words(in text: String) -> [String] {
        text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
    }

    /// Typed words that name a mood.
    static let moodWords: [String: Mood] = [
        "shocked": .shocked, "shock": .shocked, "surprised": .shocked, "surprise": .shocked, "omg": .shocked,
        "wow": .shocked, "wtf": .shocked, "what": .shocked,
        "screaming": .screaming, "scream": .screaming, "yelling": .screaming, "yell": .screaming, "shouting": .screaming,
        "laughing": .laughing, "laugh": .laughing, "lol": .laughing, "lmao": .laughing, "haha": .laughing,
        "funny": .laughing,
        "happy": .happy, "smile": .happy, "glad": .happy, "nice": .happy, "good": .happy,
        "smug": .smug, "smirk": .smug, "petty": .smug, "sarcastic": .smug, "sarcasm": .smug,
        "crying": .crying, "cry": .crying, "tears": .crying, "sob": .crying,
        "sad": .sad, "depressed": .sad, "lonely": .sad, "down": .sad, "upset": .sad,
        "angry": .angry, "mad": .angry, "rage": .angry, "furious": .angry, "annoyed": .angry,
        "confused": .confused, "confusing": .confused, "huh": .confused, "why": .confused,
        "unimpressed": .unimpressed, "meh": .unimpressed, "bored": .unimpressed, "boring": .unimpressed,
        "disappointed": .unimpressed, "whatever": .unimpressed,
        "nervous": .nervous, "anxious": .nervous, "awkward": .nervous, "scared": .nervous, "panic": .nervous,
        "stressed": .nervous, "worried": .nervous,
        "excited": .excited, "hype": .excited, "hyped": .excited, "yay": .excited,
        "celebrate": .celebrate, "celebrating": .celebrate, "party": .celebrate, "win": .celebrate,
        "winning": .celebrate, "congrats": .celebrate, "cheers": .celebrate,
        "facepalm": .facepalm, "ugh": .facepalm, "smh": .facepalm, "dumb": .facepalm,
        "shrug": .shrug, "idk": .shrug, "dunno": .shrug,
        "pointing": .pointing, "point": .pointing,
        "clapping": .clapping, "clap": .clapping, "applause": .clapping, "bravo": .clapping,
    ]

    private static let multiWordMoods: [String: Mood] = [
        "side eye": .sideEye, "mind blown": .mindBlown, "thumbs up": .thumbsUp,
    ]

    /// Famous templates, most famous first. Ids are Imgflip's where known; names cover what Imgflip has called them.
    public static let entries: [Entry] = [
        Entry(names: ["Distracted Boyfriend"], id: "112126428", moods: [.sideEye, .nervous],
              words: ["distracted", "boyfriend", "girlfriend", "looking back", "checking out", "jealous", "tempted", "cheating"]),
        Entry(names: ["Drake Hotline Bling", "Drakeposting"], id: "181913649", moods: [.unimpressed, .thumbsUp],
              words: ["drake", "no yes", "nah yeah", "prefer", "approve", "disapprove", "better"]),
        Entry(names: ["Two Buttons"], id: "87743020", moods: [.nervous],
              words: ["buttons", "choice", "choose", "decision", "dilemma", "sweating"]),
        Entry(names: ["Woman Yelling At Cat"], id: "188390779", moods: [.angry, .screaming, .confused],
              words: ["yelling", "cat", "woman", "argument", "smudge", "dinner table"]),
        Entry(names: ["Surprised Pikachu"], id: "155067746", moods: [.shocked],
              words: ["pikachu", "surprised", "shocked", "pokemon", "shock"]),
        Entry(names: ["Hide the Pain Harold"], id: "27813981", moods: [.nervous, .sad],
              words: ["harold", "pain", "awkward", "fake smile", "old man", "coping"]),
        Entry(names: ["This Is Fine"], id: "55311130", moods: [.nervous, .shrug],
              words: ["fine", "fire", "dog", "burning", "chaos", "everything is fine"]),
        Entry(names: ["Disaster Girl"], id: "97984", moods: [.smug],
              words: ["disaster", "fire", "girl", "evil", "smirk", "arson"]),
        Entry(names: ["Roll Safe Think About It"], id: "89370399", moods: [.smug, .mindBlown],
              words: ["think", "thinking", "smart", "tap head", "genius", "logic", "roll safe"]),
        Entry(names: ["Mocking Spongebob"], id: "102156234", moods: [.smug, .angry],
              words: ["mocking", "spongebob", "sarcastic", "sarcasm", "chicken", "mock"]),
        Entry(names: ["Change My Mind"], id: "129242436", moods: [.smug],
              words: ["change my mind", "debate", "opinion", "prove me wrong"]),
        Entry(names: ["Monkey Puppet"], id: "148909805", moods: [.sideEye, .nervous],
              words: ["monkey", "puppet", "side eye", "awkward", "look away", "awkward look"]),
        Entry(names: ["Side Eyeing Chloe", "Chloe Side Eye"], id: nil, moods: [.sideEye, .unimpressed],
              words: ["chloe", "side eye", "suspicious", "skeptical"]),
        Entry(names: ["Sad Pablo Escobar"], id: "80707627", moods: [.sad, .unimpressed],
              words: ["sad", "pablo", "escobar", "waiting", "lonely", "alone", "bored"]),
        Entry(names: ["Waiting Skeleton"], id: "4087833", moods: [.sad, .unimpressed],
              words: ["waiting", "skeleton", "forever", "bench", "still waiting"]),
        Entry(names: ["Expanding Brain"], id: "93895088", moods: [.mindBlown],
              words: ["brain", "galaxy brain", "smart", "enlightened", "levels", "big brain"]),
        Entry(names: ["Is This A Pigeon"], id: "100777631", moods: [.confused, .pointing],
              words: ["pigeon", "butterfly", "is this", "anime"]),
        Entry(names: ["Batman Slapping Robin"], id: "438680", moods: [.angry],
              words: ["batman", "robin", "slap", "shut up"]),
        Entry(names: ["Gru's Plan"], id: "131940431", moods: [.nervous, .confused],
              words: ["gru", "plan", "despicable me", "wait what"]),
        Entry(names: ["Left Exit 12 Off Ramp"], id: "124822590", moods: [.nervous],
              words: ["exit", "car", "swerve", "off ramp", "highway"]),
        Entry(names: ["Running Away Balloon"], id: "131087935", moods: [.sad],
              words: ["balloon", "running away", "chasing", "holding back"]),
        Entry(names: ["UNO Draw 25 Cards"], id: "217743513", moods: [.smug, .unimpressed],
              words: ["uno", "draw 25", "cards", "refuse", "rather not"]),
        Entry(names: ["Bernie I Am Once Again Asking For Your Support"], id: "222403160", moods: [.unimpressed, .sad],
              words: ["bernie", "asking", "once again", "support", "please"]),
        Entry(names: ["Buff Doge vs. Cheems"], id: "247375501", moods: [.excited],
              words: ["doge", "cheems", "buff", "strong", "weak", "then vs now"]),
        Entry(names: ["Always Has Been"], id: "252600902", moods: [.shrug, .pointing],
              words: ["always has been", "astronaut", "space", "wait its all"]),
        Entry(names: ["Epic Handshake"], id: "135256802", moods: [.happy, .celebrate, .thumbsUp, .clapping],
              words: ["handshake", "agree", "agreement", "teamwork", "same", "together"]),
        Entry(names: ["Anakin Padme 4 Panel"], id: "322841258", moods: [.confused, .nervous],
              words: ["anakin", "padme", "right", "for the better"]),
        Entry(names: ["Tuxedo Winnie The Pooh"], id: "178591752", moods: [.smug, .happy],
              words: ["winnie", "pooh", "tuxedo", "fancy", "classy", "sophisticated"]),
        Entry(names: ["Panik Kalm Panik"], id: "226297822", moods: [.nervous, .screaming],
              words: ["panik", "kalm", "panic", "calm", "meme man"]),
        Entry(names: ["Leonardo Dicaprio Cheers"], id: "5496396", moods: [.celebrate, .happy, .excited, .clapping, .thumbsUp],
              words: ["cheers", "toast", "dicaprio", "gatsby", "congrats", "congratulations"]),
        Entry(names: ["Success Kid"], id: "61544", moods: [.celebrate, .happy, .thumbsUp, .clapping],
              words: ["success", "win", "victory", "fist", "yes", "kid"]),
        Entry(names: ["Laughing Leo"], id: "259237855", moods: [.laughing],
              words: ["laughing", "lol", "leo", "dicaprio", "django", "haha"]),
        Entry(names: ["Laughing Men In Suits"], id: nil, moods: [.laughing],
              words: ["laughing", "suits", "men", "lol", "haha"]),
        Entry(names: ["Unsettled Tom"], id: "175540452", moods: [.shocked, .nervous],
              words: ["tom", "unsettled", "uncomfortable", "tom and jerry"]),
        Entry(names: ["Blinking White Guy", "Blinking Guy", "Drew Scanlon Reaction"], id: nil, moods: [.shocked, .confused],
              words: ["blinking", "blink", "disbelief", "surprised"]),
        Entry(names: ["Mr Krabs Blur Meme", "Confused Mr Krabs"], id: nil, moods: [.confused, .shocked],
              words: ["krabs", "blur", "dizzy", "spongebob"]),
        Entry(names: ["Math Lady/Confused Lady", "Confused Math Lady", "Math Lady"], id: nil, moods: [.confused],
              words: ["math", "calculating", "confused lady", "thinking"]),
        Entry(names: ["Grumpy Cat"], id: "405658", moods: [.unimpressed, .angry],
              words: ["grumpy", "cat", "no", "annoyed"]),
        Entry(names: ["Captain Picard Facepalm"], id: "1509839", moods: [.facepalm],
              words: ["picard", "facepalm", "star trek", "disappointed"]),
        Entry(names: ["Clown Applying Makeup"], id: "195515965", moods: [.facepalm],
              words: ["clown", "makeup", "foolish", "stupid"]),
        Entry(names: ["Bike Fall"], id: "79132341", moods: [.facepalm],
              words: ["bike", "fall", "self sabotage", "stick"]),
        Entry(names: ["Futurama Fry"], id: "61520", moods: [.sideEye, .confused],
              words: ["fry", "not sure if", "suspicious", "squint", "futurama"]),
        Entry(names: ["Third World Skeptical Kid"], id: "101288", moods: [.sideEye, .unimpressed],
              words: ["skeptical", "kid", "doubt", "suspicious"]),
        Entry(names: ["Bad Luck Brian"], id: "61585", moods: [.sad],
              words: ["bad luck", "brian", "unlucky", "fail"]),
        Entry(names: ["First World Problems"], id: "61539", moods: [.crying, .sad],
              words: ["first world problems", "crying", "cry", "woman"]),
        Entry(names: ["Crying Michael Jordan", "Michael Jordan Crying", "Crying Jordan"], id: nil, moods: [.crying, .sad],
              words: ["jordan", "crying", "tears"]),
        Entry(names: ["Finding Neverland"], id: "6235864", moods: [.crying, .sad],
              words: ["neverland", "crying", "tears"]),
        Entry(names: ["Evil Kermit"], id: "84341851", moods: [.smug],
              words: ["evil", "kermit", "temptation", "dark side", "hoodie"]),
        Entry(names: ["But That's None Of My Business", "Kermit Sipping Tea"], id: "16464531", moods: [.smug],
              words: ["kermit", "tea", "sipping", "none of my business", "petty"]),
        Entry(names: ["Oprah You Get A"], id: "28251713", moods: [.excited, .celebrate, .pointing, .clapping],
              words: ["oprah", "you get a", "everyone gets", "giveaway"]),
        Entry(names: ["Y U No"], id: "61527", moods: [.angry],
              words: ["y u no", "why", "rage"]),
        Entry(names: ["Arthur Fist"], id: "74191766", moods: [.angry],
              words: ["arthur", "fist", "clenched"]),
        Entry(names: ["Inhaling Seagull"], id: "114585149", moods: [.screaming, .angry],
              words: ["seagull", "inhaling", "scream", "yell"]),
        Entry(names: ["American Chopper Argument"], id: "134797956", moods: [.angry, .screaming],
              words: ["argument", "american chopper", "fight", "yelling"]),
        Entry(names: ["Matrix Morpheus"], id: "100947", moods: [.mindBlown],
              words: ["morpheus", "matrix", "what if i told you"]),
        Entry(names: ["Ancient Aliens"], id: "101470", moods: [.mindBlown, .confused],
              words: ["aliens", "ancient aliens", "history channel", "giorgio"]),
        Entry(names: ["Philosoraptor"], id: "61516", moods: [.confused, .mindBlown],
              words: ["philosoraptor", "dinosaur", "thinking", "question"]),
        Entry(names: ["Sleeping Shaq"], id: "99683372", moods: [.unimpressed],
              words: ["shaq", "sleeping", "wide awake"]),
        Entry(names: ["Hard To Swallow Pills"], id: "132769734", moods: [.sad],
              words: ["pills", "truth", "hard to swallow"]),
        Entry(names: ["Who Killed Hannibal"], id: "135678846", moods: [.confused],
              words: ["hannibal", "who killed", "eric andre", "why would"]),
        Entry(names: ["They're The Same Picture"], id: "180190441", moods: [.confused, .unimpressed],
              words: ["same picture", "the office", "same", "no difference"]),
        Entry(names: ["Spongebob Ight Imma Head Out"], id: "196652226", moods: [.shrug, .unimpressed],
              words: ["head out", "leaving", "ight", "spongebob", "bye", "leave"]),
        Entry(names: ["I Bet He's Thinking About Other Women"], id: "110163934", moods: [.sad, .sideEye],
              words: ["thinking", "other women", "overthinking", "bed"]),
        Entry(names: ["Disappointed Black Guy"], id: nil, moods: [.unimpressed, .sad],
              words: ["disappointed", "really", "ugh"]),
        Entry(names: ["Kombucha Girl"], id: nil, moods: [.unimpressed, .confused],
              words: ["kombucha", "disgusted", "unsure"]),
        Entry(names: ["Leonardo Dicaprio Pointing", "Rick Dalton Pointing"], id: nil, moods: [.pointing, .excited],
              words: ["pointing", "recognize", "that's me", "dicaprio"]),
        Entry(names: ["Spider Man Pointing", "Spider-Man Pointing at Spider-Man"], id: nil, moods: [.pointing, .confused],
              words: ["spiderman", "spider man", "pointing", "same", "twins", "copy"]),
        Entry(names: ["Trade Offer"], id: "309868304", moods: [.pointing, .smug],
              words: ["trade", "offer", "deal", "i receive", "you receive"]),
        Entry(names: ["Car Salesman Slaps Roof Of Car"], id: nil, moods: [.smug, .happy],
              words: ["salesman", "slaps roof", "fits so many"]),
        Entry(names: ["Scooby Doo Mask Reveal"], id: nil, moods: [.shocked],
              words: ["mask", "reveal", "unmask", "scooby"]),
        Entry(names: ["The Rock Driving"], id: "21735", moods: [.shocked, .sideEye],
              words: ["rock", "driving", "car", "dwayne"]),
        Entry(names: ["Jack Sparrow Being Chased"], id: nil, moods: [.nervous],
              words: ["running", "chased", "jack sparrow", "run"]),
        Entry(names: ["Mother Ignoring Kid Drowning In A Pool"], id: nil, moods: [.sad],
              words: ["ignoring", "pool", "drowning", "skeleton"]),
        Entry(names: ["Squidward Window", "Squidward"], id: nil, moods: [.sad, .sideEye],
              words: ["squidward", "window", "jealous", "watching"]),
        Entry(names: ["Doge"], id: "8072285", moods: [.happy, .excited],
              words: ["doge", "wow", "such", "much"]),
        Entry(names: ["Grandma Finds The Internet"], id: "61556", moods: [.excited, .confused],
              words: ["grandma", "internet", "computer", "old"]),
        Entry(names: ["One Does Not Simply"], id: "61579", moods: [.smug],
              words: ["one does not simply", "boromir", "lord of the rings"]),
        Entry(names: ["Brace Yourselves X is Coming"], id: "61546", moods: [.nervous],
              words: ["brace yourselves", "coming", "winter"]),
        Entry(names: ["Black Girl Wat"], id: nil, moods: [.confused],
              words: ["wat", "what", "confused"]),
        Entry(names: ["Confused Gandalf"], id: nil, moods: [.confused],
              words: ["gandalf", "no memory", "lord of the rings"]),
        Entry(names: ["Marked Safe From"], id: "161865971", moods: [.happy],
              words: ["safe", "marked safe"]),
    ]
}
