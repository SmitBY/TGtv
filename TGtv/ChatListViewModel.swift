import Foundation
import TDLibKit
import Combine

final class ChatListViewModel: ObservableObject {
    let client: TDLibClient
    private var cachedChats: [TDLibKit.Chat] = []
    private var remoteSearchChats: [TG.Chat] = []
    private var hashtagSearchChats: [TG.Chat] = []
    private var searchTask: Task<Void, Never>?
    private let cacheQueue = DispatchQueue(label: "com.tgtv.chatList.cache", qos: .utility)
    private let cacheFileURL: URL
    private var isChatsUpdateScheduled = false
    
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
        print("ChatListViewModel: Получено обновление \(type(of: update))")
        
        // Если у нас есть чаты и прошло более 5 секунд с момента загрузки,
        // но isLoading все еще true, сбрасываем это состояние
        if !cachedChats.isEmpty && isLoading && hasLoadedChatsOnce {
            print("ChatListViewModel: Обнаружено зависшее состояние загрузки, сбрасываем")
            isLoading = false
            loadingProgress = ""
        }
        
        switch update {
        case .updateAuthorizationState(let stateUpdate):
            let newState = stateUpdate.authorizationState
            print("ChatListViewModel: .updateAuthorizationState, новое состояние: \(newState)")
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
            print("ChatListViewModel: Получен новый чат: \(update.chat.title)")
            upsertChat(update.chat)
            scheduleChatsUpdate()
        case .updateChatLastMessage(let update):
            print("ChatListViewModel: Обновлено последнее сообщение для чата \(update.chatId)")
            if let index = cachedChats.firstIndex(where: { $0.id == update.chatId }) {
                // Создаем новый экземпляр Chat с обновленным lastMessage
                let updatedChat = cachedChats[index]
                let newChat = TDLibKit.Chat(
                    accentColorId: updatedChat.accentColorId,
                    actionBar: updatedChat.actionBar,
                    availableReactions: updatedChat.availableReactions,
                    background: updatedChat.background,
                    backgroundCustomEmojiId: updatedChat.backgroundCustomEmojiId,
                    blockList: updatedChat.blockList,
                    businessBotManageBar: updatedChat.businessBotManageBar,
                    canBeDeletedForAllUsers: updatedChat.canBeDeletedForAllUsers,
                    canBeDeletedOnlyForSelf: updatedChat.canBeDeletedOnlyForSelf,
                    canBeReported: updatedChat.canBeReported,
                    chatLists: updatedChat.chatLists,
                    clientData: updatedChat.clientData,
                    defaultDisableNotification: updatedChat.defaultDisableNotification,
                    draftMessage: updatedChat.draftMessage,
                    emojiStatus: updatedChat.emojiStatus,
                    hasProtectedContent: updatedChat.hasProtectedContent,
                    hasScheduledMessages: updatedChat.hasScheduledMessages,
                    id: updatedChat.id,
                    isMarkedAsUnread: updatedChat.isMarkedAsUnread,
                    isTranslatable: updatedChat.isTranslatable,
                    lastMessage: update.lastMessage, // Обновляем lastMessage
                    lastReadInboxMessageId: updatedChat.lastReadInboxMessageId,
                    lastReadOutboxMessageId: updatedChat.lastReadOutboxMessageId,
                    messageAutoDeleteTime: updatedChat.messageAutoDeleteTime,
                    messageSenderId: updatedChat.messageSenderId,
                    notificationSettings: updatedChat.notificationSettings,
                    pendingJoinRequests: updatedChat.pendingJoinRequests,
                    permissions: updatedChat.permissions,
                    photo: updatedChat.photo,
                    positions: updatedChat.positions,
                    profileAccentColorId: updatedChat.profileAccentColorId,
                    profileBackgroundCustomEmojiId: updatedChat.profileBackgroundCustomEmojiId,
                    replyMarkupMessageId: updatedChat.replyMarkupMessageId,
                    themeName: updatedChat.themeName,
                    title: updatedChat.title,
                    type: updatedChat.type,
                    unreadCount: updatedChat.unreadCount,
                    unreadMentionCount: updatedChat.unreadMentionCount,
                    unreadReactionCount: updatedChat.unreadReactionCount,
                    videoChat: updatedChat.videoChat,
                    viewAsTopics: updatedChat.viewAsTopics
                )
                upsertChat(newChat)
                scheduleChatsUpdate()
            }
        case .updateChatPosition(let chatPositionUpdate):
            print("ChatListViewModel: Получено обновление позиции чата для \(chatPositionUpdate.chatId). Не перезагружаем список чатов.")
            // Обновляем только позицию чата, если он уже есть в кеше
            if let index = cachedChats.firstIndex(where: { $0.id == chatPositionUpdate.chatId }) {
                // Получаем обновленный список позиций
                let currentPositions = cachedChats[index].positions
                let filteredPositions = currentPositions.filter { $0.list != chatPositionUpdate.position.list }
                let newPositions = filteredPositions + [chatPositionUpdate.position]
                
                // Создаем новую копию чата с обновленными позициями
                let updatedChat = cachedChats[index]
                let newChat = TDLibKit.Chat(
                    accentColorId: updatedChat.accentColorId,
                    actionBar: updatedChat.actionBar,
                    availableReactions: updatedChat.availableReactions,
                    background: updatedChat.background,
                    backgroundCustomEmojiId: updatedChat.backgroundCustomEmojiId,
                    blockList: updatedChat.blockList,
                    businessBotManageBar: updatedChat.businessBotManageBar,
                    canBeDeletedForAllUsers: updatedChat.canBeDeletedForAllUsers,
                    canBeDeletedOnlyForSelf: updatedChat.canBeDeletedOnlyForSelf,
                    canBeReported: updatedChat.canBeReported,
                    chatLists: updatedChat.chatLists,
                    clientData: updatedChat.clientData,
                    defaultDisableNotification: updatedChat.defaultDisableNotification,
                    draftMessage: updatedChat.draftMessage,
                    emojiStatus: updatedChat.emojiStatus,
                    hasProtectedContent: updatedChat.hasProtectedContent,
                    hasScheduledMessages: updatedChat.hasScheduledMessages,
                    id: updatedChat.id,
                    isMarkedAsUnread: updatedChat.isMarkedAsUnread,
                    isTranslatable: updatedChat.isTranslatable,
                    lastMessage: updatedChat.lastMessage,
                    lastReadInboxMessageId: updatedChat.lastReadInboxMessageId,
                    lastReadOutboxMessageId: updatedChat.lastReadOutboxMessageId,
                    messageAutoDeleteTime: updatedChat.messageAutoDeleteTime,
                    messageSenderId: updatedChat.messageSenderId,
                    notificationSettings: updatedChat.notificationSettings,
                    pendingJoinRequests: updatedChat.pendingJoinRequests,
                    permissions: updatedChat.permissions,
                    photo: updatedChat.photo,
                    positions: newPositions, // Обновляем позиции
                    profileAccentColorId: updatedChat.profileAccentColorId,
                    profileBackgroundCustomEmojiId: updatedChat.profileBackgroundCustomEmojiId,
                    replyMarkupMessageId: updatedChat.replyMarkupMessageId,
                    themeName: updatedChat.themeName,
                    title: updatedChat.title,
                    type: updatedChat.type,
                    unreadCount: updatedChat.unreadCount,
                    unreadMentionCount: updatedChat.unreadMentionCount,
                    unreadReactionCount: updatedChat.unreadReactionCount,
                    videoChat: updatedChat.videoChat,
                    viewAsTopics: updatedChat.viewAsTopics
                )
                upsertChat(newChat)
                scheduleChatsUpdate()
            }
            // Не перезагружаем чаты после первой загрузки
            /* 
            Task {
                try? await loadChats()
            }
            */
        case .updateChatPhoto(let update):
            print("ChatListViewModel: Обновлено фото чата \(update.chatId)")
            if let index = cachedChats.firstIndex(where: { $0.id == update.chatId }) {
                let updatedChat = cachedChats[index]
                let newChat = TDLibKit.Chat(
                    accentColorId: updatedChat.accentColorId,
                    actionBar: updatedChat.actionBar,
                    availableReactions: updatedChat.availableReactions,
                    background: updatedChat.background,
                    backgroundCustomEmojiId: updatedChat.backgroundCustomEmojiId,
                    blockList: updatedChat.blockList,
                    businessBotManageBar: updatedChat.businessBotManageBar,
                    canBeDeletedForAllUsers: updatedChat.canBeDeletedForAllUsers,
                    canBeDeletedOnlyForSelf: updatedChat.canBeDeletedOnlyForSelf,
                    canBeReported: updatedChat.canBeReported,
                    chatLists: updatedChat.chatLists,
                    clientData: updatedChat.clientData,
                    defaultDisableNotification: updatedChat.defaultDisableNotification,
                    draftMessage: updatedChat.draftMessage,
                    emojiStatus: updatedChat.emojiStatus,
                    hasProtectedContent: updatedChat.hasProtectedContent,
                    hasScheduledMessages: updatedChat.hasScheduledMessages,
                    id: updatedChat.id,
                    isMarkedAsUnread: updatedChat.isMarkedAsUnread,
                    isTranslatable: updatedChat.isTranslatable,
                    lastMessage: updatedChat.lastMessage,
                    lastReadInboxMessageId: updatedChat.lastReadInboxMessageId,
                    lastReadOutboxMessageId: updatedChat.lastReadOutboxMessageId,
                    messageAutoDeleteTime: updatedChat.messageAutoDeleteTime,
                    messageSenderId: updatedChat.messageSenderId,
                    notificationSettings: updatedChat.notificationSettings,
                    pendingJoinRequests: updatedChat.pendingJoinRequests,
                    permissions: updatedChat.permissions,
                    photo: update.photo, // Обновляем фото
                    positions: updatedChat.positions,
                    profileAccentColorId: updatedChat.profileAccentColorId,
                    profileBackgroundCustomEmojiId: updatedChat.profileBackgroundCustomEmojiId,
                    replyMarkupMessageId: updatedChat.replyMarkupMessageId,
                    themeName: updatedChat.themeName,
                    title: updatedChat.title,
                    type: updatedChat.type,
                    unreadCount: updatedChat.unreadCount,
                    unreadMentionCount: updatedChat.unreadMentionCount,
                    unreadReactionCount: updatedChat.unreadReactionCount,
                    videoChat: updatedChat.videoChat,
                    viewAsTopics: updatedChat.viewAsTopics
                )
                upsertChat(newChat)
                scheduleChatsUpdate()
            }
        case .updateChatTitle(let update):
            print("ChatListViewModel: Обновлено название чата \(update.chatId)")
            if let index = cachedChats.firstIndex(where: { $0.id == update.chatId }) {
                let updatedChat = cachedChats[index]
                let newChat = TDLibKit.Chat(
                    accentColorId: updatedChat.accentColorId,
                    actionBar: updatedChat.actionBar,
                    availableReactions: updatedChat.availableReactions,
                    background: updatedChat.background,
                    backgroundCustomEmojiId: updatedChat.backgroundCustomEmojiId,
                    blockList: updatedChat.blockList,
                    businessBotManageBar: updatedChat.businessBotManageBar,
                    canBeDeletedForAllUsers: updatedChat.canBeDeletedForAllUsers,
                    canBeDeletedOnlyForSelf: updatedChat.canBeDeletedOnlyForSelf,
                    canBeReported: updatedChat.canBeReported,
                    chatLists: updatedChat.chatLists,
                    clientData: updatedChat.clientData,
                    defaultDisableNotification: updatedChat.defaultDisableNotification,
                    draftMessage: updatedChat.draftMessage,
                    emojiStatus: updatedChat.emojiStatus,
                    hasProtectedContent: updatedChat.hasProtectedContent,
                    hasScheduledMessages: updatedChat.hasScheduledMessages,
                    id: updatedChat.id,
                    isMarkedAsUnread: updatedChat.isMarkedAsUnread,
                    isTranslatable: updatedChat.isTranslatable,
                    lastMessage: updatedChat.lastMessage,
                    lastReadInboxMessageId: updatedChat.lastReadInboxMessageId,
                    lastReadOutboxMessageId: updatedChat.lastReadOutboxMessageId,
                    messageAutoDeleteTime: updatedChat.messageAutoDeleteTime,
                    messageSenderId: updatedChat.messageSenderId,
                    notificationSettings: updatedChat.notificationSettings,
                    pendingJoinRequests: updatedChat.pendingJoinRequests,
                    permissions: updatedChat.permissions,
                    photo: updatedChat.photo,
                    positions: updatedChat.positions,
                    profileAccentColorId: updatedChat.profileAccentColorId,
                    profileBackgroundCustomEmojiId: updatedChat.profileBackgroundCustomEmojiId,
                    replyMarkupMessageId: updatedChat.replyMarkupMessageId,
                    themeName: updatedChat.themeName,
                    title: update.title, // Обновляем название
                    type: updatedChat.type,
                    unreadCount: updatedChat.unreadCount,
                    unreadMentionCount: updatedChat.unreadMentionCount,
                    unreadReactionCount: updatedChat.unreadReactionCount,
                    videoChat: updatedChat.videoChat,
                    viewAsTopics: updatedChat.viewAsTopics
                )
                upsertChat(newChat)
                scheduleChatsUpdate()
            }
        case .updateChatUnreadMentionCount(let update):
            print("ChatListViewModel: Обновлено количество непрочитанных упоминаний для чата \(update.chatId)")
            if let index = cachedChats.firstIndex(where: { $0.id == update.chatId }) {
                let updatedChat = cachedChats[index]
                let newChat = TDLibKit.Chat(
                    accentColorId: updatedChat.accentColorId,
                    actionBar: updatedChat.actionBar,
                    availableReactions: updatedChat.availableReactions,
                    background: updatedChat.background,
                    backgroundCustomEmojiId: updatedChat.backgroundCustomEmojiId,
                    blockList: updatedChat.blockList,
                    businessBotManageBar: updatedChat.businessBotManageBar,
                    canBeDeletedForAllUsers: updatedChat.canBeDeletedForAllUsers,
                    canBeDeletedOnlyForSelf: updatedChat.canBeDeletedOnlyForSelf,
                    canBeReported: updatedChat.canBeReported,
                    chatLists: updatedChat.chatLists,
                    clientData: updatedChat.clientData,
                    defaultDisableNotification: updatedChat.defaultDisableNotification,
                    draftMessage: updatedChat.draftMessage,
                    emojiStatus: updatedChat.emojiStatus,
                    hasProtectedContent: updatedChat.hasProtectedContent,
                    hasScheduledMessages: updatedChat.hasScheduledMessages,
                    id: updatedChat.id,
                    isMarkedAsUnread: updatedChat.isMarkedAsUnread,
                    isTranslatable: updatedChat.isTranslatable,
                    lastMessage: updatedChat.lastMessage,
                    lastReadInboxMessageId: updatedChat.lastReadInboxMessageId,
                    lastReadOutboxMessageId: updatedChat.lastReadOutboxMessageId,
                    messageAutoDeleteTime: updatedChat.messageAutoDeleteTime,
                    messageSenderId: updatedChat.messageSenderId,
                    notificationSettings: updatedChat.notificationSettings,
                    pendingJoinRequests: updatedChat.pendingJoinRequests,
                    permissions: updatedChat.permissions,
                    photo: updatedChat.photo,
                    positions: updatedChat.positions,
                    profileAccentColorId: updatedChat.profileAccentColorId,
                    profileBackgroundCustomEmojiId: updatedChat.profileBackgroundCustomEmojiId,
                    replyMarkupMessageId: updatedChat.replyMarkupMessageId,
                    themeName: updatedChat.themeName,
                    title: updatedChat.title,
                    type: updatedChat.type,
                    unreadCount: updatedChat.unreadCount,
                    unreadMentionCount: update.unreadMentionCount, // Обновляем количество упоминаний
                    unreadReactionCount: updatedChat.unreadReactionCount,
                    videoChat: updatedChat.videoChat,
                    viewAsTopics: updatedChat.viewAsTopics
                )
                upsertChat(newChat)
                scheduleChatsUpdate()
            }
        case .updateChatUnreadReactionCount(let update):
            print("ChatListViewModel: Обновлено количество непрочитанных реакций для чата \(update.chatId)")
            if let index = cachedChats.firstIndex(where: { $0.id == update.chatId }) {
                let updatedChat = cachedChats[index]
                let newChat = TDLibKit.Chat(
                    accentColorId: updatedChat.accentColorId,
                    actionBar: updatedChat.actionBar,
                    availableReactions: updatedChat.availableReactions,
                    background: updatedChat.background,
                    backgroundCustomEmojiId: updatedChat.backgroundCustomEmojiId,
                    blockList: updatedChat.blockList,
                    businessBotManageBar: updatedChat.businessBotManageBar,
                    canBeDeletedForAllUsers: updatedChat.canBeDeletedForAllUsers,
                    canBeDeletedOnlyForSelf: updatedChat.canBeDeletedOnlyForSelf,
                    canBeReported: updatedChat.canBeReported,
                    chatLists: updatedChat.chatLists,
                    clientData: updatedChat.clientData,
                    defaultDisableNotification: updatedChat.defaultDisableNotification,
                    draftMessage: updatedChat.draftMessage,
                    emojiStatus: updatedChat.emojiStatus,
                    hasProtectedContent: updatedChat.hasProtectedContent,
                    hasScheduledMessages: updatedChat.hasScheduledMessages,
                    id: updatedChat.id,
                    isMarkedAsUnread: updatedChat.isMarkedAsUnread,
                    isTranslatable: updatedChat.isTranslatable,
                    lastMessage: updatedChat.lastMessage,
                    lastReadInboxMessageId: updatedChat.lastReadInboxMessageId,
                    lastReadOutboxMessageId: updatedChat.lastReadOutboxMessageId,
                    messageAutoDeleteTime: updatedChat.messageAutoDeleteTime,
                    messageSenderId: updatedChat.messageSenderId,
                    notificationSettings: updatedChat.notificationSettings,
                    pendingJoinRequests: updatedChat.pendingJoinRequests,
                    permissions: updatedChat.permissions,
                    photo: updatedChat.photo,
                    positions: updatedChat.positions,
                    profileAccentColorId: updatedChat.profileAccentColorId,
                    profileBackgroundCustomEmojiId: updatedChat.profileBackgroundCustomEmojiId,
                    replyMarkupMessageId: updatedChat.replyMarkupMessageId,
                    themeName: updatedChat.themeName,
                    title: updatedChat.title,
                    type: updatedChat.type,
                    unreadCount: updatedChat.unreadCount,
                    unreadMentionCount: updatedChat.unreadMentionCount,
                    unreadReactionCount: update.unreadReactionCount, // Обновляем количество реакций
                    videoChat: updatedChat.videoChat,
                    viewAsTopics: updatedChat.viewAsTopics
                )
                upsertChat(newChat)
                scheduleChatsUpdate()
            }
        case .updateChatReadInbox(let update):
            print("ChatListViewModel: Обновлено состояние прочтения входящих для чата \(update.chatId)")
            if let index = cachedChats.firstIndex(where: { $0.id == update.chatId }) {
                let updatedChat = cachedChats[index]
                let newChat = TDLibKit.Chat(
                    accentColorId: updatedChat.accentColorId,
                    actionBar: updatedChat.actionBar,
                    availableReactions: updatedChat.availableReactions,
                    background: updatedChat.background,
                    backgroundCustomEmojiId: updatedChat.backgroundCustomEmojiId,
                    blockList: updatedChat.blockList,
                    businessBotManageBar: updatedChat.businessBotManageBar,
                    canBeDeletedForAllUsers: updatedChat.canBeDeletedForAllUsers,
                    canBeDeletedOnlyForSelf: updatedChat.canBeDeletedOnlyForSelf,
                    canBeReported: updatedChat.canBeReported,
                    chatLists: updatedChat.chatLists,
                    clientData: updatedChat.clientData,
                    defaultDisableNotification: updatedChat.defaultDisableNotification,
                    draftMessage: updatedChat.draftMessage,
                    emojiStatus: updatedChat.emojiStatus,
                    hasProtectedContent: updatedChat.hasProtectedContent,
                    hasScheduledMessages: updatedChat.hasScheduledMessages,
                    id: updatedChat.id,
                    isMarkedAsUnread: updatedChat.isMarkedAsUnread,
                    isTranslatable: updatedChat.isTranslatable,
                    lastMessage: updatedChat.lastMessage,
                    lastReadInboxMessageId: update.lastReadInboxMessageId, // Обновляем ID последнего прочитанного входящего сообщения
                    lastReadOutboxMessageId: updatedChat.lastReadOutboxMessageId,
                    messageAutoDeleteTime: updatedChat.messageAutoDeleteTime,
                    messageSenderId: updatedChat.messageSenderId,
                    notificationSettings: updatedChat.notificationSettings,
                    pendingJoinRequests: updatedChat.pendingJoinRequests,
                    permissions: updatedChat.permissions,
                    photo: updatedChat.photo,
                    positions: updatedChat.positions,
                    profileAccentColorId: updatedChat.profileAccentColorId,
                    profileBackgroundCustomEmojiId: updatedChat.profileBackgroundCustomEmojiId,
                    replyMarkupMessageId: updatedChat.replyMarkupMessageId,
                    themeName: updatedChat.themeName,
                    title: updatedChat.title,
                    type: updatedChat.type,
                    unreadCount: update.unreadCount, // Обновляем количество непрочитанных сообщений
                    unreadMentionCount: updatedChat.unreadMentionCount,
                    unreadReactionCount: updatedChat.unreadReactionCount,
                    videoChat: updatedChat.videoChat,
                    viewAsTopics: updatedChat.viewAsTopics
                )
                upsertChat(newChat)
                scheduleChatsUpdate()
            }
        case .updateChatReadOutbox(let update):
            print("ChatListViewModel: Обновлено состояние прочтения исходящих для чата \(update.chatId)")
            if let index = cachedChats.firstIndex(where: { $0.id == update.chatId }) {
                let updatedChat = cachedChats[index]
                let newChat = TDLibKit.Chat(
                    accentColorId: updatedChat.accentColorId,
                    actionBar: updatedChat.actionBar,
                    availableReactions: updatedChat.availableReactions,
                    background: updatedChat.background,
                    backgroundCustomEmojiId: updatedChat.backgroundCustomEmojiId,
                    blockList: updatedChat.blockList,
                    businessBotManageBar: updatedChat.businessBotManageBar,
                    canBeDeletedForAllUsers: updatedChat.canBeDeletedForAllUsers,
                    canBeDeletedOnlyForSelf: updatedChat.canBeDeletedOnlyForSelf,
                    canBeReported: updatedChat.canBeReported,
                    chatLists: updatedChat.chatLists,
                    clientData: updatedChat.clientData,
                    defaultDisableNotification: updatedChat.defaultDisableNotification,
                    draftMessage: updatedChat.draftMessage,
                    emojiStatus: updatedChat.emojiStatus,
                    hasProtectedContent: updatedChat.hasProtectedContent,
                    hasScheduledMessages: updatedChat.hasScheduledMessages,
                    id: updatedChat.id,
                    isMarkedAsUnread: updatedChat.isMarkedAsUnread,
                    isTranslatable: updatedChat.isTranslatable,
                    lastMessage: updatedChat.lastMessage,
                    lastReadInboxMessageId: updatedChat.lastReadInboxMessageId,
                    lastReadOutboxMessageId: update.lastReadOutboxMessageId, // Обновляем ID последнего прочитанного исходящего сообщения
                    messageAutoDeleteTime: updatedChat.messageAutoDeleteTime,
                    messageSenderId: updatedChat.messageSenderId,
                    notificationSettings: updatedChat.notificationSettings,
                    pendingJoinRequests: updatedChat.pendingJoinRequests,
                    permissions: updatedChat.permissions,
                    photo: updatedChat.photo,
                    positions: updatedChat.positions,
                    profileAccentColorId: updatedChat.profileAccentColorId,
                    profileBackgroundCustomEmojiId: updatedChat.profileBackgroundCustomEmojiId,
                    replyMarkupMessageId: updatedChat.replyMarkupMessageId,
                    themeName: updatedChat.themeName,
                    title: updatedChat.title,
                    type: updatedChat.type,
                    unreadCount: updatedChat.unreadCount,
                    unreadMentionCount: updatedChat.unreadMentionCount,
                    unreadReactionCount: updatedChat.unreadReactionCount,
                    videoChat: updatedChat.videoChat,
                    viewAsTopics: updatedChat.viewAsTopics
                )
                upsertChat(newChat)
                updateChats()
            }
        case .updateChatDraftMessage:
            print("ChatListViewModel: updateChatDraftMessage не требует перезагрузки всех чатов")
            // НЕ перезагружаем все чаты
        default:
            print("ChatListViewModel: Необрабатываемое обновление \(type(of: update))")
        }
    }
    
    @MainActor
    func loadChats() async throws {
        // Проверяем, загружали ли мы уже чаты
        if hasLoadedChatsOnce {
            print("ChatListViewModel: Чаты уже были загружены, пропускаем повторную загрузку")
            return
        }
        
        guard !isLoading else {
            print("ChatListViewModel: Загрузка чатов уже идет, пропускаем повторный запрос")
            return
        }
        
        isLoading = true
        error = nil
        loadingProgress = "Загрузка списка чатов..."
        
        do {
            cachedChats = []
            print("ChatListViewModel: Загружаем чаты")
            
            // Загружаем список чатов
            _ = try await client.loadChats(chatList: .chatListMain, limit: 20)
            
            // Получаем список загруженных чатов
            let response = try await client.getChats(chatList: .chatListMain, limit: 50)
            let chatIds = response.chatIds
            
            print("ChatListViewModel: Получено \(chatIds.count) ID чатов")
            loadingProgress = "Загружено \(chatIds.count) чатов"
            
            // Загружаем детали чатов
            for chatId in chatIds {
                do {
                    let chat = try await client.getChat(chatId: chatId)
                    upsertChat(chat)
                } catch {
                    print("ChatListViewModel: Ошибка при загрузке деталей чата \(chatId): \(error)")
                }
            }
            updateChats()
            
            // Устанавливаем флаг, что чаты уже загружены
            hasLoadedChatsOnce = true
            
            print("ChatListViewModel: Загрузка чатов завершена, получено \(cachedChats.count) чатов")
            loadingProgress = "" // Очищаем сообщение о загрузке
            isLoading = false
        } catch {
            print("ChatListViewModel: Ошибка при загрузке чатов: \(error)")
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
                } catch {
                    print("ChatListViewModel: Не удалось получить чат \(chatId): \(error)")
                }
            }
            return chats
        } catch {
            print("ChatListViewModel: Ошибка поиска чатов на сервере: \(error)")
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
                } catch {
                    print("ChatListViewModel: Не удалось загрузить чат \(message.chatId) для хэштега: \(error)")
                }
            }
            return chats
        } catch {
            print("ChatListViewModel: Ошибка поиска по хэштегам: \(error)")
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
        print("ChatListViewModel: Обновление списка чатов, количество: \(cachedChats.count)")
        
        // Убеждаемся, что индикатор загрузки скрывается после успешного обновления чатов
        if !cachedChats.isEmpty && !loadingProgress.isEmpty {
            print("ChatListViewModel: Очищаем индикатор загрузки, так как чаты успешно загружены")
            loadingProgress = ""
        }
        
        chats = cachedChats.map { makeTGChat(from: $0) }
        
        // Если мы обновили список чатов и он не пустой, но индикатор загрузки все еще активен,
        // сбрасываем флаг загрузки
        if !chats.isEmpty && isLoading && hasLoadedChatsOnce {
            print("ChatListViewModel: Завершаем загрузку, так как чаты успешно загружены")
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
    
} 
