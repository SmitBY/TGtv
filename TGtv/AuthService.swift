import Foundation
import TDLibKit
import Combine

enum PasswordError: Swift.Error {
    case error(String)
}

@MainActor
class AuthService {
    private let client: TDLibClient
    @Published var qrCodeUrl: String?
    @Published var isAuthorized = false
    @Published var needPassword = false
    @Published var passwordHint: String = ""
    private var isSettingParameters = false
    private var isRequestingQR = false
    @Published var isChangingAuthState = false
    @Published var authError: String?
    private var chatLoadRetryCount = 0
    private var maxChatLoadRetries = 3
    private var isChatLoadingInProgress = false
    private var lastAuthStateCheck: TimeInterval = 0
    private var minStateCheckInterval: TimeInterval = 1.0  // минимальный интервал между проверками состояния в секундах
    
    init(client: TDLibClient) {
        self.client = client
    }
    
    func handleUpdate(_ update: Update) {
        switch update {
        case .updateAuthorizationState(let state):
            isChangingAuthState = true
            handleAuthStateUpdate(state.authorizationState)
            isChangingAuthState = false
        default:
            break
        }
    }
    
    private func handleAuthStateUpdate(_ state: AuthorizationState) {
        // Логируем ключевые состояния — это помогает понять, почему TDLib закрывается/не доходит до QR.
        DebugLogger.shared.log("AuthService: authorizationState = \(state)")

        switch state {
        case .authorizationStateWaitTdlibParameters:
            if !isAuthorized {
                Task { await setupTDLib() }
            }
        case .authorizationStateWaitPhoneNumber:
            if !isAuthorized {
                Task { await startQRAuth() }
            }
        case .authorizationStateWaitOtherDeviceConfirmation(let data):
            qrCodeUrl = data.link
            needPassword = false
            isRequestingQR = false
        case .authorizationStateWaitPassword(let data):
            passwordHint = data.passwordHint
            qrCodeUrl = nil
            needPassword = true
            isRequestingQR = false
        case .authorizationStateReady:
            needPassword = false
            isRequestingQR = false
            if !isAuthorized {
                isAuthorized = true
            }
            
            if chatLoadRetryCount < maxChatLoadRetries && !isChatLoadingInProgress {
                Task {
                    do {
                        isChatLoadingInProgress = true
                        try await client.loadChats(chatList: .chatListMain, limit: 20)
                        chatLoadRetryCount = 0
                    } catch {
                        chatLoadRetryCount += 1
                        
                        if chatLoadRetryCount >= maxChatLoadRetries {
                            // достигли лимита попыток
                        }
                    }
                    isChatLoadingInProgress = false
                }
            }
        case .authorizationStateLoggingOut:
            if isAuthorized {
                isAuthorized = false
            }
            isRequestingQR = false
        case .authorizationStateClosing:
            if isAuthorized {
                isAuthorized = false
            }
            isRequestingQR = false
        case .authorizationStateClosed:
            if isAuthorized {
                isAuthorized = false
            }
            isRequestingQR = false
        default:
            break
        }
    }
    
