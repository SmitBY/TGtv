import Foundation
import TDLibKit
import Combine

@MainActor
class AuthService {
    private let client: TDLibClient
    @Published var qrCodeUrl: String?
    @Published var isAuthorized = false
    @Published var needPassword = false
    @Published var passwordHint: String = ""
    private var isSettingParameters = false
    @Published var isChangingAuthState = false
    private var chatLoadRetryCount = 0
    private var maxChatLoadRetries = 3
    private var isChatLoadingInProgress = false
    private var lastAuthStateCheck: TimeInterval = 0
    private var minStateCheckInterval: TimeInterval = 1.0  // минимальный интервал между проверками состояния в секундах
    
    init(client: TDLibClient) {
        print("AuthService: Инициализация")
        self.client = client
    }
    
    func handleUpdate(_ update: Update) {
        print("AuthService: Обработка обновления: \(update)")
        
        switch update {
        case .updateAuthorizationState(let state):
            isChangingAuthState = true
            handleAuthStateUpdate(state.authorizationState)
            isChangingAuthState = false
        case .updateOption:
            print("AuthService: Получено обновление опций")
        case .updateChatPosition:
            print("AuthService: Получено обновление позиции чата, игнорируется в AuthService")
        default:
            print("AuthService: Необработанное обновление: \(update)")
        }
    }
    
    private func handleAuthStateUpdate(_ state: AuthorizationState) {
        print("AuthService: Получено состояние авторизации: \(state)")
        
        switch state {
        case .authorizationStateWaitTdlibParameters:
            if !isSettingParameters && !isAuthorized {
                print("AuthService: Установка параметров TDLib")
                isSettingParameters = true
                Task {
                    await setupTDLib()
                }
            }
        case .authorizationStateWaitPhoneNumber:
            print("AuthService: Запрос QR кода")
            if !isAuthorized {
                Task {
                    await startQRAuth()
                }
            }
        case .authorizationStateWaitOtherDeviceConfirmation(let data):
            print("AuthService: Получен QR код")
            qrCodeUrl = data.link
            needPassword = false
        case .authorizationStateWaitPassword(let data):
            print("AuthService: Требуется ввод пароля")
            passwordHint = data.passwordHint
            qrCodeUrl = nil
            needPassword = true
        case .authorizationStateReady:
            print("AuthService: Авторизация успешна")
            needPassword = false
            if !isAuthorized {
                isAuthorized = true
            }
            
            if chatLoadRetryCount < maxChatLoadRetries && !isChatLoadingInProgress {
                Task {
                    do {
                        isChatLoadingInProgress = true
                        print("AuthService: Загрузка чатов (попытка \(chatLoadRetryCount + 1)/\(maxChatLoadRetries))")
                        try await client.loadChats(chatList: .chatListMain, limit: 20)
                        chatLoadRetryCount = 0
                    } catch {
                        print("AuthService: Ошибка загрузки чатов: \(error)")
                        chatLoadRetryCount += 1
                        
                        if chatLoadRetryCount >= maxChatLoadRetries {
                            print("AuthService: Достигнуто максимальное количество попыток загрузки чатов")
                        }
                    }
                    isChatLoadingInProgress = false
                }
            }
        case .authorizationStateLoggingOut:
            print("AuthService: Выполняется выход")
            if isAuthorized {
                isAuthorized = false
            }
        case .authorizationStateClosing:
            print("AuthService: Закрытие соединения")
            if isAuthorized {
                isAuthorized = false
            }
        case .authorizationStateClosed:
            print("AuthService: Соединение закрыто")
            if isAuthorized {
                isAuthorized = false
            }
            Task {
                await checkAuthState()
            }
        default:
            print("AuthService: Неизвестное состояние: \(state)")
        }
    }
    
    private func setupTDLib() async {
        print("AuthService: Настройка TDLib")
        
        do {
            _ = try? await client.setLogVerbosityLevel(newVerbosityLevel: 1)
            let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].path
            let databasePath = (documentsPath as NSString).appendingPathComponent("tdlib")
            let filesPath = (documentsPath as NSString).appendingPathComponent("tdlib_files")
            
            if !FileManager.default.fileExists(atPath: databasePath) {
                try FileManager.default.createDirectory(atPath: databasePath, withIntermediateDirectories: true)
            }
            
            if !FileManager.default.fileExists(atPath: filesPath) {
                try FileManager.default.createDirectory(atPath: filesPath, withIntermediateDirectories: true)
            }
            
            print("AuthService: Отправка параметров TDLib")
            try await client.setTdlibParameters(
                apiHash: "a3406de8d171bb422bb6ddf3bbd800e2",
                apiId: 94575,
                applicationVersion: "1.0",
                databaseDirectory: databasePath,
                databaseEncryptionKey: Data(),
                deviceModel: "Apple tvOS",
                filesDirectory: filesPath,
                systemLanguageCode: "ru",
                systemVersion: "1.0",
                useChatInfoDatabase: true,
                useFileDatabase: true,
                useMessageDatabase: true,
                useSecretChats: true,
                useTestDc: false
            )
            print("AuthService: Параметры TDLib установлены")
        } catch {
            print("AuthService: Ошибка установки параметров: \(error)")
        }
        
        isSettingParameters = false
    }
    
    private func startQRAuth() async {
        print("AuthService: Запуск QR авторизации")
        do {
            try await client.requestQrCodeAuthentication(otherUserIds: [])
            print("AuthService: Запрос QR кода отправлен успешно")
        } catch {
            print("AuthService: Ошибка запроса QR кода: \(error)")
        }
    }
    
    func checkPassword(_ password: String) async -> Bool {
        print("AuthService: Проверка пароля")
        do {
            try await client.checkAuthenticationPassword(password: password)
            return true
        } catch {
            print("AuthService: Ошибка проверки пароля: \(error)")
            return false
        }
    }
    
    func checkAuthState() async {
        let currentTime = Date().timeIntervalSince1970
        // Проверяем, что прошло достаточно времени с последней проверки
        guard currentTime - lastAuthStateCheck >= minStateCheckInterval else {
            print("AuthService: Слишком частая проверка состояния авторизации, пропускаем")
            return
        }
        
        print("AuthService: Проверка состояния авторизации")
        lastAuthStateCheck = currentTime
        isChangingAuthState = true
        do {
            let state = try await client.getAuthorizationState()
            print("AuthService: Текущее состояние: \(state)")
            handleAuthStateUpdate(state)
        } catch {
            print("AuthService: Ошибка получения состояния: \(error)")
        }
        isChangingAuthState = false
    }
    
    private func loadChats() {
        print("AuthService: Загрузка чатов...")
        
        Task {
            do {
                try await client.loadChats(
                    chatList: .chatListMain,
                    limit: 20
                )
                print("AuthService: Чаты успешно загружены")
            } catch let error as TDLibKit.Error {
                if error.code == 404 {
                    print("AuthService: Чат-лист пуст, это нормально при первом запуске")
                    return
                }
                print("AuthService: Ошибка загрузки чатов: \(error)")
            } catch {
                print("AuthService: Неизвестная ошибка загрузки чатов: \(error)")
            }
        }
    }
} 