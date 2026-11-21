import Foundation
import Observation
import ReaderModels

/// 最近浏览：打开过详情、但不在书架上的书，最近的在前（搜索页空闲时展示）
@Observable
final class RecentBooks {
    private(set) var books: [Book] = []
    @ObservationIgnored private let key = "recent.books"
    private static let limit = 12

    init() {
        if let data = UserDefaults.standard.data(forKey: key),
           let list = try? JSONDecoder().decode([Book].self, from: data) {
            books = list
        }
    }

    func record(_ book: Book) {
        var book = book
        book.infoHtml = nil
        book.tocHtml = nil
        books.removeAll { $0.bookUrl == book.bookUrl || ($0.name == book.name && $0.author == book.author) }
        books.insert(book, at: 0)
        if books.count > Self.limit { books.removeLast(books.count - Self.limit) }
        persist()
    }

    func remove(_ book: Book) {
        books.removeAll { $0.bookUrl == book.bookUrl }
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(books) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}
