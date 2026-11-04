import SwiftUI

/// The look of an English Reader category's cover: a two-color gradient and a motif. Drawn rather than stored, so a
/// category the site adds later gets one too: from words in its name ("Sports", "World Music"…), or failing that
/// from its name's hash, always the same one.
nonisolated struct CategoryTheme: Equatable, Sendable {
    /// The gradient's top-left and bottom-right colors, as 0xRRGGBB.
    var top: UInt32
    var bottom: UInt32
    /// An SF Symbol.
    var symbol: String

    static func forCategory(_ name: String) -> CategoryTheme {
        let lowered = name.lowercased()
        if let known = known[lowered] { return known }
        let words = lowered.split { !$0.isLetter }.map(String.init)
        for rule in rules where words.contains(where: { word in rule.prefixes.contains { matches(word, $0) } }) {
            return rule.theme
        }
        let hash = fnv1a(lowered)
        let palette = fallbackPalettes[Int(hash % UInt64(fallbackPalettes.count))]
        let symbol = fallbackSymbols[Int((hash / 7) % UInt64(fallbackSymbols.count))]
        return CategoryTheme(top: palette.0, bottom: palette.1, symbol: symbol)
    }

    /// The site's categories (2026-11) and Other.
    private static let known: [String: CategoryTheme] = [
        "society & ideas": CategoryTheme(top: 0x8B6CFF, bottom: 0x3F2B96, symbol: "lightbulb.max.fill"),
        "places": CategoryTheme(top: 0x2BC0B4, bottom: 0x1D5FA8, symbol: "globe.europe.africa.fill"),
        "health": CategoryTheme(top: 0xFF8A80, bottom: 0xB0174F, symbol: "heart.fill"),
        "science & nature": CategoryTheme(top: 0x7ED38A, bottom: 0x1E6B3A, symbol: "leaf.fill"),
        "history": CategoryTheme(top: 0xE8B15A, bottom: 0x7A4A1E, symbol: "building.columns.fill"),
        "technology": CategoryTheme(top: 0x38BDF8, bottom: 0x1E3A8A, symbol: "cpu.fill"),
        "culture": CategoryTheme(top: 0xF472B6, bottom: 0xD97706, symbol: "theatermasks.fill"),
        "other": CategoryTheme(top: 0x94A3B8, bottom: 0x3D4A5C, symbol: "text.book.closed.fill"),
    ]

    /// Words a future category's name may have, checked in order: the start of a word for 4 letters or more
    /// ("sports" has "sport"), the whole word for shorter ones (so "war" isn't found in "warming").
    private static let rules: [(prefixes: [String], theme: CategoryTheme)] = [
        (["tech", "comput", "internet", "digital", "artificial", "ai", "robot"], known["technology"]!),
        (["sport", "fitness", "olymp"], CategoryTheme(top: 0xFB923C, bottom: 0xB91C1C, symbol: "figure.run")),
        (["business", "econom", "financ", "money", "work", "career"], CategoryTheme(top: 0x34D399, bottom: 0x0F766E, symbol: "chart.line.uptrend.xyaxis")),
        (["music", "song"], CategoryTheme(top: 0xC084FC, bottom: 0x6D28D9, symbol: "music.note")),
        (["film", "movie", "cinema", "tv", "television"], CategoryTheme(top: 0xF87171, bottom: 0x7F1D1D, symbol: "film.fill")),
        (["art", "arts", "design", "paint"], CategoryTheme(top: 0xFDA4AF, bottom: 0xBE185D, symbol: "paintpalette.fill")),
        (["food", "cook", "cuisine", "drink"], CategoryTheme(top: 0xFBBF24, bottom: 0xC2410C, symbol: "fork.knife")),
        (["travel", "journey", "trip"], CategoryTheme(top: 0x7DD3FC, bottom: 0x0369A1, symbol: "airplane")),
        (["language", "word", "grammar", "vocabular", "english"], CategoryTheme(top: 0xA5B4FC, bottom: 0x4338CA, symbol: "character.book.closed.fill")),
        (["politic", "government", "law", "democra"], CategoryTheme(top: 0x94A3B8, bottom: 0x1E293B, symbol: "building.2.fill")),
        (["space", "astronom", "universe", "planet"], CategoryTheme(top: 0x818CF8, bottom: 0x1E1B4B, symbol: "moon.stars.fill")),
        (["climate", "environment", "weather", "ocean"], CategoryTheme(top: 0x5EEAD4, bottom: 0x0E7490, symbol: "cloud.sun.fill")),
        (["animal", "wildlife", "pet", "pets"], CategoryTheme(top: 0xBEF264, bottom: 0x3F6212, symbol: "pawprint.fill")),
        (["book", "literatur", "story", "stories", "fiction", "poem", "poet", "novel"], CategoryTheme(top: 0xFCD34D, bottom: 0x92400E, symbol: "book.fill")),
        (["education", "learn", "school", "study"], CategoryTheme(top: 0x93C5FD, bottom: 0x1D4ED8, symbol: "graduationcap.fill")),
        (["psycholog", "mind", "philosoph", "idea"], known["society & ideas"]!),
        (["people", "biograph", "person", "life"], CategoryTheme(top: 0xFDBA74, bottom: 0x9A3412, symbol: "person.crop.square.fill")),
        (["news", "current", "today"], CategoryTheme(top: 0xCBD5E1, bottom: 0x334155, symbol: "newspaper.fill")),
        (["health", "medic", "body", "disease"], known["health"]!),
        (["science", "physic", "chemi", "biolog", "math"], CategoryTheme(top: 0x67E8F9, bottom: 0x155E75, symbol: "atom")),
        (["nature", "plant", "earth"], known["science & nature"]!),
        (["histor", "ancient", "war"], known["history"]!),
        (["place", "countr", "city", "cities", "geograph", "world"], known["places"]!),
        (["culture", "societ", "tradition", "religion"], known["culture"]!),
    ]

    private static let fallbackPalettes: [(UInt32, UInt32)] = [
        (0xF9A8D4, 0x9D174D), (0x93C5FD, 0x1E40AF), (0x86EFAC, 0x166534), (0xFCD34D, 0xB45309),
        (0xC4B5FD, 0x5B21B6), (0x67E8F9, 0x0E7490), (0xFDA4AF, 0x9F1239), (0xA7F3D0, 0x047857),
    ]
    private static let fallbackSymbols = [
        "sparkles", "star.fill", "circle.hexagongrid.fill", "seal.fill", "flag.fill", "bookmark.fill", "rhombus.fill",
    ]

    private static func matches(_ word: String, _ keyword: String) -> Bool {
        word == keyword || (keyword.count >= 4 && word.hasPrefix(keyword))
    }

    /// A hash that is the same on every launch (Swift's `hashValue` isn't).
    private static func fnv1a(_ text: String) -> UInt64 {
        text.utf8.reduce(14_695_981_039_346_656_037 as UInt64) { ($0 ^ UInt64($1)) &* 1_099_511_628_211 }
    }
}

