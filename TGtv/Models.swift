import Foundation

enum TG {
    struct Chat: Hashable {
        let id: Int64
        let title: String
        let lastMessage: String
    }
    
    struct Message: Hashable {
        let id: Int64
        let text: String
        let isOutgoing: Bool
        let media: MessageMedia?
        let date: Date
    }
    
    enum MessageMedia: Hashable {
        case photo(path: String)
        case video(VideoInfo)
        case document(path: String)
        
        struct VideoInfo: Hashable {
            let path: String
            let fileId: Int
            let expectedSize: Int64
            let downloadedSize: Int64
            let isDownloadingCompleted: Bool
            let mimeType: String
        }
    }
} 