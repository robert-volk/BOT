import Foundation
import Photos
import Vision
import NaturalLanguage
import UIKit

/// Reads photos in the albums you choose: visible text (Apple's on-device text recognition) and what the picture
/// shows (on-device image classification). Nothing is uploaded, and photo text is never sent to Claude.
enum PhotoIndexer {
    struct Album: Identifiable {
        let id: String
        let name: String
        let count: Int
    }

    struct Item {
        var assetID: String
        var date: Date?
        var text: String
        var vector: [Float]
    }

    static func authorize() async -> Bool {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        return status == .authorized || status == .limited
    }

    // MARK: Albums

    private static func entry(_ c: PHAssetCollection) -> Album? {
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
        let n = PHAsset.fetchAssets(in: c, options: options).count
        guard n > 0, let title = c.localizedTitle else { return nil }
        return Album(id: c.localIdentifier, name: title, count: n)
    }

    /// A short, useful list: Recents, Screenshots, Favorites and your own albums.
    static func albums() -> [Album] {
        var out: [Album] = []
        let wanted: [PHAssetCollectionSubtype] = [.smartAlbumUserLibrary, .smartAlbumScreenshots, .smartAlbumFavorites]
        PHAssetCollection.fetchAssetCollections(with: .smartAlbum, subtype: .any, options: nil).enumerateObjects { c, _, _ in
            if wanted.contains(c.assetCollectionSubtype), let a = entry(c) { out.append(a) }
        }
        PHAssetCollection.fetchAssetCollections(with: .album, subtype: .albumRegular, options: nil).enumerateObjects { c, _, _ in
            if let a = entry(c) { out.append(a) }
        }
        return out
    }

    /// The newest photos in these albums that haven't been read yet (up to `limit` per run).
    static func newAssetIDs(inAlbums ids: [String], excluding known: Set<String>, limit: Int) -> [String] {
        var out: [String] = []
        var seen = Set<String>()
        let collections = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: ids, options: nil)
        collections.enumerateObjects { c, _, _ in
            let options = PHFetchOptions()
            options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
            options.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
            PHAsset.fetchAssets(in: c, options: options).enumerateObjects { asset, _, stop in
                if out.count >= limit { stop.pointee = true; return }
                let id = asset.localIdentifier
                if !known.contains(id), seen.insert(id).inserted { out.append(id) }
            }
        }
        return out
    }

    // MARK: Reading a photo

    static func loadImage(_ assetID: String, side: CGFloat) async -> UIImage? {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [assetID], options: nil).firstObject else { return nil }
        return await withCheckedContinuation { continuation in
            let options = PHImageRequestOptions()
            options.isNetworkAccessAllowed = true       // iCloud Photos: download the picture when needed
            options.deliveryMode = .highQualityFormat
            options.resizeMode = .fast
            var finished = false
            PHImageManager.default().requestImage(for: asset, targetSize: CGSize(width: side, height: side),
                                                  contentMode: .aspectFit, options: options) { image, info in
                if let degraded = info?[PHImageResultIsDegradedKey] as? Bool, degraded { return }
                if !finished {
                    finished = true
                    continuation.resume(returning: image)
                }
            }
        }
    }

    /// Text and a one-line description for a photo, plus its search vector.
    static func describe(assetID: String, embedder: NLEmbedding?) async -> Item? {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [assetID], options: nil).firstObject,
              let image = await loadImage(assetID, side: 1600), let cg = image.cgImage else { return nil }
        let orientation = CGImagePropertyOrientation(image.imageOrientation)
        let (labels, ocr) = await Task.detached(priority: .utility) { () -> ([String], String) in
            let classify = VNClassifyImageRequest()
            let handler = VNImageRequestHandler(cgImage: cg, orientation: orientation, options: [:])
            try? handler.perform([classify])
            let labels = (classify.results ?? [])
                .filter { $0.confidence > 0.35 }
                .prefix(6)
                .map { $0.identifier.replacingOccurrences(of: "_", with: " ") }
            return (Array(labels), TextReader.recognize(cg, orientation: orientation))
        }.value

        let formatter = DateFormatter()
        formatter.dateStyle = .long
        var text = "Photo taken " + (asset.creationDate.map { formatter.string(from: $0) } ?? "on an unknown date") + "."
        if !labels.isEmpty { text += " Looks like: " + labels.joined(separator: ", ") + "." }
        if !ocr.isEmpty { text += " Text in photo: " + String(ocr.prefix(1200)) }
        return Item(assetID: assetID, date: asset.creationDate, text: text, vector: DocumentIndexer.embed(text, using: embedder))
    }
}

// MARK: - Dates in spoken photo searches

enum DateWindow {
    /// "yesterday", "last week", "last month", "this year", "in March", "in March 2025", "2024".
    static func parse(_ text: String) -> ClosedRange<Date>? {
        let t = text.lowercased()
        let cal = Calendar.current
        let now = Date()

        func interval(_ component: Calendar.Component, offset: Int) -> ClosedRange<Date>? {
            guard let shifted = cal.date(byAdding: component, value: offset, to: now),
                  let i = cal.dateInterval(of: component, for: shifted) else { return nil }
            return i.start...i.end
        }
        if t.contains("yesterday") { return interval(.day, offset: -1) }
        if t.contains("today") { return interval(.day, offset: 0) }
        if t.contains("last week") { return interval(.weekOfYear, offset: -1) }
        if t.contains("this week") { return interval(.weekOfYear, offset: 0) }
        if t.contains("last month") { return interval(.month, offset: -1) }
        if t.contains("this month") { return interval(.month, offset: 0) }
        if t.contains("last year") { return interval(.year, offset: -1) }
        if t.contains("this year") { return interval(.year, offset: 0) }

        let months = ["january", "february", "march", "april", "may", "june", "july", "august", "september", "october", "november", "december"]
        var year: Int?
        if let r = t.range(of: #"\b(19|20)\d{2}\b"#, options: .regularExpression) { year = Int(t[r]) }
        if let m = months.firstIndex(where: { t.range(of: "\\b" + $0 + "\\b", options: .regularExpression) != nil }) {
            var comps = DateComponents()
            comps.month = m + 1
            comps.year = year ?? cal.component(.year, from: now)
            if year == nil, let candidate = cal.date(from: comps), candidate > now { comps.year = comps.year! - 1 }   // "March" means the latest March
            if let start = cal.date(from: comps), let i = cal.dateInterval(of: .month, for: start) { return i.start...i.end }
        }
        if let year {
            var comps = DateComponents()
            comps.year = year
            if let start = cal.date(from: comps), let i = cal.dateInterval(of: .year, for: start) { return i.start...i.end }
        }
        return nil
    }
}

enum PhotoIntent {
    /// "find photos of the receipt from March", "show me the screenshot with the flight number"
    /// → the topic ("the receipt from March"). Empty topic means "just show recent ones".
    static func parse(_ raw: String) -> String? {
        let t = VisualIntent.stripPolite(raw.trimmingCharacters(in: CharacterSet(charactersIn: " .!?")))
        let pattern = #"^(?:please )?(?:find|show|pull up|look for|search|get|display|bring up|give)\b.{0,25}?\b(?:photos?|pictures?|pics?|screenshots?|images?)\b(?:\s+(?:of|with|about|from|for|showing|containing))?\s*(.*)$"#
        if let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
           let m = re.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)),
           let r = Range(m.range(at: 1), in: t) {
            return String(t[r]).trimmingCharacters(in: .whitespaces)
        }
        return nil
    }
}
