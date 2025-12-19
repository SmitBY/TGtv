import Foundation
import TDLibKit
import Combine
import UIKit

final class ChatListViewModel: ObservableObject {
    let client: TDLibClient
    private var cachedChats: [TDLibKit.Chat] = []
    private var remoteSearchChats: [TG.Chat] = []
    private var hashtagSearchChats: [TG.Chat] = []
    private var searchTask: Task<Void, Never>?
    private let cacheQueue = DispatchQueue(label: "com.tgtv.chatList.cache", qos: .utility)
    private let cacheFileURL: URL
    private var isChatsUpdateScheduled = false
    
    // MARK: - Avatars
    
    private let avatarCache = NSCache<NSNumber, UIImage>()
    private var avatarTasks: [Int64: Task<Void, Never>] = [:]
    private var avatarFileIdByChatId: [Int64: Int] = [:]
    private var avatarLastRequestAt: [Int64: TimeInterval] = [:]
    private let avatarRequestMinInterval: TimeInterval = 10
    private let avatarDidUpdateSubject = PassthroughSubject<Int64, Never>()
    
    var avatarDidUpdate: AnyPublisher<Int64, Never> {
        avatarDidUpdateSubject.eraseToAnyPublisher()
    }
    
    @Published private(set) var chats: [TG.Chat] = []
    @Published private(set) var filteredChats: [TG.Chat] = []
    @Published private(set) var searchQuery: String = ""
    @Published private(set) var error: Swift.Error?
    @Published private(set) var isLoading = false
    @Published private(set) var loadingProgress = "Загрузка чатов..."
    // Флаг, указывающий были ли уже загружены чаты
    private var hasLoadedChatsOnce = false
    
    init(client: TDLibClient) {
        self.client = client
        self.cacheFileURL = ChatListViewModel.makeCacheURL()
        
        Task { [weak self] in
            guard let self else { return }
            let cachedSnapshot = self.restoreChatsFromDisk()
            if !cachedSnapshot.isEmpty {
                await MainActor.run {
                    self.chats = cachedSnapshot
                    self.filteredChats = cachedSnapshot
                }
            }
            try? await self.loadChats()
        }
    }
    
    deinit {
        searchTask?.cancel()
    }
    
    @MainActor
    func handleUpdate(_ update: TDLibKit.Update) {
        if !cachedChats.isEmpty && isLoading && hasLoadedChatsOnce {
            isLoading = false
            loadingProgress = ""
        }
        
        switch update {
        case .updateAuthorizationState(let stateUpdate):
            let newState = stateUpdate.authorizationState
            switch newState {
            case .authorizationStateReady:
                // Загружаем чаты только при первой авторизации, если еще не загружали
                if !hasLoadedChatsOnce {
                    Task { @MainActor in
                        try? await loadChats()
                    }
                }
            default:
                break
            }
        case .updateNewChat(let update):
            upsertChat(update.chat)
            scheduleChatsUpdate()
        case .updateChatLastMessage(let update):
            if let index = cachedChats.firstIndex(where: { $0.id == update.chatId }) {
                let updatedChat = cachedChats[index]
                let newChat = updatedChat.updating(lastMessage: update.lastMessage)
                upsertChat(newChat)
                scheduleChatsUpdate()
            }
        case .updateChatPosition(let chatPositionUpdate):
            // Обновляем только позицию чата, если он уже есть в кеше
            if let index = cachedChats.firstIndex(where: { $0.id == chatPositionUpdate.chatId }) {
                // Получаем обновленный список позиций
                let currentPositions = cachedChats[index].positions
                let filteredPositions = currentPositions.filter { $0.list != chatPositionUpdate.position.list }
                let newPositions = filteredPositions + [chatPositionUpdate.position]
                
                let updatedChat = cachedChats[index]
                let newChat = updatedChat.updating(positions: newPositions)
                upsertChat(newChat)
                scheduleChatsUpdate()
            }
            
        case .updateChatPhoto(let update):
            if let index = cachedChats.firstIndex(where: { $0.id == update.chatId }) {
                let updatedChat = cachedChats[index]
                let newChat = updatedChat.updating(photo: update.photo)
                upsertChat(newChat)
                invalidateAvatarCache(chatId: update.chatId)
                scheduleChatsUpdate()
            }
        case .updateChatTitle(let update):
            if let index = cachedChats.firstIndex(where: { $0.id == update.chatId }) {
                let updatedChat = cachedChats[index]
                let newChat = updatedChat.updating(title: update.title)
                upsertChat(newChat)
                scheduleChatsUpdate()
            }
        case .updateChatUnreadMentionCount(let update):
            if let index = cachedChats.firstIndex(where: { $0.id == update.chatId }) {
                let updatedChat = cachedChats[index]
                let newChat = updatedChat.updating(unreadMentionCount: update.unreadMentionCount)
                upsertChat(newChat)
                scheduleChatsUpdate()
            }
        case .updateChatUnreadReactionCount(let update):
            if let index = cachedChats.firstIndex(where: { $0.id == update.chatId }) {
                let updatedChat = cachedChats[index]
                let newChat = updatedChat.updating(unreadReactionCount: update.unreadReactionCount)
                upsertChat(newChat)
                scheduleChatsUpdate()
            }
        case .updateChatReadInbox(let update):
            if let index = cachedChats.firstIndex(where: { $0.id == update.chatId }) {
                let updatedChat = cachedChats[index]
                let newChat = updatedChat.updating(
                    unreadCount: update.unreadCount,
                    lastReadInboxMessageId: update.lastReadInboxMessageId
                )
                upsertChat(newChat)
                scheduleChatsUpdate()
            }
        case .updateChatReadOutbox(let update):
            if let index = cachedChats.firstIndex(where: { $0.id == update.chatId }) {
                let updatedChat = cachedChats[index]
                let newChat = updatedChat.updating(lastReadOutboxMessageId: update.lastReadOutboxMessageId)
                upsertChat(newChat)
                updateChats()
            }
        case .updateChatDraftMessage:
            break
        default:
            break
        }
    }
    
