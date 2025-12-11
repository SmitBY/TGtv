import Foundation

final class SelectedChatsStore {
    private let idsKey = "selected_chat_ids"
    private let completedKey = "selected_chat_completed"
    private let defaults = UserDefaults.standard
    
    func load() -> [Int64] {
        defaults.array(forKey: idsKey) as? [Int64] ?? []
    }
    
    func save(ids: [Int64]) {
        defaults.set(ids, forKey: idsKey)
    }
    
    var hasCompletedSelection: Bool {
        defaults.bool(forKey: completedKey)
    }
    
    func markCompleted() {
        defaults.set(true, forKey: completedKey)
    }

    func clear() {
        defaults.removeObject(forKey: idsKey)
        defaults.removeObject(forKey: completedKey)
    }
}
