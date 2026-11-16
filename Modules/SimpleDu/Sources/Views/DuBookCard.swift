import SwiftUI
import ImageIO
#if canImport(UIKit)
import UIKit

struct DuPhoto: View {
    let package: DuPackage
    let path: String
    var maxPixels: Int = 1600
    @State private var image: UIImage?
    var body: some View {
        Group {
            if let image { Image(uiImage: image).resizable().scaledToFit() }
            else { ProgressView().frame(maxWidth: .infinity, minHeight: 140) }
        }
        .accessibilityLabel(package.content.images.first { $0.path == path }?.alt ?? "正文插图")
        .task(id: package.key + path) {
            guard let data = package.files[path] else { return }
            let limit = maxPixels
            image = await Task.detached(priority: .userInitiated) {
                guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil as UIImage? }
                let options = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                               kCGImageSourceThumbnailMaxPixelSize: limit,
                               kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary
                return CGImageSourceCreateThumbnailAtIndex(source, 0, options).map { UIImage(cgImage: $0) }
            }.value
        }
    }
}

#endif

struct DuBookCard: View {
    let book: DuBook
    private var coverColor: Color {
        switch (book.dayNumber ?? 1) % 4 {
        case 0: Color(red: 0.50, green: 0.38, blue: 0.46)
        case 1: Color(red: 0.57, green: 0.36, blue: 0.22)
        case 2: Color(red: 0.29, green: 0.45, blue: 0.49)
        default: Color(red: 0.34, green: 0.46, blue: 0.38)
        }
    }
    var body: some View {
        VStack(spacing: 9) {
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.white.opacity(0.90))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.black.opacity(0.10)))
                    .padding(.leading, 5).padding(.top, 5)
                RoundedRectangle(cornerRadius: 8)
                    .fill(coverColor.gradient).padding(.trailing, 4).padding(.bottom, 5)
                Rectangle().fill(Color.black.opacity(0.16)).frame(width: 12)
                    .padding(.leading, 5).padding(.vertical, 10)
                Rectangle().fill(Color.white.opacity(0.20)).frame(width: 1)
                    .padding(.leading, 19).padding(.vertical, 10)
                VStack(spacing: 12) {
                    Text(book.dayLabel).font(.system(size: 25, weight: .bold, design: .rounded))
                        .lineLimit(1).minimumScaleFactor(0.7)
                    Rectangle().fill(Color.white.opacity(0.38)).frame(height: 1).padding(.horizontal, 8)
                    Text(book.articleLabel).font(.system(size: 17, weight: .medium, design: .rounded))
                        .lineLimit(1).minimumScaleFactor(0.7)
                }.foregroundStyle(.white)
                    .padding(.leading, 27).padding(.trailing, 15)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }.aspectRatio(0.72, contentMode: .fit)
                .shadow(color: .black.opacity(0.12), radius: 3, x: 1, y: 3)
            Text(book.readingStatus).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(book.shelfLabel)，\(book.article.title)，\(book.readingStatus)")
    }
}
