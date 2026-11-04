import SwiftUI

/// One English Reader category: its cover, then its articles, which can be narrowed to a level (A2…C2, for picking
/// something that suits) and ordered newest, easiest or shortest first.
struct SiteCategoryView: View {
    let category: SiteCategory
    /// How an article's card looks right now (opened here, audio, being fetched), from the library.
    let state: (SiteArticleSummary) -> SiteArticleRow.State
    /// Articles are being fetched for a download.
    let isPreparingDownload: Bool
    let onOpen: (SiteArticleSummary) -> Void
    /// Download the narration of these, free.
    let onDownload: ([SiteArticleSummary]) -> Void
    @State private var site = SiteLibrary.shared
    @AppStorage(SettingsKeys.siteArticleOrder) private var order = SiteArticleOrder.newest
    @State private var level: String?

    private var all: [SiteArticleSummary] {
        site.articles.filter { $0.siteCategory == category }
    }

    private var shown: [SiteArticleSummary] {
        let chosen = level.map { level in all.filter { $0.cefr?.uppercased() == level } } ?? all
        return SiteCategories.sorted(chosen, by: order)
    }

    var body: some View {
        let all = all
        let levels = SiteCategories.levels(in: all)
        List {
            Section {
                banner(count: all.count, levels: levels)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                if levels.count > 1 {
                    levelPicker(levels)
                        .listRowInsets(EdgeInsets(top: 12, leading: 0, bottom: 0, trailing: 0))
                        .listRowBackground(Color.clear)
                }
            }
            Section {
                ForEach(shown, id: \.id) { summary in
                    Button {
                        onOpen(summary)
                    } label: {
                        SiteArticleRow(summary: summary, state: state(summary), showsThumbnail: false)
                            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: SwipeRevealRow<EmptyView>.cornerRadius, style: .continuous))
                            .contentShape(RoundedRectangle(cornerRadius: SwipeRevealRow<EmptyView>.cornerRadius, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 5, leading: 0, bottom: 5, trailing: 0))
                }
            }
        }
        .listSectionSpacing(.compact)
        .overlay {
            if all.isEmpty {
                ContentUnavailableView("No Articles", systemImage: "books.vertical", description: Text("This category has no articles on English Reader now."))
            }
        }
        .navigationTitle(category.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                if isPreparingDownload {
                    ProgressView()
                } else {
                    Menu {
                        Picker("Order", selection: $order) {
                            ForEach(SiteArticleOrder.allCases) { Text($0.title).tag($0) }
                        }
                        Section {
                            let articles = shown
                            Button(articles.count == 1 ? "Download Audio" : "Download Audio of All \(articles.count)", systemImage: "arrow.down.circle") {
                                onDownload(articles)
                            }
                            .disabled(articles.isEmpty)
                        }
                    } label: {
                        Label("Order and Download", systemImage: "ellipsis")
                    }
                }
            }
        }
    }

    private func banner(count: Int, levels: [String]) -> some View {
        CategoryArt(theme: .forCategory(category.name))
            .overlay {
                LinearGradient(colors: [.clear, .black.opacity(0.3)], startPoint: .center, endPoint: .bottom)
            }
            .overlay(alignment: .bottomLeading) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(category.name)
                        .font(.system(.largeTitle, design: .serif, weight: .bold))
                        .lineLimit(2)
                        .minimumScaleFactor(0.6)
                    Text(summaryLine(count: count, levels: levels))
                        .font(.subheadline.weight(.semibold))
                        .opacity(0.9)
                    if let description = site.info(for: category)?.description, !description.isEmpty {
                        Text(description)
                            .font(.footnote)
                            .lineLimit(2)
                            .opacity(0.85)
                    }
                }
                .foregroundStyle(.white)
                .padding(20)
            }
            .frame(height: 190)
            .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
            .accessibilityElement(children: .combine)
    }

    /// "12 articles · B1 to C2".
    private func summaryLine(count: Int, levels: [String]) -> String {
        let articles = count == 1 ? "1 article" : "\(count) articles"
        guard let easiest = levels.first, let hardest = levels.last else { return articles }
        return easiest == hardest ? "\(articles) · \(easiest)" : "\(articles) · \(easiest) to \(hardest)"
    }

    private func levelPicker(_ levels: [String]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                chip("All Levels", isOn: level == nil) { level = nil }
                ForEach(levels, id: \.self) { value in
                    chip(value, isOn: level == value) { level = level == value ? nil : value }
                }
            }
        }
        .scrollClipDisabled()
    }

    private func chip(_ title: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .foregroundStyle(isOn ? Color.white : Color.primary)
                .background(isOn ? AnyShapeStyle(Color(rgb: CategoryTheme.forCategory(category.name).bottom)) : AnyShapeStyle(Color(.secondarySystemGroupedBackground)), in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}