    @MainActor
    func loadChats() async throws {
        // Проверяем, загружали ли мы уже чаты
        if hasLoadedChatsOnce {
            return
        }
        
        guard !isLoading else {
            return
        }
        
        isLoading = true
        error = nil
        loadingProgress = "Загрузка списка чатов..."
        
        do {
            cachedChats = []
            
            // Загружаем список чатов
            _ = try await client.loadChats(chatList: .chatListMain, limit: 20)
            
            // Получаем список загруженных чатов
            let response = try await client.getChats(chatList: .chatListMain, limit: 50)
            let chatIds = response.chatIds
            
            loadingProgress = "Загружено \(chatIds.count) чатов"
            
            // Загружаем детали чатов
            for chatId in chatIds {
                do {
                    let chat = try await client.getChat(chatId: chatId)
                    upsertChat(chat)
                } catch { }
            }
            updateChats()
            
            // Устанавливаем флаг, что чаты уже загружены
            hasLoadedChatsOnce = true
            
            loadingProgress = "" // Очищаем сообщение о загрузке
            isLoading = false
        } catch {
            self.error = error
            loadingProgress = "" // Очищаем сообщение о загрузке даже при ошибке
            isLoading = false
        }
    }
    
    @MainActor
    func updateSearchQuery(_ text: String) {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized != searchQuery else { return }
        searchQuery = normalized
        
        if normalized.isEmpty {
            remoteSearchChats = []
            hashtagSearchChats = []
            searchTask?.cancel()
            searchTask = nil
            applyChatFilter()
            return
        }
        
        if normalized.count < 3 {
            remoteSearchChats = []
        }
        
        applyChatFilter()
        startSearchTaskIfNeeded(for: normalized)
    }
    
    private func startSearchTaskIfNeeded(for query: String) {
        let needsChats = query.count >= 3
        let needsHashtags = query.contains("#")
        guard needsChats || needsHashtags else { return }
        
        searchTask?.cancel()
        searchTask = Task { [weak self] in
            await self?.performRemoteSearch(for: query, includeChats: needsChats, includeHashtags: needsHashtags)
        }
    }
    
    private func performRemoteSearch(for query: String, includeChats: Bool, includeHashtags: Bool) async {
        let remote = includeChats ? await fetchServerSideChats(query: query) : []
        let hashtags = includeHashtags ? await fetchHashtagChats(query: query) : []
        
        await MainActor.run {
            guard self.searchQuery == query else { return }
            if includeChats {
                self.remoteSearchChats = remote
            } else {
                self.remoteSearchChats = []
            }
            if includeHashtags {
                self.hashtagSearchChats = hashtags
            } else {
                self.hashtagSearchChats = []
            }
            self.applyChatFilter()
        }
    }
    
