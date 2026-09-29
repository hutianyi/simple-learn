import Foundation

struct PlaybackItem: Equatable, Sendable {
    let dayID: UUID
    let articleID: UUID
}

enum PlaybackQueue {
    static func build(_ library: ListenLibrary, order: PlaybackOrder, startingAt: UUID? = nil,
                      avoidingFirst: UUID? = nil) -> [PlaybackItem] {
        var items = library.days.sorted { $0.importSequence < $1.importSequence }.flatMap { day in
            day.articles.sorted { $0.articleNumber < $1.articleNumber }.map { PlaybackItem(dayID: day.id, articleID: $0.id) }
        }
        switch order {
        case .forward: break
        case .reverse: items.reverse()
        case .shuffle:
            items.shuffle()
            if let startingAt, let index = items.firstIndex(where: { $0.articleID == startingAt }) { items.swapAt(0, index) }
            else if items.count > 1, items.first?.articleID == avoidingFirst { items.swapAt(0, 1) }
        }
        return items
    }
}
