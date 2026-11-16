import SwiftUI
import StudyShell

struct DuReaderView: View {
    let store: DuStore
    let bookID: String
    let addToListening: (@MainActor (SimpleDuListeningArticle) async throws -> String)?
    @State private var reading = true
    @State private var initialized = false
    @State private var requestedEvidence: String?
    @State private var showingSources = false
    @State private var offeringListening = false

    var body: some View {
        Group {
            if let book = store.book(bookID) {
                VStack(spacing: 0) {
                    if reading {
                        DuReadingPages(store: store, book: book, evidence: requestedEvidence) {
                            Task {
                                await store.change(bookID) { progress in
                                    if progress.stage == .reading {
                                        progress.stage = .quiz
                                        progress.currentQuestionID = book.article.questions.first?.id
                                    }
                                }
                                if store.message == nil { reading = false }
                            }
                        }
                    } else {
                        DuQuizView(store: store, book: book) { paragraph in
                            requestedEvidence = paragraph; reading = true
                        }
                    }
                }
                .navigationTitle(book.article.title).navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItemGroup(placement: .topBarTrailing) {
                        if reading {
                            Menu {
                                ForEach([24.0, 28.0, 32.0, 36.0], id: \.self) { size in
                                    Button {
                                        Task { await store.change(bookID, fontSize: size) { _ in } }
                                    } label: { Label("\(Int(size)) 号字", systemImage: store.snapshot?.index.fontSize == size ? "checkmark" : "textformat.size") }
                                }
                            } label: { Label("字号", systemImage: "textformat.size") }
                        }
                        Button(reading ? "答题" : "看文章", systemImage: reading ? "checklist" : "book") {
                            if reading {
                                Task {
                                    await store.change(bookID) { progress in
                                        if progress.stage == .reading {
                                            progress.stage = .quiz; progress.currentQuestionID = book.article.questions.first?.id
                                        }
                                    }
                                    if store.message == nil { reading = false }
                                }
                            } else { requestedEvidence = nil; reading = true }
                        }.accessibilityIdentifier("du.toggleReading")
                        Button("资料", systemImage: "info.circle") { showingSources = true }
                    }
                }
                .task {
                    guard !initialized else { return }
                    initialized = true; reading = book.libraryState.readOverride == false || book.progress.stage == .reading
                }
                .task(id: book.shouldOfferListening && !store.busy && !store.saving && store.message == nil && !showingSources) {
                    if addToListening != nil, book.shouldOfferListening, !store.busy, !store.saving,
                       store.message == nil, !showingSources { offeringListening = true }
                }
                .alert("添加到简单听？", isPresented: $offeringListening) {
                    if let addToListening {
                        Button("添加") {
                            Task { await store.answerListeningOffer(bookID, add: true, perform: addToListening) }
                        }.accessibilityIdentifier("du.offerListening.add")
                        Button("暂不添加", role: .cancel) {
                            Task { await store.answerListeningOffer(bookID, add: false, perform: addToListening) }
                        }.accessibilityIdentifier("du.offerListening.skip")
                    }
                } message: {
                    Text("已完成《\(book.article.title)》的阅读和全部题目，要把这篇文章添加到简单听吗？")
                }
                .sheet(isPresented: $showingSources) {
                    NavigationStack {
                        List {
                            Section("事实来源") {
                                ForEach(book.article.sources.indices, id: \.self) { index in
                                    let source = book.article.sources[index]
                                    if let url = URL(string: source.url) { Link(source.title, destination: url) }
                                }
                            }
                            Section("插图说明与来源") {
                                ForEach(book.package.content.images.filter { image in book.article.units.contains { $0.image == image.path } }, id: \.path) { image in
                                    VStack(alignment: .leading, spacing: 8) { Text(image.alt); Text(image.credit).font(.footnote).foregroundStyle(.secondary) }
                                }
                            }
                        }.navigationTitle("家长资料").toolbar { Button("完成") { showingSources = false } }
                    }
                }
            } else { ContentUnavailableView("文章已更新", systemImage: "book", description: Text("请返回书架重新选择文章。")) }
        }
    }
}

private struct DuReadingPages: View {
    let store: DuStore
    let book: DuBook
    let evidence: String?
    let startQuiz: () -> Void
    @State private var pages: [DuPage] = []
    @State private var pageIndex = 0
    @State private var layoutKey = ""
    @State private var appliedEvidence: String?
    @ScaledMetric(relativeTo: .body) private var dynamicScale: CGFloat = 1

