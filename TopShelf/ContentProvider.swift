import TVServices

/// Fills the Top Shelf (the area above the apps when Mindseerr is in the top row) with the trending
/// titles the app last saw on Seerr. Selecting one opens it in the app.
final class ContentProvider: TVTopShelfContentProvider {
    override func loadTopShelfContent(completionHandler: @escaping (TVTopShelfContent?) -> Void) {
        // Turned off in the app's Settings: show the static banner instead.
        guard TopShelfCache.isEnabled else { return completionHandler(nil) }
        let items: [TVTopShelfSectionedItem] = TopShelfCache.load().prefix(20).map { saved in
            let item = TVTopShelfSectionedItem(identifier: "\(saved.type)-\(saved.tmdbId)")
            item.title = saved.title
            item.imageShape = .poster
            if let poster = saved.posterURL {
                item.setImageURL(poster, for: .screenScale1x)
                item.setImageURL(poster, for: .screenScale2x)
            }
            if let link = TopShelfCache.link(type: saved.type, tmdbId: saved.tmdbId) {
                item.displayAction = TVTopShelfAction(url: link)
                item.playAction = TVTopShelfAction(url: link)
            }
            return item
        }
        // Nothing saved yet (the app hasn't loaded Discover): the system shows the static Top Shelf banner.
        guard !items.isEmpty else { return completionHandler(nil) }
        let section = TVTopShelfItemCollection(items: items)
        section.title = "Trending on Seerr"
        completionHandler(TVTopShelfSectionedContent(sections: [section]))
    }
}