extension Color {
    init(rgb: UInt32) {
        self.init(red: Double((rgb >> 16) & 0xFF) / 255, green: Double((rgb >> 8) & 0xFF) / 255, blue: Double(rgb & 0xFF) / 255)
    }
}

/// A category's cover art at any size: the gradient, a soft highlight, and the motif large and cut off by the
/// bottom-right edge.
struct CategoryArt: View {
    let theme: CategoryTheme

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let side = max(size.width, size.height)
            ZStack {
                LinearGradient(colors: [Color(rgb: theme.top), Color(rgb: theme.bottom)], startPoint: .topLeading, endPoint: .bottomTrailing)
                Circle()
                    .fill(.white.opacity(0.28))
                    .frame(width: side * 0.9, height: side * 0.9)
                    .blur(radius: side * 0.2)
                    .offset(x: -size.width * 0.4, y: -size.height * 0.45)
                Image(systemName: theme.symbol)
                    .resizable()
                    .scaledToFit()
                    .frame(width: side * 0.72, height: side * 0.72)
                    .foregroundStyle(.white.opacity(0.24))
                    .rotationEffect(.degrees(-14))
                    .offset(x: size.width * 0.3, y: size.height * 0.16)
            }
            .frame(width: size.width, height: size.height)
        }
        .clipped()
        .accessibilityHidden(true)
    }
}

/// A category in the library's row of covers: its art, name and how many articles it has.
struct CategoryTile: View {
    let category: SiteCategory
    let count: Int

    static let size = CGSize(width: 148, height: 188)

    var body: some View {
        CategoryArt(theme: .forCategory(category.name))
            .overlay {
                // Keeps white text readable on the light top of a gradient.
                LinearGradient(colors: [.clear, .black.opacity(0.28)], startPoint: .center, endPoint: .bottom)
            }
            .overlay(alignment: .bottomLeading) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(category.name)
                        .font(.system(.title3, design: .serif, weight: .bold))
                        .lineLimit(2)
                        .minimumScaleFactor(0.75)
                    Text(count == 1 ? "1 article" : "\(count) articles")
                        .font(.caption.weight(.semibold))
                        .opacity(0.85)
                }
                .foregroundStyle(.white)
                .padding(14)
            }
            .frame(width: Self.size.width, height: Self.size.height)
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(category.name), \(count == 1 ? "1 article" : "\(count) articles")")
            .accessibilityAddTraits(.isButton)
    }
}

/// The small cover beside an article in a list: its category's colors with the motif whole.
struct CategoryThumbnail: View {
    let category: SiteCategory
    var side: CGFloat = 56

    var body: some View {
        let theme = CategoryTheme.forCategory(category.name)
        ZStack {
            LinearGradient(colors: [Color(rgb: theme.top), Color(rgb: theme.bottom)], startPoint: .topLeading, endPoint: .bottomTrailing)
            Image(systemName: theme.symbol)
                .font(.system(size: side * 0.4, weight: .semibold))
                .foregroundStyle(.white.opacity(0.95))
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: side * 0.24, style: .continuous))
        .accessibilityHidden(true)
    }
}
