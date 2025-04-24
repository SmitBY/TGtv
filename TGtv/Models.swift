import Foundation

enum TG {
    struct Chat {
        let id: Int64
        let title: String
        let lastMessage: String
    }
    
    struct Message {
        let id: Int64
        let text: String
        let isOutgoing: Bool
        let media: MessageMedia?
        let date: Date
    }
    
    enum MessageMedia {
        case photo(path: String)
        case video(path: String)
        case document(path: String)
    }
} 