    private func fetchServerSideChats(query: String) async -> [TG.Chat] {
        do {
            let serverResult = try await client.searchChatsOnServer(limit: 25, query: query)
            let publicResult = try await client.searchPublicChats(query: query)
            var combinedIds: [Int64] = []
            for id in serverResult.chatIds {
                if !combinedIds.contains(id) {
                    combinedIds.append(id)
                }
            }
            for id in publicResult.chatIds {
                if !combinedIds.contains(id) {
                    combinedIds.append(id)
                }
            }
            
            let cachedSnapshot = await MainActor.run { self.cachedChats }
            var chats: [TG.Chat] = []
            for chatId in combinedIds {
                if let cached = cachedSnapshot.first(where: { $0.id == chatId }) {
                    chats.append(makeTGChat(from: cached))
                    continue
                }
                do {
                    let chat = try await client.getChat(chatId: chatId)
                    chats.append(makeTGChat(from: chat))
                } catch { }
            }
            return chats
        } catch {
            return []
        }
    }
    
    private func fetchHashtagChats(query: String) async -> [TG.Chat] {
        do {
            let result = try await client.searchMessages(
                chatList: nil,
                chatTypeFilter: nil,
                filter: .searchMessagesFilterVideo,
                limit: 30,
                maxDate: nil,
                minDate: nil,
                offset: nil,
                query: query
            )
            let messages = result.messages
            var seenChats = Set<Int64>()
            var chats: [TG.Chat] = []
            for message in messages {
                guard case .messageVideo = message.content else { continue }
                if seenChats.contains(message.chatId) { continue }
                seenChats.insert(message.chatId)
                
                do {
                    let chat = try await client.getChat(chatId: message.chatId)
                    chats.append(makeTGChat(from: chat))
                } catch { }
            }
            return chats
        } catch {
            return []
        }
    }
    
    @MainActor
    private func applyChatFilter() {
        guard !searchQuery.isEmpty else {
            filteredChats = chats
            return
        }
        
        let query = searchQuery.lowercased()
        let localMatches = chats.filter { matchesSearch($0, query: query) }
        var combined: [TG.Chat] = searchQuery.contains("#")
            ? hashtagSearchChats + localMatches
            : localMatches
        combined.append(contentsOf: remoteSearchChats)
        filteredChats = uniqueChats(combined)
    }
    
    @MainActor
    private func updateChats() {
        // Убеждаемся, что индикатор загрузки скрывается после успешного обновления чатов
        if !cachedChats.isEmpty && !loadingProgress.isEmpty {
            loadingProgress = ""
        }
        
        chats = cachedChats.map { makeTGChat(from: $0) }
        
        // Если мы обновили список чатов и он не пустой, но индикатор загрузки все еще активен, сбрасываем флаг загрузки
        if !chats.isEmpty && isLoading && hasLoadedChatsOnce {
            isLoading = false
        }
        
        applyChatFilter()
        persistChatsSnapshot()
    }
    
