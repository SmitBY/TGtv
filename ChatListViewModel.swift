import Foundation
import TDLibKit
import Combine

final class ChatListViewModel: ObservableObject {
    let client: TDLibClient
    private var cachedChats: [TDLibKit.Chat] = [] // Основной кеш объектов TDLibKit.Chat
    @Published private(set) var chats: [TG.Chat] = [] // Публикуемый массив для UI
    @Published private(set) var error: Swift.Error?
    @Published private(set) var isLoading = false
    @Published private(set) var isLoadingMore = false // Флаг для пагинации
    @Published private(set) var loadingProgress = "Загрузка чатов..."

    // Для пагинации
    private var currentOffsetOrder: String = "9223372036854775807"
    private var currentOffsetChatId: Int64 = 0
    private var canLoadMoreChats = true // Флаг, есть ли еще чаты для загрузки

    // Для дебаунсинга UI обновлений
    private var debounceTask: Task<Void, Never>?
    private let debounceInterval: UInt64 = 200_000_000 // 200ms в наносекундах
    private var hasLoadedChatsOnce = false // Флаг, чтобы отследить первую успешную загрузку

    init(client: TDLibClient) {
        self.client = client
        Task { @MainActor in
            await loadInitialChats()
        }
    }

    @MainActor
    func handleUpdate(_ update: TDLibKit.Update) {
        print("ChatListViewModel: Получено обновление \(type(of: update))")
        var chatUpdated = false

        switch update {
        case .updateNewChat(let newChatUpdate):
            print("ChatListViewModel: .updateNewChat для чата \(newChatUpdate.chat.title)")
            if let index = cachedChats.firstIndex(where: { $0.id == newChatUpdate.chat.id }) {
                // Чат уже есть, обновляем его данные на месте
                cachedChats[index] = newChatUpdate.chat
                chatUpdated = true
            } else {
                // Чата нет в кеше. Добавляем его в конец списка.
                print("ChatListViewModel: Добавление нового чата \(newChatUpdate.chat.title) в конец списка.")
                cachedChats.append(newChatUpdate.chat)
                chatUpdated = true
            }

        case .updateChatLastMessage(let lastMessageUpdate):
            print("ChatListViewModel: .updateChatLastMessage для чата \(lastMessageUpdate.chatId)")
            if let index = cachedChats.firstIndex(where: { $0.id == lastMessageUpdate.chatId }) {
                // Обновляем только lastMessage, не меняя позицию
                if let lastMsg = lastMessageUpdate.lastMessage {
                    cachedChats[index].lastMessage = lastMsg
                    // Обновляем и positions, если они приходят, но не сортируем по ним
                    if !lastMessageUpdate.positions.isEmpty {
                       cachedChats[index].positions = lastMessageUpdate.positions
                    }
                    chatUpdated = true
                }
            }

        case .updateChatPosition(let chatPositionUpdate):
            print("ChatListViewModel: .updateChatPosition для чата \(chatPositionUpdate.chatId)")
            if let index = cachedChats.firstIndex(where: { $0.id == chatPositionUpdate.chatId }) {
                // Обновляем только поле positions, если оно есть в нашей модели, или запрашиваем весь чат,
                // но НЕ МЕНЯЕМ ЕГО ПОЛОЖЕНИЕ в cachedChats.
                Task {
                    do {
                        let updatedChat = try await client.getChat(chatId: chatPositionUpdate.chatId)
                        await MainActor.run { 
                            // Обновляем чат на месте
                            self.cachedChats[index] = updatedChat 
                            self._scheduleUiUpdate() // Планируем обновление UI после обновления данных
                        }
                    } catch {
                        print("ChatListViewModel: Ошибка при обновлении чата из updateChatPosition: \(error)")
                    }
                }
            } else {
                 // Чата нет в кеше. Игнорируем обновление позиции, чтобы не нарушать порядок.
                 print("ChatListViewModel: Чат \(chatPositionUpdate.chatId) из updateChatPosition не в кеше. Игнорируем.")
            }

        case .updateAuthorizationState(let stateUpdate):
            let newState = stateUpdate.authorizationState
            print("ChatListViewModel: .updateAuthorizationState, новое состояние: \(newState)")
            switch newState {
            case .authorizationStateReady:
                // Загружаем чаты, если это первый раз после логина, или если предыдущее состояние было "плохим"
                // и мы сбросили hasLoadedChatsOnce.
                if !hasLoadedChatsOnce || cachedChats.isEmpty {
                    print("ChatListViewModel: Состояние Ready, запускаем начальную загрузку чатов (hasLoadedChatsOnce: \(hasLoadedChatsOnce), cachedChats empty: \(cachedChats.isEmpty)).")
                    Task {
                        await loadInitialChats()
                    }
                } else {
                    print("ChatListViewModel: Состояние Ready, но чаты уже были загружены (hasLoadedChatsOnce: \(hasLoadedChatsOnce)). Пропускаем перезагрузку.")
                }
            case .authorizationStateClosed, .authorizationStateClosing, .authorizationStateLoggingOut:
                print("ChatListViewModel: Сессия закрывается/закрыта (\(newState)). Очищаем кеш и сбрасываем флаг загрузки.")
                self.cachedChats = []
                self.chats = [] // Также очищаем опубликованные чаты
                self.hasLoadedChatsOnce = false
                self.canLoadMoreChats = false 
                self.error = nil 
                self._publishChatsFromCache() // Убедимся, что UI обновлен пустым списком
            default:
                print("ChatListViewModel: Промежуточное состояние авторизации: \(newState). Ничего не предпринимаем.")
            }
        
        case .updateChatPhoto(let photoUpdate):
             if let index = cachedChats.firstIndex(where: { $0.id == photoUpdate.chatId }) {
                 print("ChatListViewModel: Обновлено фото для чата \(photoUpdate.chatId)")
                 Task { 
                      if let chat = try? await client.getChat(chatId: photoUpdate.chatId) {
                          await MainActor.run {
                              self.cachedChats[index] = chat // Обновляем на месте
                              self._scheduleUiUpdate()
                          }
                      }
                 }
             }
             
        case .updateChatReadInbox(let readUpdate), .updateChatReadOutbox(let readUpdate):
            let chatId = (update as? UpdateChatReadInbox)?.chatId ?? (update as? UpdateChatReadOutbox)?.chatId ?? 0
             if chatId != 0, let index = cachedChats.firstIndex(where: { $0.id == chatId }) {
                 print("ChatListViewModel: Обновлен статус прочтения для чата \(chatId)")
                 Task {
                     if let chat = try? await client.getChat(chatId: chatId) {
                         await MainActor.run {
                             self.cachedChats[index] = chat // Обновляем на месте
                             self._scheduleUiUpdate()
                         }
                     }
                 }
             }

        default:
            break
        }

        // Если какое-то из синхронных обновлений изменило данные, планируем обновление UI
        if chatUpdated {
            _scheduleUiUpdate()
        }
    }

