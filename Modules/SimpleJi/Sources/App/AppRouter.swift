import Foundation

enum AppRoute: Hashable {
    case addWords
    case review
    case dictation
    case extraPractice
}

enum AppPage: String, CaseIterable {
    case study, wordLibrary, statistics, settings

    var title: String {
        switch self {
        case .study: "学习"
        case .wordLibrary: "词库"
        case .statistics: "统计"
        case .settings: "设置"
        }
    }

    var symbol: String {
        switch self {
        case .study: "rectangle.on.rectangle"
        case .wordLibrary: "books.vertical"
        case .statistics: "chart.bar.xaxis"
        case .settings: "gearshape"
        }
    }
}

@MainActor
final class AppRouter: ObservableObject {
    @Published var path: [AppRoute] = []
    @Published var selectedPage: AppPage = .study

    var isStudying: Bool {
        path.contains(.review) || path.contains(.dictation) || path.contains(.extraPractice)
    }

    func push(_ route: AppRoute) {
        selectedPage = .study
        path.append(route)
    }

    func reset() {
        path.removeAll()
        selectedPage = .study
    }
}