    @MainActor
    private func scheduleChatsUpdate() {
        guard !isChatsUpdateScheduled else { return }
        isChatsUpdateScheduled = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.isChatsUpdateScheduled = false
            self.updateChats()
        }
    }
    
    private func chatComesBefore(_ lhs: TDLibKit.Chat, _ rhs: TDLibKit.Chat) -> Bool {
        let lhsOrder = mainChatListOrder(for: lhs)
        let rhsOrder = mainChatListOrder(for: rhs)
        
        if let lhsOrder, let rhsOrder, lhsOrder != rhsOrder {
            return lhsOrder > rhsOrder
        }
        if lhsOrder != nil && rhsOrder == nil {
            return true
        }
        if lhsOrder == nil && rhsOrder != nil {
            return false
        }
        
        let lhsDate = Int64(lhs.lastMessage?.date ?? 0)
        let rhsDate = Int64(rhs.lastMessage?.date ?? 0)
        if lhsDate != rhsDate {
            return lhsDate > rhsDate
        }
        
        return lhs.id > rhs.id
    }
    
    @MainActor
    private func upsertChat(_ chat: TDLibKit.Chat) {
        if let existingIndex = cachedChats.firstIndex(where: { $0.id == chat.id }) {
            cachedChats.remove(at: existingIndex)
        }
        
        let insertIndex = cachedChats.firstIndex(where: { chatComesBefore(chat, $0) }) ?? cachedChats.count
        cachedChats.insert(chat, at: insertIndex)
    }
    
    private func mainChatListOrder(for chat: TDLibKit.Chat) -> Int64? {
        for position in chat.positions {
            let list = position.list
            if case .chatListMain = list {
                return position.order.rawValue
            }
        }
        return nil
    }
    
    private func persistChatsSnapshot() {
        let entries = cachedChats.prefix(60).map { chat in
            ChatCacheEntry(
                id: chat.id,
                title: chat.title,
                lastMessage: "",
                order: mainChatListOrder(for: chat),
                lastMessageDate: Int64(chat.lastMessage?.date ?? 0)
            )
        }
        guard !entries.isEmpty else { return }
        
        cacheQueue.async { [cacheFileURL] in
            do {
                let data = try JSONEncoder().encode(entries)
                try data.write(to: cacheFileURL, options: .atomic)
            } catch {
                print("ChatListViewModel: Не удалось сохранить кэш чатов: \(error)")
            }
        }
    }
    
    private func restoreChatsFromDisk() -> [TG.Chat] {
        do {
            let data = try Data(contentsOf: cacheFileURL)
            let entries = try JSONDecoder().decode([ChatCacheEntry].self, from: data)
            let sortedEntries = entries.sorted(by: cacheEntryComesBefore)
            return sortedEntries.map { TG.Chat(id: $0.id, title: $0.title, lastMessage: $0.lastMessage) }
        } catch {
            return []
        }
    }
    
    private func cacheEntryComesBefore(_ lhs: ChatCacheEntry, _ rhs: ChatCacheEntry) -> Bool {
        if let lhsOrder = lhs.order, let rhsOrder = rhs.order, lhsOrder != rhsOrder {
            return lhsOrder > rhsOrder
        }
        if lhs.order != nil && rhs.order == nil {
            return true
        }
        if lhs.order == nil && rhs.order != nil {
            return false
        }
        if lhs.lastMessageDate != rhs.lastMessageDate {
            return lhs.lastMessageDate > rhs.lastMessageDate
        }
        return lhs.id > rhs.id
    }
    
    private static func makeCacheURL() -> URL {
        let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return directory.appendingPathComponent("chat_list_cache.json")
    }
    
    private struct ChatCacheEntry: Codable {
        let id: Int64
        let title: String
        let lastMessage: String
        let order: Int64?
        let lastMessageDate: Int64
    }
    
    private func makeTGChat(from chat: TDLibKit.Chat, overrideLastMessage: String? = nil) -> TG.Chat {
        TG.Chat(
            id: chat.id,
            title: chat.title,
            lastMessage: overrideLastMessage ?? ""
        )
    }
    
    private func matchesSearch(_ chat: TG.Chat, query: String) -> Bool {
        chat.title.lowercased().contains(query)
    }
    
    private func uniqueChats(_ items: [TG.Chat]) -> [TG.Chat] {
        var seen = Set<Int64>()
        var result: [TG.Chat] = []
        for chat in items {
            if seen.insert(chat.id).inserted {
                result.append(chat)
            }
        }
        return result
    }
    
    // MARK: - Avatar API
    
    func avatarImage(for chatId: Int64) -> UIImage? {
        avatarCache.object(forKey: NSNumber(value: chatId))
    }
    
    @MainActor
    func requestAvatarIfNeeded(chatId: Int64) {
        if avatarCache.object(forKey: NSNumber(value: chatId)) != nil { return }
        if avatarTasks[chatId] != nil { return }
        
        let now = Date().timeIntervalSince1970
        if let last = avatarLastRequestAt[chatId], now - last < avatarRequestMinInterval {
            return
        }
        avatarLastRequestAt[chatId] = now
        
        let task = Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            defer {
                Task { @MainActor in
                    self.avatarTasks[chatId] = nil
                }
            }
            
            guard !Task.isCancelled else { return }
            guard let file = await self.resolveAvatarSmallFile(chatId: chatId) else { return }
            
            let fileId = file.id
            await MainActor.run {
                self.avatarFileIdByChatId[chatId] = fileId
            }
            
            guard let path = await self.ensureDownloadedAvatarPath(file: file) else { return }
            guard !path.isEmpty, FileManager.default.fileExists(atPath: path) else { return }
            guard !Task.isCancelled else { return }
            
            guard let image = UIImage(contentsOfFile: path) else { return }
            guard !Task.isCancelled else { return }
            
            let shouldStore = await MainActor.run { self.avatarFileIdByChatId[chatId] == fileId }
            guard shouldStore else { return }
            
            await MainActor.run {
                self.avatarCache.setObject(image, forKey: NSNumber(value: chatId))
                self.avatarDidUpdateSubject.send(chatId)
            }
        }
        
        avatarTasks[chatId] = task
    }
    
    @MainActor
    private func invalidateAvatarCache(chatId: Int64) {
        avatarTasks[chatId]?.cancel()
        avatarTasks[chatId] = nil
        avatarFileIdByChatId[chatId] = nil
        avatarCache.removeObject(forKey: NSNumber(value: chatId))
        avatarDidUpdateSubject.send(chatId)
    }
    
    private func resolveAvatarSmallFile(chatId: Int64) async -> File? {
        if let file = await MainActor.run(resultType: File?.self, body: {
            self.cachedChats.first(where: { $0.id == chatId })?.photo?.small
        }) {
            return file
        }
        
        do {
            let chat = try await client.getChat(chatId: chatId)
            return chat.photo?.small
        } catch {
            return nil
        }
    }
    
    private func ensureDownloadedAvatarPath(file: File) async -> String? {
        let existingPath = file.local.path
        if !existingPath.isEmpty, FileManager.default.fileExists(atPath: existingPath) {
            return existingPath
        }
        
        guard file.local.canBeDownloaded else { return nil }
        
        do {
            let downloaded = try await client.downloadFile(
                fileId: file.id,
                limit: 0,
                offset: 0,
                priority: 8,
                synchronous: true
            )
            let path = downloaded.local.path
            guard !path.isEmpty, FileManager.default.fileExists(atPath: path) else { return nil }
            return path
        } catch {
            return nil
        }
    }
    
}

