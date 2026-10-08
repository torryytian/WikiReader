import Foundation
import SwiftData
import Testing
@testable import WikiReader

@MainActor
struct SavedWordTests {
    private func makeArticle(_ title: String) -> Article {
        Article(title: title, sourceURL: ArticleInput.articleURL(forTitle: title), blocks: [.paragraph("A")])
    }

    private func request(_ word: String, term: String? = nil, sentence: String = "A sentence.") -> WordLookupRequest {
        WordLookupRequest(word: word, term: term ?? word, hasDefinition: true, sentence: sentence)
    }

    @Test func toggleSavesThenRemoves() {
        let article = makeArticle("Paris")
        #expect(article.toggleSavedWord(request("studies", term: "study")) == true)
        #expect(article.isSaved(term: "study"))
        #expect(article.savedWords.map(\.word) == ["studies"])

        #expect(article.toggleSavedWord(request("study")) == false)
        #expect(article.savedWords.isEmpty)
    }

    @Test func sameTermIsOneEntryRegardlessOfCase() {
        let article = makeArticle("Paris")
        article.toggleSavedWord(request("Run"))
        #expect(article.isSaved(term: "run"))
        #expect(article.savedWords.count == 1)
    }

    @Test func newestWordComesFirst() {
        let article = makeArticle("Paris")
        article.toggleSavedWord(request("alpha"))
        article.toggleSavedWord(request("beta"))
        #expect(article.savedWords.map(\.word) == ["beta", "alpha"])
    }

    @Test func eachArticleHasItsOwnList() {
        let einstein = makeArticle("Albert Einstein")
        let paris = makeArticle("Paris")
        einstein.toggleSavedWord(request("relativity"))
        #expect(einstein.isSaved(term: "relativity"))
        #expect(!paris.isSaved(term: "relativity"))
        #expect(paris.savedWords.isEmpty)
    }

    @Test func removeByID() {
        let article = makeArticle("Paris")
        article.toggleSavedWord(request("alpha"))
        article.toggleSavedWord(request("beta"))
        article.removeSavedWord(id: "alpha")
        #expect(article.savedWords.map(\.word) == ["beta"])
    }

    @Test func savedWordsSurviveTheDatabase() throws {
        let container = try ModelContainer(for: Article.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let article = makeArticle("Paris")
        container.mainContext.insert(article)
        article.toggleSavedWord(request("alpha", sentence: "Alpha is first."))
        try container.mainContext.save()

        let fetched = try #require(try container.mainContext.fetch(FetchDescriptor<Article>()).first)
        #expect(fetched.savedWords.first?.sentence == "Alpha is first.")
    }
}

struct SavedWordHighlightTests {
    private func document(_ paragraphs: [String]) -> ArticleDocument {
        ArticleDocument(title: "Example", blocks: paragraphs.map { .paragraph($0) }, style: .default)
    }

    private func found(_ keys: Set<String>, in document: ArticleDocument) -> [String] {
        let text = document.attributedText.string as NSString
        return document.ranges(ofWords: keys).map { text.substring(with: $0) }
    }

    @Test func findsEveryOccurrenceIgnoringCase() {
        let doc = document(["Wreckage was found. The wreckage sank.", "More WRECKAGE."])
        #expect(found(["wreckage"], in: doc) == ["Wreckage", "wreckage", "WRECKAGE"])
    }

    @Test func matchesWholeWordsOnly() {
        let doc = document(["The crash was a crashing bore."])
        #expect(found(["crash"], in: doc) == ["crash"])
    }

    @Test func possessiveStillMatches() {
        let doc = document(["The aircraft's recorders and the aircraft."])
        #expect(found(["aircraft"], in: doc) == ["aircraft's", "aircraft"])
    }

    @Test func noKeysNoRanges() {
        #expect(document(["Anything."]).ranges(ofWords: []).isEmpty)
    }

    @Test func titleIsNotSearched() {
        let doc = document(["Body text."])
        #expect(doc.ranges(ofWords: ["example"]).isEmpty)
    }
}
