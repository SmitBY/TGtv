import Foundation
import TDLibKit
import Combine

final class ChatListViewModel: ObservableObject {
    let client: TDLibClient
    private var cachedChats: [TDLibKit.Chat] = []
    @Published private(set) var chats: [TG.Chat] = []
    @Published private(set) var error: Swift.Error?
    @Published private(set) var isLoading = false
    @Published private(set) var loadingProgress = "Загрузка чатов..."
    
    init(client: TDLibClient) {
        self.client = client
        // Запускаем загрузку чатов при инициализации
        Task { @MainActor in
            try? await loadChats()
        }
    }
    
    @MainActor
    func handleUpdate(_ update: TDLibKit.Update) {
        print("ChatListViewModel: Получено обновление \(type(of: update))")
        switch update {
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
                Task {
                    if let chat = try? await client.getChat(chatId: update.chatId) {
                        cachedChats[index] = chat
                        updateChats()
                    }
                }
            }
        case .updateAuthorizationState(let state):
            if case .authorizationStateReady = state.authorizationState {
                print("ChatListViewModel: Авторизация успешна, загружаем чаты")
                Task {
                    try? await loadChats()
                }
            }
        default:
            break
        }
    }
    
    @MainActor
    func loadChats() async throws {
        guard !isLoading else {
            print("ChatListViewModel: Загрузка чатов уже выполняется")
            return
        }
        
        isLoading = true
        loadingProgress = "Загрузка списка чатов..."
        
        do {
            print("ChatListViewModel: Загрузка чатов")
            _ = try await client.loadChats(chatList: .chatListMain, limit: 20)
            
            let maxRetries = 5
            var retryCount = 0
            var gotChats = false
            
            while !gotChats && retryCount < maxRetries {
                do {
                    loadingProgress = "Получение списка чатов... (попытка \(retryCount + 1))"
                    // Явно запрашиваем список чатов
                    let chatList = try await client.getChats(chatList: .chatListMain, limit: 20)
                    print("ChatListViewModel: Получено \(chatList.chatIds.count) чатов")
                    
                    if chatList.chatIds.isEmpty {
                        // Если чатов нет, пробуем еще раз через секунду
                        retryCount += 1
                        try await Task.sleep(nanoseconds: 1_000_000_000) // 1 секунда
                        continue
                    }
                    
                    gotChats = true
                    cachedChats = []
                    
                    for (index, chatId) in chatList.chatIds.enumerated() {
                        loadingProgress = "Загрузка чата \(index + 1) из \(chatList.chatIds.count)..."
                        do {
                            let chat = try await client.getChat(chatId: chatId)
                            cachedChats.append(chat)
                            print("ChatListViewModel: Загружен чат \(chat.title)")
                            updateChats() // Обновляем UI по мере загрузки каждого чата
                        } catch {
                            print("ChatListViewModel: Ошибка при загрузке чата \(chatId): \(error)")
                        }
                    }
                } catch {
                    print("ChatListViewModel: Ошибка при получении списка чатов: \(error)")
                    retryCount += 1
                    try await Task.sleep(nanoseconds: 1_000_000_000) // 1 секунда
                }
            }
            
            if !gotChats {
                print("ChatListViewModel: Не удалось загрузить чаты после \(maxRetries) попыток")
                self.error = NSError(domain: "ChatListViewModel", code: 1, userInfo: [NSLocalizedDescriptionKey: "Не удалось загрузить чаты"])
            }
        } catch {
            print("ChatListViewModel: Ошибка загрузки чатов: \(error)")
            self.error = error
        }
        
        isLoading = false
        loadingProgress = ""
        print("ChatListViewModel: Загрузка чатов завершена, всего: \(cachedChats.count)")
    }
    
    private func updateChats() {
        print("ChatListViewModel: Обновление списка чатов, количество: \(cachedChats.count)")
        chats = cachedChats.map { chat in
            TG.Chat(
                id: chat.id,
                title: chat.title,
                lastMessage: getMessageText(from: chat.lastMessage)
            )
        }
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