private extension TDLibKit.Chat {
    func updating(
        lastMessage: Message? = nil,
        positions: [ChatPosition]? = nil,
        photo: ChatPhotoInfo? = nil,
        title: String? = nil,
        unreadCount: Int? = nil,
        unreadMentionCount: Int? = nil,
        unreadReactionCount: Int? = nil,
        lastReadInboxMessageId: Int64? = nil,
        lastReadOutboxMessageId: Int64? = nil
    ) -> TDLibKit.Chat {
        TDLibKit.Chat(
            accentColorId: self.accentColorId,
            actionBar: self.actionBar,
            availableReactions: self.availableReactions,
            background: self.background,
            backgroundCustomEmojiId: self.backgroundCustomEmojiId,
            blockList: self.blockList,
            businessBotManageBar: self.businessBotManageBar,
            canBeDeletedForAllUsers: self.canBeDeletedForAllUsers,
            canBeDeletedOnlyForSelf: self.canBeDeletedOnlyForSelf,
            canBeReported: self.canBeReported,
            chatLists: self.chatLists,
            clientData: self.clientData,
            defaultDisableNotification: self.defaultDisableNotification,
            draftMessage: self.draftMessage,
            emojiStatus: self.emojiStatus,
            hasProtectedContent: self.hasProtectedContent,
            hasScheduledMessages: self.hasScheduledMessages,
            id: self.id,
            isMarkedAsUnread: self.isMarkedAsUnread,
            isTranslatable: self.isTranslatable,
            lastMessage: lastMessage ?? self.lastMessage,
            lastReadInboxMessageId: lastReadInboxMessageId ?? self.lastReadInboxMessageId,
            lastReadOutboxMessageId: lastReadOutboxMessageId ?? self.lastReadOutboxMessageId,
            messageAutoDeleteTime: self.messageAutoDeleteTime,
            messageSenderId: self.messageSenderId,
            notificationSettings: self.notificationSettings,
            pendingJoinRequests: self.pendingJoinRequests,
            permissions: self.permissions,
            photo: photo ?? self.photo,
            positions: positions ?? self.positions,
            profileAccentColorId: self.profileAccentColorId,
            profileBackgroundCustomEmojiId: self.profileBackgroundCustomEmojiId,
            replyMarkupMessageId: self.replyMarkupMessageId,
            theme: self.theme,
            title: title ?? self.title,
            type: self.type,
            unreadCount: unreadCount ?? self.unreadCount,
            unreadMentionCount: unreadMentionCount ?? self.unreadMentionCount,
            unreadReactionCount: unreadReactionCount ?? self.unreadReactionCount,
            upgradedGiftColors: self.upgradedGiftColors,
            videoChat: self.videoChat,
            viewAsTopics: self.viewAsTopics
        )
    }
}