    var body: some View {
        GeometryReader { geometry in
            let wide = geometry.size.width >= 760 && geometry.size.height >= 360
            let font = CGFloat(store.snapshot?.index.fontSize ?? 28) * dynamicScale
            let textWidth = wide ? (geometry.size.width - 80) / 2 : geometry.size.width - 48
            let textHeight = wide ? geometry.size.height - 110 : max(150, geometry.size.height * 0.48 - 80)
            let key = "\(Int(textWidth)):\(Int(textHeight)):\(font):\(evidence ?? "")"
            VStack(spacing: 0) {
                if !pages.isEmpty {
                    TabView(selection: $pageIndex) {
                        ForEach(pages.indices, id: \.self) { index in
                            DuReadingPage(package: book.package, page: pages[index], wide: wide)
                                .padding(.horizontal, 24).padding(.top, 12).padding(.bottom, 8)
                                .tag(index)
                        }
                    }.tabViewStyle(.page(indexDisplayMode: .never))
                    HStack(spacing: 20) {
                        Button("上一页", systemImage: "chevron.left") { pageIndex -= 1 }.disabled(pageIndex == 0)
                            .accessibilityIdentifier("du.previousPage")
                        Spacer()
                        Text("\(pageIndex + 1) / \(pages.count)").monospacedDigit().foregroundStyle(.secondary)
                            .accessibilityIdentifier("du.pageNumber")
                        Spacer()
                        if pageIndex + 1 == pages.count {
                            Button("开始答题", systemImage: "checklist", action: startQuiz).buttonStyle(.borderedProminent)
                                .accessibilityIdentifier("du.startQuiz")
                        } else {
                            Button("下一页", systemImage: "chevron.right") { pageIndex += 1 }.buttonStyle(.borderedProminent)
                                .accessibilityIdentifier("du.nextPage")
                        }
                    }.font(.headline).padding(.horizontal, 24).padding(.vertical, 14).background(.bar)
                } else { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
            }
            .task(id: key) {
                let anchor = pages.indices.contains(pageIndex) ? pages[pageIndex].anchor : book.progress.anchor
                let newPages = DuPagination.pages(book.article, width: textWidth, height: textHeight, fontSize: font)
                layoutKey = ""; pages = newPages
                if evidence != appliedEvidence, let evidence, let match = newPages.firstIndex(where: { $0.blocks.contains { $0.paragraphID == evidence } }) { pageIndex = match }
                else if let anchor, let match = newPages.firstIndex(where: { $0.contains(anchor) }) { pageIndex = match }
                else { pageIndex = 0 }
                appliedEvidence = evidence; layoutKey = key
                if newPages.indices.contains(pageIndex) {
                    let position = newPages[pageIndex].anchor
                    let finished = pageIndex == newPages.count - 1
                    await store.change(book.id) {
                        $0.anchor = position
                        if finished { $0.readingCompleted = true }
                    }
                }
            }
            .onChange(of: store.saving) { _, saving in
                guard !saving, store.message == nil, pages.indices.contains(pageIndex) else { return }
                let finished = pageIndex == pages.count - 1
                guard book.progress.anchor != pages[pageIndex].anchor || (finished && book.progress.readingCompleted != true) else { return }
                let anchor = pages[pageIndex].anchor
                Task {
                    await store.change(book.id) {
                        $0.anchor = anchor
                        if finished { $0.readingCompleted = true }
                    }
                }
            }
            .onChange(of: pageIndex) { _, index in
                guard layoutKey == key, pages.indices.contains(index) else { return }
                let anchor = pages[index].anchor
                let finished = index == pages.count - 1
                Task {
                    await store.change(book.id) {
                        $0.anchor = anchor
                        if finished { $0.readingCompleted = true }
                    }
                }
            }
        }
    }
}

private struct DuReadingPage: View {
    let package: DuPackage
    let page: DuPage
    let wide: Bool
    var body: some View {
        Group {
            if wide {
                HStack(alignment: .center, spacing: 32) {
                    DuPhoto(package: package, path: page.unit.image).frame(maxWidth: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: 22))
                    bodyText.frame(maxWidth: .infinity)
                }
            } else {
                VStack(spacing: 16) {
                    DuPhoto(package: package, path: page.unit.image).frame(maxHeight: 220)
                        .clipShape(RoundedRectangle(cornerRadius: 18))
                    bodyText
                }
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    private var bodyText: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if !page.unit.heading.isEmpty { Text(page.unit.heading).font(.title2.bold()).foregroundStyle(.tint) }
                ForEach(page.blocks) { block in
                    Text(block.text).fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier("du.paragraph.\(block.paragraphID)")
                }
            }.padding(.vertical, 4)
        }.defaultScrollAnchor(.top)
    }
}