    @MainActor
    func loadInitialChats(limit: Int = 30) async {
        debounceTask?.cancel()
        
        guard !isLoading else {
            print("ChatListViewModel: Начальная загрузка уже выполняется.")
            return
        }
        print("ChatListViewModel: Запрос на начальную загрузку чатов (limit: \(limit)).")
        isLoading = true
        canLoadMoreChats = true
        loadingProgress = "Загрузка списка чатов..."

        currentOffsetOrder = "9223372036854775807"
        currentOffsetChatId = 0

        do {
            let chatListResponse = try await client.getChats(
                chatList: .chatListMain,
                limit: limit,
                offsetOrder: currentOffsetOrder,
                offsetChatId: currentOffsetChatId
            )
            print("ChatListViewModel: Начальная загрузка: получено \(chatListResponse.chatIds.count) ID чатов.")

            if chatListResponse.chatIds.isEmpty {
                self.cachedChats = []
                self.canLoadMoreChats = false
            } else {
                var newChatsBatch: [TDLibKit.Chat] = []
                for (index, chatId) in chatListResponse.chatIds.enumerated() {
                    if self.isLoading {
                        loadingProgress = "Загрузка деталей чата \(index + 1) из \(chatListResponse.chatIds.count)..."
                    }
                    do {
                        let chat = try await client.getChat(chatId: chatId)
                        newChatsBatch.append(chat)
                    } catch {
                        print("ChatListViewModel: Ошибка при загрузке чата \(chatId) в loadInitialChats: \(error)")
                    }
                }
                // Полностью перезаписываем кеш результатом ПЕРВОЙ загрузки
                self.cachedChats = newChatsBatch 

                if let lastChat = newChatsBatch.last,
                   let lastChatPosition = lastChat.positions.first(where: { $0.list is ChatListMain }) {
                    self.currentOffsetOrder = lastChatPosition.order.description
                    self.currentOffsetChatId = lastChat.id
                    self.canLoadMoreChats = newChatsBatch.count == limit
                } else {
                    self.canLoadMoreChats = false
                }
            }
            _publishChatsFromCache()
        } catch {
            print("ChatListViewModel: Ошибка при начальной загрузке чатов: \(error)")
            self.error = error
            self.cachedChats = []
            _publishChatsFromCache()
        }
        isLoading = false
        if !Task.isCancelled {
             loadingProgress = ""
        }
        // Устанавливаем флаг после первой попытки загрузки, даже если она не принесла чатов (например, пустой список)
        // или завершилась ошибкой (чтобы не пытаться снова и снова при .authorizationStateReady, если ошибка постоянна)
        // Но если были чаты - точно true.
        if !self.cachedChats.isEmpty {
            self.hasLoadedChatsOnce = true
        }
    }

