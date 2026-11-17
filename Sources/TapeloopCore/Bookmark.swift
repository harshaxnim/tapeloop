import Foundation

/// A moment the user marked while recording ("Bookmark Moment"). Bookmarks live in memory with the buffer and age
/// out with it; a save copies the ones inside its range into the recording's metadata.
public struct Bookmark: Codable, Hashable, Identifiable, Sendable {
    /// A stable id.
    public var id: UUID
    /// When the moment happened.
    public var date: Date
    /// An optional label, for example "idea".
    public var label: String?

    /// Creates a bookmark.
    public init(id: UUID = UUID(), date: Date, label: String? = nil) {
        self.id = id
        self.date = date
        self.label = label
    }
}
