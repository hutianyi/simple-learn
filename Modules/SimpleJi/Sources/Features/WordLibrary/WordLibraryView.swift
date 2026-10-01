import CoreData
import SwiftUI

struct WordLibraryView: View {
    @State private var searchText = ""

    var body: some View {
        WordLibraryResults(searchText: searchText)
            .searchable(text: $searchText, prompt: "搜索英文或中文")
            .navigationTitle("词库")
            .navigationBarTitleDisplayMode(.inline)
    }
}

private struct WordLibraryResults: View {
    @FetchRequest private var words: FetchedResults<WordEntity>

    init(searchText: String) {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let predicate: NSPredicate? = trimmed.isEmpty
            ? nil
            : NSPredicate(
                format: "english CONTAINS[cd] %@ OR chinese CONTAINS[cd] %@",
                trimmed,
                trimmed
            )

        let request = WordEntity.fetchRequest()
        request.sortDescriptors = [
            NSSortDescriptor(keyPath: \WordEntity.createdAt, ascending: false),
            NSSortDescriptor(keyPath: \WordEntity.importPosition, ascending: true),
            NSSortDescriptor(keyPath: \WordEntity.normalizedEnglish, ascending: true)
        ]
        request.predicate = predicate
        _words = FetchRequest(fetchRequest: request, animation: .default)
    }

    var body: some View {
        Group {
            if words.isEmpty {
                VStack(spacing: 14) {
                    Image(systemName: "books.vertical")
                        .font(.system(size: 40))
                        .foregroundStyle(AppPalette.accent)
                    Text("没有找到单词")
                        .font(.title3.weight(.bold))
                    Text("可以返回首页添加单词，或者换一个搜索词。")
                        .foregroundStyle(AppPalette.textSecondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(AppPalette.background)
            } else {
                List {
                    Section {
                        ForEach(words, id: \.objectID) { word in
                            NavigationLink {
                                WordDetailView(word: word)
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(word.english)
                                        .font(.headline)
                                    Text(word.chinese)
                                        .font(.subheadline)
                                        .foregroundStyle(AppPalette.textSecondary)
                                }
                                .padding(.vertical, 4)
                            }
                        }
                    } header: {
                        Text("\(words.count) 个单词")
                    }
                }
                .listStyle(.insetGrouped)
            }
        }
    }
}