    @MainActor
    func loadMoreChats(limit: Int = 20) async {
        debounceTask?.cancel()
        
        guard !isLoadingMore && canLoadMoreChats && !isLoading else {
            if isLoading { print("ChatListViewModel: Начальная загрузка активна, пропускаем loadMoreChats.")}
            if isLoadingMore { print("ChatListViewModel: Загрузка 'еще' уже выполняется.") }
            if !canLoadMoreChats { print("ChatListViewModel: Больше нет чатов для загрузки.") }
            return
        }
        print("ChatListViewModel: Запрос на дозагрузку чатов (limit: \(limit)). OffsetOrder: \(currentOffsetOrder), OffsetChatId: \(currentOffsetChatId).")
        isLoadingMore = true

        do {
            let chatListResponse = try await client.getChats(
                chatList: .chatListMain,
                limit: limit,
                offsetOrder: currentOffsetOrder,
                offsetChatId: currentOffsetChatId
            )
            print("ChatListViewModel: Дозагрузка: получено \(chatListResponse.chatIds.count) ID чатов.")

            if chatListResponse.chatIds.isEmpty {
                canLoadMoreChats = false
            } else {
                var newChatsBatch: [TDLibKit.Chat] = []
                for chatId in chatListResponse.chatIds {
                    // Пропускаем дубликаты на всякий случай
                    if self.cachedChats.contains(where: { $0.id == chatId }) { continue }
                    do {
                        let chat = try await client.getChat(chatId: chatId)
                        newChatsBatch.append(chat)
                    } catch {
                        print("ChatListViewModel: Ошибка при дозагрузке чата \(chatId): \(error)")
                    }
                }
                
                if !newChatsBatch.isEmpty {
                    // Просто добавляем новые чаты в конец
                    self.cachedChats.append(contentsOf: newChatsBatch)
                    
                    if let lastChat = newChatsBatch.last,
                       let lastChatPosition = lastChat.positions.first(where: { $0.list is ChatListMain }) {
                        self.currentOffsetOrder = lastChatPosition.order.description
                        self.currentOffsetChatId = lastChat.id
                        self.canLoadMoreChats = newChatsBatch.count == limit
                    } else {
                        self.canLoadMoreChats = false 
                    }
                    _publishChatsFromCache()
                } else {
                    if !chatListResponse.chatIds.isEmpty && newChatsBatch.isEmpty {
                        print("ChatListViewModel: Дозагрузка не добавила новых чатов, хотя ID были получены. Возможно, конец списка.")
                        self.canLoadMoreChats = false
                    }
                }
            }
        } catch {
            print("ChatListViewModel: Ошибка при дозагрузке чатов: \(error)")
        }
        isLoadingMore = false
    }
    
    @MainActor
    private func _scheduleUiUpdate() {
        debounceTask?.cancel()
        
        debounceTask = Task {
            do {
                try await Task.sleep(nanoseconds: debounceInterval)
                guard !Task.isCancelled else { return }
                
                print("ChatListViewModel: Выполняем отложенное обновление UI")
                _publishChatsFromCache()
            } catch {
                 if !(error is CancellationError) {
                    print("ChatListViewModel: Ошибка в debounceTask: \(error)")
                }
            }
        }
    }

    private func _publishChatsFromCache() {
        // Сортировка не нужна, порядок определяется начальной загрузкой и добавлением в конец
        print("ChatListViewModel: Публикация \(cachedChats.count) чатов в UI.")
        self.chats = cachedChats.map { mapTdChatToTgChat($0) }
    }
    
    private func mapTdChatToTgChat(_ chat: TDLibKit.Chat) -> TG.Chat {
        return TG.Chat(
            id: chat.id,
            title: chat.title,
            lastMessage: getMessageText(from: chat.lastMessage)
        )
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
} 