    private func setupTDLib() async {
        guard !isSettingParameters else { return }
        isSettingParameters = true
        defer { isSettingParameters = false }

        do {
            _ = try? await client.setLogVerbosityLevel(newVerbosityLevel: 1)
            
            // Работа с файловой системой в фоновом потоке
            let (databasePath, filesPath) = try await Task.detached(priority: .utility) {
                let fileManager = FileManager.default
                // На tvOS CachesDirectory — самое надежное место для записи без ошибок доступа
                let cachesURL = fileManager.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                
                let dbPath = cachesURL.appendingPathComponent("tdlib", isDirectory: true).path
                let fPath = cachesURL.appendingPathComponent("tdlib_files", isDirectory: true).path
                
                // Создаем директории
                try fileManager.createDirectory(atPath: dbPath, withIntermediateDirectories: true, attributes: nil)
                try fileManager.createDirectory(atPath: fPath, withIntermediateDirectories: true, attributes: nil)
                
                return (dbPath, fPath)
            }.value
            
            try await client.setTdlibParameters(
                apiHash: Config.apiHash,
                apiId: Config.apiId,
                applicationVersion: "1.0.1",
                databaseDirectory: databasePath,
                // TDLib ожидает либо пустой ключ (без шифрования), либо 32 байта.
                // Используем 32 байта нулей для предсказуемого поведения между запусками.
                databaseEncryptionKey: Data(repeating: 0, count: 32),
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
        } catch {
            DebugLogger.shared.log("AuthService: Ошибка setupTDLib: \(error)")
        }
    }
    
    private func startQRAuth() async {
        guard !isRequestingQR else { return }
        isRequestingQR = true
        defer { isRequestingQR = false }

        do {
            authError = nil
            try await client.requestQrCodeAuthentication(otherUserIds: [])
        } catch {
            let errorDesc = "\(error)"
            DebugLogger.shared.log("AuthService: Ошибка requestQrCodeAuthentication: \(errorDesc)")
            if errorDesc.contains("API_ID_PUBLISHED_FLOOD") {
                authError = "Критическая ошибка: Используется заблокированный api_id. Пожалуйста, замените apiId и apiHash в коде."
            } else {
                authError = "Ошибка запроса QR: \(errorDesc)"
            }
        }
    }
    
    func checkPassword(_ password: String) async -> Result<Void, PasswordError> {
        do {
            try await client.checkAuthenticationPassword(password: password)
            return .success(())
        } catch {
            let errorDesc = "\(error)"
            DebugLogger.shared.log("AuthService: Ошибка checkPassword: \(errorDesc)")
            if errorDesc.contains("PASSWORD_HASH_INVALID") {
                return .failure(.error("Неверный пароль"))
            } else if errorDesc.contains("FLOOD_WAIT") {
                return .failure(.error("Слишком много попыток. Пожалуйста, подождите."))
            }
            return .failure(.error("Ошибка: \(errorDesc)"))
        }
    }
    
    func checkAuthState() async {
        let currentTime = Date().timeIntervalSince1970
        // Проверяем, что прошло достаточно времени с последней проверки
        guard currentTime - lastAuthStateCheck >= minStateCheckInterval else {
            return
        }
        
        lastAuthStateCheck = currentTime
        isChangingAuthState = true
        do {
            let state = try await client.getAuthorizationState()
            handleAuthStateUpdate(state)
        } catch {
            DebugLogger.shared.log("AuthService: Ошибка getAuthorizationState: \(error)")
        }
        isChangingAuthState = false
    }

    /// Принудительно запускает auth-flow и пытается довести до получения QR/пароля без троттлинга.
    /// Нужен после logout/restart клиента, когда UI уже на экране авторизации, но TDLib ещё не прислал link.
    func startAuthFlow(force: Bool = true) async {
        if isChangingAuthState && !force { return }
        isChangingAuthState = true
        defer { isChangingAuthState = false }

        // Сбрасываем UI-состояния — иначе можно застрять на старом состоянии.
        qrCodeUrl = nil
        needPassword = false
        passwordHint = ""

        // Несколько попыток: TDLib может сначала вернуть WaitTdlibParameters, затем WaitPhoneNumber и т.д.
        for attempt in 1...6 {
            do {
                let state = try await client.getAuthorizationState()
                handleAuthStateUpdate(state)

                switch state {
                case .authorizationStateWaitTdlibParameters:
                    // setupTDLib запускается из handleAuthStateUpdate и защищён флагом isSettingParameters
                    break
                case .authorizationStateWaitPhoneNumber:
                    // requestQrCodeAuthentication запускается из handleAuthStateUpdate и защищён флагом isRequestingQR
                    return
                case .authorizationStateWaitOtherDeviceConfirmation:
                    // link будет установлен в handleAuthStateUpdate
                    return
                case .authorizationStateWaitPassword:
                    return
                case .authorizationStateReady:
                    return
                case .authorizationStateClosing, .authorizationStateClosed, .authorizationStateLoggingOut:
                    break
                default:
                    break
                }
            } catch {
                DebugLogger.shared.log("AuthService: Ошибка startAuthFlow (attempt \(attempt)): \(error)")
            }

            try? await Task.sleep(nanoseconds: 300_000_000) // 0.3s
        }
    }
    
    func logout() async {
        guard !isChangingAuthState else {
            return
        }
        
        isChangingAuthState = true
        do {
            try await client.logOut()
            isAuthorized = false
        } catch {
            DebugLogger.shared.log("AuthService: Ошибка logOut: \(error)")
        }
        isChangingAuthState = false
    }
    
    private func loadChats() {
        Task {
            do {
                try await client.loadChats(
                    chatList: .chatListMain,
                    limit: 20
                )
            } catch let error as TDLibKit.Error {
                if error.code == 404 { return }
            } catch { }
        }
    }
} 
