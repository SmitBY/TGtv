import UIKit
import TDLibKit
import Combine

// Расширение для ручной обработки JSON от TDLib
extension TDLibKit.Update {
    static func fromRawJSON(_ data: Data) -> TDLibKit.Update? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["@type"] as? String else {
            return nil
        }
        
        // Обработка обновления состояния авторизации
        if type == "updateAuthorizationState",
           let authState = json["authorization_state"] as? [String: Any],
           let authStateType = authState["@type"] as? String {
            
            var state: TDLibKit.AuthorizationState
            
            switch authStateType {
            case "authorizationStateWaitTdlibParameters":
                state = .authorizationStateWaitTdlibParameters
            case "authorizationStateWaitPhoneNumber":
                state = .authorizationStateWaitPhoneNumber
            case "authorizationStateWaitOtherDeviceConfirmation":
                if let link = authState["link"] as? String {
                    state = .authorizationStateWaitOtherDeviceConfirmation(.init(link: link))
                } else {
                    return nil
                }
            case "authorizationStateWaitPassword":
                let passwordHint = authState["password_hint"] as? String ?? ""
                let hasRecoveryEmailAddress = authState["has_recovery_email_address"] as? Bool ?? false
                let hasPassportData = authState["has_passport_data"] as? Bool ?? false
                let recoveryEmailAddressPattern = authState["recovery_email_address_pattern"] as? String ?? ""
                
                state = .authorizationStateWaitPassword(.init(
                    hasPassportData: hasPassportData,
                    hasRecoveryEmailAddress: hasRecoveryEmailAddress,
                    passwordHint: passwordHint,
                    recoveryEmailAddressPattern: recoveryEmailAddressPattern
                ))
            case "authorizationStateReady":
                state = .authorizationStateReady
            case "authorizationStateClosing":
                state = .authorizationStateClosing
            case "authorizationStateClosed":
                state = .authorizationStateClosed
            default:
                return nil
            }
            
            return .updateAuthorizationState(.init(authorizationState: state))
        }
        
        // Обработка обновления состояния подключения
        if type == "updateConnectionState",
           let connState = json["state"] as? [String: Any],
           let connStateType = connState["@type"] as? String {
            
            var state: TDLibKit.ConnectionState
            
            switch connStateType {
            case "connectionStateWaitingForNetwork":
                state = .connectionStateWaitingForNetwork
            case "connectionStateConnecting":
                state = .connectionStateConnecting
            case "connectionStateConnectingToProxy":
                state = .connectionStateConnectingToProxy
            case "connectionStateReady":
                state = .connectionStateReady
            case "connectionStateUpdating":
                state = .connectionStateUpdating
            default:
                return nil
            }
            
            return .updateConnectionState(.init(state: state))
        }
        
        // Обработка обновления типа реакции по умолчанию
        if type == "updateDefaultReactionType",
           let reactionType = json["reaction_type"] as? [String: Any],
           let reactionTypeType = reactionType["@type"] as? String {
            
            if reactionTypeType == "reactionTypeEmoji",
                let emoji = reactionType["emoji"] as? String {
                
                return .updateDefaultReactionType(.init(
                    reactionType: .reactionTypeEmoji(.init(emoji: emoji))
                ))
            }
            
            return nil
        }
        
        // Обработка параметров поиска анимаций
        if type == "updateAnimationSearchParameters",
           let provider = json["provider"] as? String,
           let emojisArray = json["emojis"] as? [String] {
            
            return .updateAnimationSearchParameters(.init(
                emojis: emojisArray,
                provider: provider
            ))
        }
        
        // Обработка обновления удаления сообщений
        if type == "updateDeleteMessages",
           let chatId = json["chat_id"] as? Int64,
           let messageIds = json["message_ids"] as? [Int64],
           let isPermanent = json["is_permanent"] as? Bool,
           let fromCache = json["from_cache"] as? Bool {
            
            let deleteMessages = TDLibKit.UpdateDeleteMessages(
                chatId: chatId,
                fromCache: fromCache,
                isPermanent: isPermanent,
                messageIds: messageIds
            )
            return .updateDeleteMessages(deleteMessages)
        }
        
        return nil
    }
}

@main
class AppDelegate: UIResponder, UIApplicationDelegate {

    var window: UIWindow?
    private var client: TDLibClient?
    private var clientManager: TDLibClientManager?
    private var authService: AuthService?
    private var chatListViewModel: ChatListViewModel?
    private var cancellables = Set<AnyCancellable>()
    private(set) var messagesViewController: MessagesViewController?

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        print("AppDelegate: Запуск приложения")
        
        window = UIWindow(frame: UIScreen.main.bounds)
        window?.backgroundColor = .black
        
        // Если клиент уже создан, используем его
        if client == nil {
            print("AppDelegate: Создание TDLib клиента")
            setupTDLibClient()
        }
        
        print("AppDelegate: Инициализация сервисов")
        if authService == nil {
            if let client = client {
                authService = AuthService(client: client)
            } else {
                print("AppDelegate: Ошибка - клиент не инициализирован")
                return false
            }
        }
        
