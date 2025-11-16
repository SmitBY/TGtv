import Foundation
import TDLibKit
import Combine

final class ChatListViewModel: ObservableObject {
    let client: TDLibClient
    private var cachedChats: [TDLibKit.Chat] = []
    private var remoteSearchChats: [TG.Chat] = []
    private var hashtagSearchChats: [TG.Chat] = []
    private var searchTask: Task<Void, Never>?
    
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
        // Запускаем загрузку чатов при инициализации
        Task { @MainActor in
            try? await loadChats()
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
            if let index = cachedChats.firstIndex(where: { $0.id == update.chat.id }) {
                cachedChats[index] = update.chat
            } else {
                cachedChats.append(update.chat)
            }
            updateChats()
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
                cachedChats[index] = newChat
                updateChats()
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
                cachedChats[index] = newChat
                updateChats()
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
                cachedChats[index] = newChat
                updateChats()
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
                cachedChats[index] = newChat
                updateChats()
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
                cachedChats[index] = newChat
                updateChats()
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
                cachedChats[index] = newChat
                updateChats()
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
                cachedChats[index] = newChat
                updateChats()
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
                cachedChats[index] = newChat
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
                    cachedChats.append(chat)
                    updateChats()
                } catch {
                    print("ChatListViewModel: Ошибка при загрузке деталей чата \(chatId): \(error)")
                }
            }
            
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
                filter: nil,
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
                if seenChats.contains(message.chatId) { continue }
                seenChats.insert(message.chatId)
                
                do {
                    let chat = try await client.getChat(chatId: message.chatId)
                    let snippet = makeSnippet(from: message, query: query)
                    chats.append(makeTGChat(from: chat, overrideLastMessage: snippet))
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
    }
    
    private func makeSnippet(from message: TDLibKit.Message, query: String) -> String {
        let text = getMessageText(from: message)
        guard !text.isEmpty else {
            return "Сообщение содержит \(query)"
        }
        return truncate(text, limit: 140)
    }
    
    private func makeTGChat(from chat: TDLibKit.Chat, overrideLastMessage: String? = nil) -> TG.Chat {
        TG.Chat(
            id: chat.id,
            title: chat.title,
            lastMessage: overrideLastMessage ?? getMessageText(from: chat.lastMessage)
        )
    }
    
    private func matchesSearch(_ chat: TG.Chat, query: String) -> Bool {
        chat.title.lowercased().contains(query) || chat.lastMessage.lowercased().contains(query)
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
    
    private func truncate(_ text: String, limit: Int) -> String {
        guard text.count > limit else { return text }
        let endIndex = text.index(text.startIndex, offsetBy: limit)
        return String(text[text.startIndex..<endIndex]) + "…"
    }
    
    private func getMessageText(from message: TDLibKit.Message?) -> String {
        guard let message = message else { return "" }
        switch message.content {
        case .messageText(let text):
            return text.text.text
        case .messagePhoto(let photo):
            return photo.caption.text.isEmpty ? "[Фото]" : photo.caption.text
        case .messageVideo(let video):
            return video.caption.text.isEmpty ? "[Видео]" : video.caption.text
        default:
            return "[Медиа]"
        }
    }
    
    private func getMessageText(from message: TDLibKit.Message) -> String {
        getMessageText(from: Optional(message))
    }
} 
