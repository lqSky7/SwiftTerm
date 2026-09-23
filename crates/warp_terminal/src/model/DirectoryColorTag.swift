import Foundation

/// The colour a directory has been tagged with.
///
/// Warp's directory colour tagging (`warp_features.md` #53): a path-to-colour table matched by longest
/// prefix, so a tag on `~/work` covers everything under it and a tag on `~/work/api` wins inside that.
///
/// The colour is a slot in the terminal's own sixteen rather than a free colour, for the same reason
/// every other colour here is: a tag that invented a hue would stop agreeing with the terminal beside
/// it, and the palette is the thing the user already chose.
struct DirectoryColorTag: Equatable {
    /// An index into the palette's sixteen ANSI slots.
    let paletteIndex: Int

    init(paletteIndex: Int) {
        self.paletteIndex = min(max(paletteIndex, 0), 15)
    }
}

extension DirectoryColorTag {
    /// Where tags live. A value, so a harness can build one without touching a settings file — and so
    /// the settings window, when it arrives, only has to load and save it.
    struct Table: Equatable {
        private var tags: [String: DirectoryColorTag] = [:]

        static let empty = Table()

        init() {}

        var isEmpty: Bool { tags.isEmpty }
        var count: Int { tags.count }

        mutating func tag(_ path: String, as tag: DirectoryColorTag) {
            tags[Self.normalized(path)] = tag
        }

        mutating func untag(_ path: String) {
            tags.removeValue(forKey: Self.normalized(path))
        }

        /// The tag that applies to a directory: the *longest* tagged path that contains it, so the most
        /// specific tag wins.
        ///
        /// The comparison is by path components rather than by string prefix, which is the whole of the
        /// difference between this and `hasPrefix`: `/Users/me/work` must not tag `/Users/me/workshop`.
        func tag(for path: String) -> DirectoryColorTag? {
            let path = Self.normalized(path)
            var best: (length: Int, tag: DirectoryColorTag)?
            for (tagged, tag) in tags {
                guard path == tagged || path.hasPrefix(tagged + "/") else { continue }
                if best == nil || tagged.count > best!.length {
                    best = (tagged.count, tag)
                }
            }
            return best?.tag
        }

        /// A trailing slash is not part of a path's identity, and a tag stored with one would never
        /// match anything.
        private static func normalized(_ path: String) -> String {
            var path = path
            while path.count > 1, path.hasSuffix("/") { path.removeLast() }
            return path
        }
    }
}
