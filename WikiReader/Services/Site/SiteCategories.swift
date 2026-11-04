import Foundation

/// A category of the English Reader catalog. Articles the site hasn't put in one are in `other`.
nonisolated struct SiteCategory: Hashable, Identifiable, Sendable {
    /// The site's number when it has one (a rename keeps it), else the name.
    var id: String
    var name: String

    static let other = SiteCategory(id: "other", name: "Other")

    var isOther: Bool { id == Self.other.id }
}

/// How a list of the site's articles is ordered.
nonisolated enum SiteArticleOrder: String, CaseIterable, Identifiable, Sendable {
    case newest
    case easiest
    case shortest

    var id: String { rawValue }

    var title: String {
        switch self {
        case .newest: "Newest"
        case .easiest: "Easiest First"
        case .shortest: "Shortest First"
        }
    }
}

extension SiteArticleSummary {
    nonisolated var siteCategory: SiteCategory {
        guard let category, !category.name.isEmpty else { return .other }
        return SiteCategory(id: category.id.map { "c\($0)" } ?? "n\(category.name)", name: category.name)
    }

    /// CEFR levels in order, easiest first; an article without one comes after all of them.
    nonisolated static let levels = ["A1", "A2", "B1", "B2", "C1", "C2"]

    nonisolated var levelRank: Int {
        cefr.flatMap { Self.levels.firstIndex(of: $0.uppercased()) } ?? Self.levels.count
    }
}

nonisolated enum SiteCategories {
    /// The catalog by category: in the site's order (`info`'s `sort`) where it gives one, then the fullest first (ties
    /// by name), Other last. Each category's articles keep the order they came in.
    static func group(
        _ articles: [SiteArticleSummary], info: [Int: SiteCategoryInfo] = [:]
    ) -> [(category: SiteCategory, articles: [SiteArticleSummary])] {
        func sort(_ category: SiteCategory) -> Int? {
            guard category.id.hasPrefix("c"), let number = Int(category.id.dropFirst()) else { return nil }
            return info[number]?.sort
        }
        var order: [SiteCategory] = []
        var members: [SiteCategory: [SiteArticleSummary]] = [:]
        for article in articles {
            let category = article.siteCategory
            if members[category] == nil { order.append(category) }
            members[category, default: []].append(article)
        }
        return order
            .map { (category: $0, articles: members[$0] ?? []) }
            .sorted { a, b in
                if a.category.isOther != b.category.isOther { return b.category.isOther }
                switch (sort(a.category), sort(b.category)) {
                case let (x?, y?) where x != y: return x < y
                case (.some, nil): return true
                case (nil, .some): return false
                default: break
                }
                if a.articles.count != b.articles.count { return a.articles.count > b.articles.count }
                return a.category.name.localizedStandardCompare(b.category.name) == .orderedAscending
            }
    }

    /// The levels some of these articles have, easiest first.
    static func levels(in articles: [SiteArticleSummary]) -> [String] {
        let present = Set(articles.compactMap { $0.cefr?.uppercased() })
        return SiteArticleSummary.levels.filter(present.contains)
    }

    static func sorted(_ articles: [SiteArticleSummary], by order: SiteArticleOrder) -> [SiteArticleSummary] {
        switch order {
        case .newest:
            return articles.sorted { ($0.shownDate ?? .distantPast) > ($1.shownDate ?? .distantPast) }
        case .easiest:
            return articles.sorted {
                $0.levelRank != $1.levelRank ? $0.levelRank < $1.levelRank : ($0.wordCount ?? .max) < ($1.wordCount ?? .max)
            }
        case .shortest:
            return articles.sorted { ($0.wordCount ?? .max) < ($1.wordCount ?? .max) }
        }
    }
}