        if chatListViewModel == nil {
            if let client = client {
                chatListViewModel = ChatListViewModel(client: client)
            } else {
                print("AppDelegate: Ошибка - клиент не инициализирован")
                return false
            }
        }
        
        print("AppDelegate: Создание контроллеров")
        if let authService = authService, let chatListViewModel = chatListViewModel {
            let authVC = AuthQRController(authService: authService)
            let chatListVC = ChatListViewController(viewModel: chatListViewModel)
            let navigationController = UINavigationController()
            navigationController.isNavigationBarHidden = true
            
            // Устанавливаем начальный экран в зависимости от состояния авторизации
            Task { @MainActor in
                let isAuthorized = authService.isAuthorized
                if isAuthorized {
                    navigationController.setViewControllers([chatListVC], animated: false)
                } else {
                    navigationController.setViewControllers([authVC], animated: false)
                }
            }
            
            authService.$isAuthorized
                .receive(on: DispatchQueue.main)
                .sink { [navigationController, chatListVC, authVC] isAuthorized in
                    if isAuthorized {
                        // При успешной авторизации сразу переходим к списку чатов
                        navigationController.setViewControllers([chatListVC], animated: true)
                    } else {
                        navigationController.setViewControllers([authVC], animated: true)
                    }
                }
                .store(in: &cancellables)
            
            window?.rootViewController = navigationController
            window?.makeKeyAndVisible()
            
            // Запускаем проверку состояния авторизации только при начальной загрузке
            Task {
                if !authService.isAuthorized {
                    await authService.checkAuthState()
                }
            }
        } else {
            print("AppDelegate: Ошибка - сервисы не инициализированы")
            return false
        }
        
        return true
    }

    private func setupTDLibClient() {
        clientManager = TDLibClientManager()
        client = clientManager?.createClient(updateHandler: { [weak self] (data: Data, client: TDLibClient) in
            let jsonString = String(data: data, encoding: .utf8) ?? ""
            
            // Для отладки выводим только важные обновления
            if !jsonString.contains("@type\":\"updateOption") {
                print("AppDelegate: Сырые данные: \(jsonString)")
            }
            
            // Пробуем сначала использовать ручной парсинг для известных типов обновлений
            if let update = Update.fromRawJSON(data) {
                print("AppDelegate: Получено обновление через ручной парсинг: \(update)")
                
                Task { @MainActor in
                    guard let self = self else { return }
                    self.authService?.handleUpdate(update)
                    self.chatListViewModel?.handleUpdate(update)
                    self.messagesViewController?.handleUpdate(update)
                }
                return
            }
            
            // Если ручной парсинг не сработал, пробуем автоматический декодер
            do {
                let decoder = JSONDecoder()
                let update = try decoder.decode(Update.self, from: data)
                
                // Для отладки выводим только важные обновления
                if !String(describing: update).contains("updateOption") {
                    print("AppDelegate: Получено обновление: \(update)")
                }
                
                Task { @MainActor in
                    guard let self = self else { return }
                    self.authService?.handleUpdate(update)
                    self.chatListViewModel?.handleUpdate(update)
                    self.messagesViewController?.handleUpdate(update)
                }
            } catch {
                // Проверяем тип ошибки и контент JSON для принятия решения
                let errorDescription = "\(error)"
                
                // Пропускаем известные безопасные ошибки
                let safeToPropagateError = (
                    jsonString.contains("\"@type\":\"updateFile\"") ||
                    jsonString.contains("\"@type\":\"updateConnectionState\"") ||
                    // Игнорируем ошибки keyNotFound для chatId
                    errorDescription.contains("keyNotFound(CodingKeys(stringValue: \"chatId\"")
                )
                
                if safeToPropagateError {
                    print("AppDelegate: Игнорируем безопасную ошибку декодирования: \(error)")
                } else {
                    print("AppDelegate: Ошибка декодирования обновления: \(error)")
                    
                    // Для других ошибок проверяем авторизацию
                    Task { @MainActor in
                        await self?.authService?.checkAuthState()
                    }
                }
            }
        })
    }

    // Упрощенный метод установки MessagesViewController
    func setMessagesViewController(_ controller: MessagesViewController?) {
        // Просто устанавливаем ссылку и логируем
        if messagesViewController !== controller {
            if controller == nil {
                print("AppDelegate: Установка messagesViewController в nil")
            } else {
                print("AppDelegate: Установка messagesViewController на новый экземпляр для чата \(controller?.chatId ?? 0)")
            }
            messagesViewController = controller
        } else {
             print("AppDelegate: Игнорирование вызова setMessagesViewController с тем же контроллером")
        }
    }
    
    // Проверка, не происходит ли сейчас смена авторизации
    private func isChangingAuthState() -> Bool {
        // Защита от nil
        guard let service = authService else { 
            print("AppDelegate: authService = nil в isChangingAuthState")
            return false 
        }
        return service.isChangingAuthState
    }

    // ... existing code ...
}

