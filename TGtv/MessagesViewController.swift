import UIKit
import TDLibKit
import Combine
import AVFoundation
import AVKit

final class MessagesViewController: UIViewController, AVPlayerViewControllerDelegate {
    private let client: TDLibClient
    private var messages: [TG.Message] = []
    private var cancellables = Set<AnyCancellable>()
    private(set) var isLoading = false
    private var selectedVideoIndexPath: IndexPath?
    private weak var currentlyPlayingVideoCell: MessageCell?
    
    let chatId: Int64
    
    private let tableView: UITableView = {
        let tv = UITableView()
        tv.backgroundColor = .black
        tv.translatesAutoresizingMaskIntoConstraints = false
        return tv
    }()
    
    private let loadingIndicator = UIActivityIndicatorView(style: .large)
    private let messageLabel = UILabel()
    
    private let messageBubble = UIView()
    private let dateLabel = UILabel()
    private let videoContainer = UIView()
    private var player: AVPlayer?
    private var playerItem: AVPlayerItem?
    var videoURL: URL?
    private var playerVC: AVPlayerViewController?
    private var isPlayingVideo = false
    private var videoPreviewImageView: UIImageView?
    private var playIcon: UIImageView?
    private var playerLayer: AVPlayerLayer?
    private var isObservingBounds = false
    private var playButton: UIButton?
    
    private var isVideoActive = false
    
    weak var viewController: MessagesViewController?
    var indexPath: IndexPath?
    
    init(chatId: Int64, client: TDLibClient) {
        self.chatId = chatId
        self.client = client
        super.init(nibName: nil, bundle: nil)
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        print("MessagesViewController: viewDidLoad для чата \(chatId)")
        setupUI()
        
        // Настраиваем аудио сессию глобально
        setupGlobalAudioSession()
        
        // Регистрируем контроллер в AppDelegate для получения обновлений
        if let appDelegate = UIApplication.shared.delegate as? AppDelegate {
            // Устанавливаем контроллер в AppDelegate
            appDelegate.setMessagesViewController(self)
            print("MessagesViewController: Зарегистрирован в AppDelegate из viewDidLoad")
        }
        
        // Запускаем загрузку сообщений
        loadMessages()
        
        // Устанавливаем фокус на таблицу
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            self.tableView.becomeFirstResponder()
        }
        
        // Важно: добавляем подписку на уведомление о переходе в неактивное состояние
        NotificationCenter.default.addObserver(self, 
                                               selector: #selector(applicationWillResignActive), 
                                               name: UIApplication.willResignActiveNotification, 
                                               object: nil)
    }
    
    @objc private func applicationWillResignActive() {
        // Сохраняем наше присутствие в AppDelegate
        if let appDelegate = UIApplication.shared.delegate as? AppDelegate {
            appDelegate.setMessagesViewController(self)
        }
        
        // Останавливаем все видео
        cleanupAllMediaResources()
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
        cleanupAllMediaResources()
        print("MessagesViewController: deinit - освобождаем ресурсы для чата \(chatId)")
    }
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        print("MessagesViewController: viewWillAppear для чата \(chatId)")
        
        if let appDelegate = UIApplication.shared.delegate as? AppDelegate {
            if appDelegate.messagesViewController !== self {
                print("MessagesViewController: Установлен как текущий VC в AppDelegate из viewWillAppear")
                appDelegate.setMessagesViewController(self)
            }
        }
    }
    
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        print("MessagesViewController: viewDidAppear для чата \(chatId)")
    }
    
    override var preferredFocusEnvironments: [UIFocusEnvironment] {
        if !messages.isEmpty {
            if let lastCell = tableView.cellForRow(at: IndexPath(row: messages.count - 1, section: 0)) {
                return [lastCell]
            }
        }
        return [tableView]
    }
    
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        print("MessagesViewController: viewDidDisappear для чата \(chatId)")
        
        // Добавляем подробное логирование состояний
        let movingFromParent = isMovingFromParent
        let beingDismissed = isBeingDismissed
        // Проверяем, является ли этот контроллер все еще верхним в стеке навигации
        // Это может дать подсказку, был ли он убран стандартным pop/dismiss или чем-то более глобальным
        let isStillTopViewController = navigationController?.topViewController === self
        let isStillVisibleViewController = navigationController?.viewControllers.contains(self) ?? false && view.window != nil

        print("MessagesViewController disappearing states: isMovingFromParent=\(movingFromParent), isBeingDismissed=\(beingDismissed), isStillTopViewController=\(isStillTopViewController), isStillVisibleViewController=\(isStillVisibleViewController)")

        // Если контроллер удаляется из стека навигации или закрывается модально,
        // обнуляем ссылку в AppDelegate
        if movingFromParent || beingDismissed {
            print("MessagesViewController: Контроллер удаляется (isMovingFromParent: \(movingFromParent), isBeingDismissed: \(beingDismissed))")
            if let appDelegate = UIApplication.shared.delegate as? AppDelegate {
                if appDelegate.messagesViewController === self {
                    print("MessagesViewController: Обнуляем ссылку на себя в AppDelegate из viewDidDisappear")
                    appDelegate.setMessagesViewController(nil)
                }
            }
        } else {
            print("MessagesViewController: Контроллер не удаляется (или не из-за навигации/dismiss), ссылка в AppDelegate сохраняется")
        }
    }
    
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        print("MessagesViewController: viewWillDisappear для чата \(chatId)")
        
        // Удаляем вызов appDelegate.willNavigateFromMessagesViewController()
        // if isMovingFromParent || (navigationController != nil && navigationController?.viewControllers.contains(self) == false) {
        //     if let appDelegate = UIApplication.shared.delegate as? AppDelegate {
        //         appDelegate.willNavigateFromMessagesViewController()
        //         print("MessagesViewController: Установлен флаг навигации в viewWillDisappear")
        //     }
        // }
    }
    
    private func setupUI() {
        view.backgroundColor = .black
        
        // Добавляем кнопку назад
        let backButton = UIButton(type: .system)
        backButton.translatesAutoresizingMaskIntoConstraints = false
        backButton.setTitle("Назад", for: .normal)
        backButton.titleLabel?.font = .systemFont(ofSize: 22, weight: .bold)
        backButton.setTitleColor(.white, for: .normal)
        backButton.addTarget(self, action: #selector(backButtonTapped), for: .primaryActionTriggered)
        view.addSubview(backButton)
        
        view.addSubview(tableView)
        
        // Настраиваем индикатор загрузки
        loadingIndicator.translatesAutoresizingMaskIntoConstraints = false
        loadingIndicator.hidesWhenStopped = true
        loadingIndicator.color = .white
        loadingIndicator.startAnimating()
        view.addSubview(loadingIndicator)
        
        // Настраиваем текстовое сообщение
        messageLabel.translatesAutoresizingMaskIntoConstraints = false
        messageLabel.textColor = .white
        messageLabel.textAlignment = .center
        messageLabel.numberOfLines = 0
        messageLabel.font = .systemFont(ofSize: 22)
        messageLabel.text = "Загрузка сообщений..."
        view.addSubview(messageLabel)
        
        NSLayoutConstraint.activate([
            backButton.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -50),
            backButton.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -40),
            backButton.widthAnchor.constraint(equalToConstant: 120),
            backButton.heightAnchor.constraint(equalToConstant: 50),
            
            tableView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 20),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: backButton.topAnchor, constant: -20),
            
            loadingIndicator.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            loadingIndicator.centerYAnchor.constraint(equalTo: view.centerYAnchor, constant: -50),
            
            messageLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            messageLabel.topAnchor.constraint(equalTo: loadingIndicator.bottomAnchor, constant: 20),
            messageLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 40),
            messageLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -40)
        ])
        
        tableView.register(MessageCell.self, forCellReuseIdentifier: "MessageCell")
        tableView.delegate = self
        tableView.dataSource = self
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 100
        tableView.contentInset = UIEdgeInsets(top: 20, left: 0, bottom: 20, right: 0)
    }
    
    @objc private func backButtonTapped() {
        print("MessagesViewController: Кнопка назад нажата")
        
        // Удаляем вызов appDelegate.willNavigateFromMessagesViewController()
        // if let appDelegate = UIApplication.shared.delegate as? AppDelegate {
        //     appDelegate.willNavigateFromMessagesViewController()
        // }
        
        // Выполняем возврат с задержкой
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            self.navigationController?.popViewController(animated: true)
        }
    }
    
    @MainActor
    func handleUpdate(_ update: TDLibKit.Update) {
        if case .updateNewMessage(let update) = update, update.message.chatId == chatId {
            handleNewMessage(update.message)
        } else if case .updateFile(let update) = update {
            // Обрабатываем обновление файлов, но не выходим из чата при ошибках
            print("MessagesViewController: Обновление файла \(update.file.id)")
            
            // Обновляем UI для видео, если это текущий файл
            if tableView.indexPathsForVisibleRows != nil {
                DispatchQueue.main.async {
                    self.tableView.reloadData()
                }
            }
        } else if case .updateDeleteMessages(let deleteInfo) = update, deleteInfo.chatId == self.chatId {
            print("MessagesViewController: Получено обновление на удаление сообщений: \(deleteInfo.messageIds) в чате \(deleteInfo.chatId)")
            handleDeletedMessages(deleteInfo.messageIds)
        }
    }
    
    private func handleNewMessage(_ message: TDLibKit.Message) {
        print("MessagesViewController: Получено новое сообщение: \(message.id)")
        let newMessage = TG.Message(
            id: message.id,
            text: getMessageText(from: message),
            isOutgoing: message.isOutgoing,
            media: getMedia(from: message),
            date: Date(timeIntervalSince1970: TimeInterval(message.date))
        )
        
        // Добавляем новое сообщение и обновляем таблицу через batch updates
        let newIndex = messages.count
        messages.append(newMessage)
        let indexPath = IndexPath(row: newIndex, section: 0)
        
        tableView.performBatchUpdates({
            tableView.insertRows(at: [indexPath], with: .automatic)
        }) { [weak self] completed in
            if completed {
                // Прокручиваем к новому сообщению и выделяем его после обновления
                self?.tableView.scrollToRow(at: indexPath, at: .bottom, animated: true)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { // Даем время на анимацию
                    self?.tableView.selectRow(at: indexPath, animated: true, scrollPosition: .none)
                    // Опционально: можно добавить обновление фокуса, если selectRow недостаточно
                    // self?.setNeedsFocusUpdate()
                    // self?.updateFocusIfNeeded()
                }
            }
        }
    }
    
    private func handleDeletedMessages(_ deletedMessageIds: [Int64]) {
        let _ = messages.count
        var indexPathsToDelete: [IndexPath] = []
        var indicesToDelete: IndexSet = []
        
        // Находим индексы сообщений, которые нужно удалить
        for (index, message) in messages.enumerated() {
            if deletedMessageIds.contains(message.id) {
                indexPathsToDelete.append(IndexPath(row: index, section: 0))
                indicesToDelete.insert(index)
            }
        }
        
        guard !indicesToDelete.isEmpty else {
            print("MessagesViewController: Сообщений для удаления не найдено в текущем списке.")
            return
        }
        
        print("MessagesViewController: Индексы для удаления: \(indicesToDelete)")
        print("MessagesViewController: IndexPaths для удаления: \(indexPathsToDelete)")

        // Сначала удаляем строки из таблицы
        tableView.performBatchUpdates({
            // Удаляем сообщения из источника данных *после* получения индексов
            messages.remove(atOffsets: indicesToDelete)
            tableView.deleteRows(at: indexPathsToDelete, with: .automatic)
        }) { completed in
            if completed {
                 print("MessagesViewController: Удалено \(indexPathsToDelete.count) сообщений. Новое количество: \(self.messages.count)")
                 if self.messages.isEmpty {
                     self.messageLabel.text = "Сообщений нет"
                     self.messageLabel.isHidden = false
                     self.loadingIndicator.stopAnimating()
                 } else {
                     // Если удалили текущую сфокусированную ячейку, возможно, потребуется перенести фокус
                     // Пока просто обновляем
                 }
            }
        }
    }
    
    private func loadMessages() {
        guard !isLoading else { return }
        
        isLoading = true
        loadingIndicator.startAnimating()
        messageLabel.isHidden = false
        messageLabel.text = "Загрузка сообщений..."
        
        // Сохраняем (закрепляем) self в AppDelegate, чтобы предотвратить снятие ссылки
        if let appDelegate = UIApplication.shared.delegate as? AppDelegate {
            appDelegate.setMessagesViewController(self)
            print("MessagesViewController: Установлен как текущий VC в AppDelegate перед началом загрузки. ChatID: \(chatId)")
        }
        
        _ = Task {
            do {
                print("MessagesViewController: Загрузка истории чата \(chatId)")
                
                // Сохраняем self в AppDelegate еще раз перед асинхронным запросом
                // и логируем текущее состояние
                await MainActor.run {
                    if let appDelegate = UIApplication.shared.delegate as? AppDelegate {
                        appDelegate.setMessagesViewController(self)
                        print("MessagesViewController: Установлен как текущий VC в AppDelegate перед getChatHistory. Текущий VC в AppDelegate: \(appDelegate.messagesViewController === self ? "self" : "другой или nil")")
                    }
                }
                
                // Проверяем, что задача не была отменена перед запросом
                if Task.isCancelled {
                    print("MessagesViewController: Задача загрузки сообщений отменена перед запросом")
                    await MainActor.run { isLoading = false }
                    return
                }
                
                print("MessagesViewController: Начинаем вызов client.getChatHistory для чата \(chatId).")
                let history = try await client.getChatHistory(
                    chatId: chatId,
                    fromMessageId: 0,
                    limit: 50,
                    offset: 0,
                    onlyLocal: false
                )
                
                // Проверяем, что задача не была отменена после запроса
                if Task.isCancelled {
                    print("MessagesViewController: Задача загрузки сообщений отменена после запроса")
                    await MainActor.run { isLoading = false }
                    return
                }
                
                print("MessagesViewController: Получено \(history.messages?.count ?? 0) сообщений")
                
                // Убеждаемся, что self все еще является активным контроллером в AppDelegate
                await MainActor.run {
                    // Проверяем, что контроллер все еще в окне (не был закрыт/выгружен)
                    guard self.view.window != nil else {
                        print("MessagesViewController: Вид не находится в окне. Возможно, контроллер был закрыт. Прерываем обновление UI.")
                        self.isLoading = false // Важно сбросить флаг
                        return
                    }
                    
                    guard let appDelegate = UIApplication.shared.delegate as? AppDelegate,
                          appDelegate.messagesViewController === self else {
                        print("MessagesViewController: Загрузка сообщений завершена (успешно), но контроллер уже не активен в AppDelegate или был заменен. ChatID: \(self.chatId). Прерываем обновление UI.")
                        self.isLoading = false // Важно сбросить флаг
                        return
                    }
                    
                    // Дополнительная проверка, что мы все еще в стеке навигации
                    guard let navController = self.navigationController,
                          navController.topViewController === self else {
                        print("MessagesViewController: Контроллер больше не является верхним в стеке навигации. Прерываем обновление UI.")
                        self.isLoading = false // Важно сбросить флаг
                        return
                    }
                    
                    // appDelegate.setMessagesViewController(self) // Уже установлено выше и проверено guard-ом

                    if let historyMessages = history.messages {
                        if !historyMessages.isEmpty {
                            // Разворачиваем массив сообщений, чтобы новые были внизу
                            messages = historyMessages.reversed().map { message in
                                TG.Message(
                                    id: message.id,
                                    text: getMessageText(from: message),
                                    isOutgoing: message.isOutgoing,
                                    media: getMedia(from: message),
                                    date: Date(timeIntervalSince1970: TimeInterval(message.date))
                                )
                            }
                            
                            loadingIndicator.stopAnimating()
                            messageLabel.isHidden = true
                            tableView.reloadData()
                            
                            // Даем время таблице обновиться и закрепляем self
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                                if let appDelegate = UIApplication.shared.delegate as? AppDelegate {
                                    appDelegate.setMessagesViewController(self)
                                }
                                
                                if self.messages.count > 0 {
                                    let lastIndex = IndexPath(row: self.messages.count - 1, section: 0)
                                    
                                    // Сначала прокручиваем к последнему сообщению
                                    self.tableView.scrollToRow(at: lastIndex, at: .bottom, animated: false)
                                    
                                    // Затем устанавливаем фокус и выделение
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                                        if let appDelegate = UIApplication.shared.delegate as? AppDelegate {
                                            appDelegate.setMessagesViewController(self)
                                        }
                                        
                                        self.tableView.selectRow(at: lastIndex, animated: false, scrollPosition: .none)
                                        
                                        // Запрашиваем обновление фокуса системы для выбора последнего сообщения
                                        self.setNeedsFocusUpdate()
                                        self.updateFocusIfNeeded()
                                        
                                        // Проверяем, что ячейка выбрана
                                        if let cell = self.tableView.cellForRow(at: lastIndex) as? MessageCell {
                                            print("MessagesViewController: Устанавливаем фокус на последнее сообщение \(lastIndex.row)")
                                            cell.setSelected(true, animated: true)
                                        } else {
                                            print("MessagesViewController: Не удалось получить ячейку для последнего сообщения")
                                        }
                                    }
                                } else {
                                    print("MessagesViewController: Нет сообщений для выбора")
                                }
                            }
                        } else {
                            loadingIndicator.stopAnimating()
                            messageLabel.text = "Нет сообщений в этом чате"
                        }
                    }
                }
            } catch {
                let errorDescription = String(describing: error)
                let errorType = type(of: error)
                print("MessagesViewController: Ошибка загрузки сообщений для чата \(chatId): \(errorDescription). Тип ошибки: \(errorType)")

                let nsError = error as NSError
                print("MessagesViewController: NSError: domain=\(nsError.domain), code=\(nsError.code), userInfo=\(nsError.userInfo)")
                
                // Закрепляем self в AppDelegate даже при ошибке, но сначала проверяем, актуален ли контроллер
                await MainActor.run {
                    guard let appDelegate = UIApplication.shared.delegate as? AppDelegate,
                          appDelegate.messagesViewController === self else {
                        print("MessagesViewController: Ошибка загрузки сообщений, но контроллер уже не активен в AppDelegate или был заменен. ChatID: \(self.chatId). Прерываем обновление UI ошибки.")
                        self.isLoading = false // Важно сбросить флаг
                        return
                    }
                    // appDelegate.setMessagesViewController(self) // Уже установлено и проверено

                    loadingIndicator.stopAnimating()
                    messageLabel.text = "Ошибка при загрузке сообщений: \(error.localizedDescription)"
                    
                    // Добавляем кнопку для повторной загрузки
                    let retryButton = UIButton(type: .system)
                    retryButton.translatesAutoresizingMaskIntoConstraints = false
                    retryButton.setTitle("Повторить загрузку", for: .normal)
                    retryButton.titleLabel?.font = .systemFont(ofSize: 22)
                    retryButton.setTitleColor(.white, for: .normal)
                    retryButton.backgroundColor = UIColor(red: 0, green: 0.5, blue: 1.0, alpha: 1.0)
                    retryButton.layer.cornerRadius = 8
                    retryButton.addTarget(self, action: #selector(retryLoadMessages), for: .primaryActionTriggered)
                    view.addSubview(retryButton)
                    
                    NSLayoutConstraint.activate([
                        retryButton.topAnchor.constraint(equalTo: messageLabel.bottomAnchor, constant: 20),
                        retryButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
                        retryButton.widthAnchor.constraint(equalToConstant: 250),
                        retryButton.heightAnchor.constraint(equalToConstant: 50)
                    ])
                }
            }
            
            isLoading = false
        }
    }
    
    @objc private func retryLoadMessages() {
        // Находим и удаляем кнопку повтора
        for subview in view.subviews {
            if let button = subview as? UIButton, button.title(for: .normal) == "Повторить загрузку" {
                button.removeFromSuperview()
                break
            }
        }
        
        // Запускаем загрузку заново
        loadMessages()
    }
    
    private func scrollToBottom() {
        guard !messages.isEmpty else { return }
        let lastIndex = IndexPath(row: messages.count - 1, section: 0)
        tableView.scrollToRow(at: lastIndex, at: .bottom, animated: true)
    }
    
    private func getMessageText(from message: TDLibKit.Message) -> String {
        switch message.content {
        case .messageText(let messageText):
            return messageText.text.text
        case .messagePhoto(let messagePhoto):
            return messagePhoto.caption.text
        case .messageVideo(let messageVideo):
            return messageVideo.caption.text
        case .messageDocument(let messageDocument):
            return messageDocument.caption.text
        default:
            return "Неподдерживаемый тип сообщения"
        }
    }
    
    private func getMedia(from message: TDLibKit.Message) -> TG.MessageMedia? {
        switch message.content {
        case .messagePhoto(let messagePhoto):
            let sizes = messagePhoto.photo.sizes
            guard let largest = sizes.max(by: { $0.width * $0.height < $1.width * $1.height }) else { return nil }
            let path = largest.photo.local.path
            print("MessagesViewController: Путь к фото: \(path)")
            return .photo(path: path)
        case .messageVideo(let messageVideo):
            let path = messageVideo.video.video.local.path
            print("MessagesViewController: Путь к видео: \(path), доступно: \(messageVideo.video.video.local.isDownloadingCompleted), размер: \(messageVideo.video.video.size)")
            
            // Проверяем, загружено ли видео
            if !messageVideo.video.video.local.isDownloadingCompleted {
                // Запускаем загрузку видео, если оно не загружено
                Task {
                    do {
                        print("MessagesViewController: Загрузка видео...")
                        let _ = try await client.downloadFile(
                            fileId: messageVideo.video.video.id,
                            limit: 0,
                            offset: 0,
                            priority: 1,
                            synchronous: false
                        )
                        print("MessagesViewController: Запрос на загрузку видео отправлен")
                    } catch {
                        print("MessagesViewController: Ошибка при загрузке видео: \(error)")
                    }
                }
            }
            
            return .video(path: path)
        case .messageDocument(let messageDocument):
            let path = messageDocument.document.document.local.path
            print("MessagesViewController: Путь к документу: \(path)")
            return .document(path: path)
        default:
            return nil
        }
    }
    
    // Метод для очистки всех ресурсов медиа
    private func cleanupAllMediaResources() {
        // Находим и останавливаем все воспроизводимые видео
        // Если используется AVPlayerViewController, он должен быть закрыт
        if let presentedVC = presentedViewController as? AVPlayerViewController {
            presentedVC.player?.pause()
            presentedVC.dismiss(animated: false) { // Закрываем синхронно, если нужно немедленно
                UIApplication.shared.isIdleTimerDisabled = false
            }
        }
        // Старая логика для MessageCell, если она где-то осталась (должна быть удалена)
        for _ in tableView.visibleCells {
            // Удаляем этот блок, так как messageCell не используется и логика устарела
            // if let messageCell = cell as? MessageCell {
            //     // messageCell.stopAndCleanupPlayer() // Этот метод удален
            // }
        }
    }
    
    // Метод для глобальной настройки аудио сессии
    func setupGlobalAudioSession() {
        do {
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.playback, mode: .moviePlayback, options: [.mixWithOthers, .allowAirPlay])
            try audioSession.setActive(true)
            print("MessagesViewController: Аудио сессия настроена глобально")
        } catch {
            print("MessagesViewController: Ошибка настройки глобальной аудио сессии: \(error)")
            // Продолжаем выполнение, ошибка может быть некритичной
        }
    }
    
    // Добавить метод для игнорирования MEMixerChannel ошибок
    func ignoreMEMixerChannelErrors() {
        // Это метод-заглушка, который имитирует обработку ошибок MEMixerChannel
        // Предотвращает некоторые ошибки воспроизведения на tvOS
        do {
            try AVAudioSession.sharedInstance().setActive(false)
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            // Игнорируем ошибки
            print("MessagesViewController: Игнорируем ошибки аудио сессии: \(error)")
        }
    }
    
    // Added: Method to handle video tap from cell
    func handleVideoTapInCell(at indexPath: IndexPath, cell: MessageCell) {
        print("MessagesViewController: Handling video tap for cell at \(indexPath.row)")

        // Если уже есть представленный AVPlayerViewController, закрываем его
        if let existingPlayerVC = presentedViewController as? AVPlayerViewController {
            existingPlayerVC.player?.pause()
            existingPlayerVC.dismiss(animated: true) { [weak self] in
                self?.presentNewPlayerViewController(for: cell.videoURL)
            }
            return
        }
        
        presentNewPlayerViewController(for: cell.videoURL)
    }

    private func presentNewPlayerViewController(for videoURL: URL?) {
        guard let videoURL = videoURL else {
            print("MessagesViewController: videoURL is nil")
            showAlert(title: "Ошибка", message: "Не удалось получить URL видео.")
            return
        }

        print("MessagesViewController: Настраиваем аудио сессию")
        setupGlobalAudioSession()

        print("MessagesViewController: Проверяем существование файла: \(videoURL.path)")
        if FileManager.default.fileExists(atPath: videoURL.path) {
            print("MessagesViewController: Файл существует, готовим AVPlayerViewController")
            
            let player = AVPlayer(url: videoURL)
            let playerViewController = AVPlayerViewController()
            playerViewController.player = player
            playerViewController.delegate = self // Устанавливаем делегата
                                               
            present(playerViewController, animated: true) {
                player.play()
                UIApplication.shared.isIdleTimerDisabled = true
                print("MessagesViewController: AVPlayerViewController представлен, видео должно играть")
            }
        } else {
            print("MessagesViewController: Файл не существует: \(videoURL.path)")
            showAlert(title: "Ошибка", message: "Видеофайл не найден.")
        }
    }

    // Этот метод должен быть частью AVPlayerViewControllerDelegate
    // и не требует override, если класс MessagesViewController напрямую реализует протокол.
    func playerViewControllerDidEndFullScreenPresentation(_ playerViewController: AVPlayerViewController) {
        print("MessagesViewController: AVPlayerViewController был закрыт (playerViewControllerDidEndFullScreenPresentation).")
        UIApplication.shared.isIdleTimerDisabled = false
    }

    // Вспомогательный метод для показа UIAlertController
    private func showAlert(title: String, message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }
}

extension MessagesViewController: UITableViewDelegate, UITableViewDataSource {
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return messages.count
    }
    
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        guard let cell = tableView.dequeueReusableCell(withIdentifier: "MessageCell", for: indexPath) as? MessageCell else {
            return UITableViewCell()
        }
        let message = messages[indexPath.row]
        cell.configure(with: message, viewController: self, indexPath: indexPath)
        // Убедимся, что ячейка может быть выбрана
        cell.selectionStyle = .default 
        return cell
    }
    
    func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        return UITableView.automaticDimension
    }
    
    // НОВЫЙ МЕТОД ДЕЛЕГАТА
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        print("MessagesViewController: Ячейка выбрана по индексу \(indexPath.row)")
        guard let cell = tableView.cellForRow(at: indexPath) as? MessageCell else {
            print("MessagesViewController: Не удалось получить MessageCell для индекса \(indexPath.row)")
            return
        }

        // Проверяем, есть ли в ячейке видео
        if cell.videoURL != nil {
            print("MessagesViewController: В ячейке есть видео, вызываем handleVideoTapInCell")
            handleVideoTapInCell(at: indexPath, cell: cell)
        } else {
            print("MessagesViewController: В ячейке нет видео.")
        }
        
        // Снимаем выделение с ячейки, если не хотим, чтобы она оставалась подсвеченной
        // tableView.deselectRow(at: indexPath, animated: true)
    }
}

final class MessageCell: UITableViewCell {
    private let messageBubble = UIView()
    private let messageLabel = UILabel()
    private let dateLabel = UILabel()
    private let videoContainer = UIView()
    var videoURL: URL?
    private var videoPreviewImageView: UIImageView?
    private var playIcon: UIImageView?
    private var playButton: UIButton?
    
    weak var viewController: MessagesViewController?
    var indexPath: IndexPath?
    
    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        setupUI()
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    private func setupUI() {
        backgroundColor = .clear
        selectionStyle = .none
        
        messageBubble.translatesAutoresizingMaskIntoConstraints = false
        messageBubble.backgroundColor = UIColor(white: 0.2, alpha: 1.0)
        messageBubble.layer.cornerRadius = 12
        contentView.addSubview(messageBubble)
        
        messageLabel.textColor = .white
        messageLabel.font = .systemFont(ofSize: 20)
        messageLabel.numberOfLines = 0
        
        dateLabel.textColor = .lightGray
        dateLabel.font = .systemFont(ofSize: 14)
        
        videoContainer.translatesAutoresizingMaskIntoConstraints = false
        videoContainer.backgroundColor = .black
        videoContainer.isHidden = true
        videoContainer.layer.cornerRadius = 8
        videoContainer.clipsToBounds = true
        
        self.playButton = nil

        let playIcon = UIImageView()
        playIcon.translatesAutoresizingMaskIntoConstraints = false
        playIcon.image = UIImage(systemName: "play.circle.fill")
        playIcon.tintColor = .white
        playIcon.contentMode = .scaleAspectFit
        playIcon.alpha = 0.8
        videoContainer.addSubview(playIcon)
        self.playIcon = playIcon
        
        let stack = UIStackView(arrangedSubviews: [messageLabel, videoContainer, dateLabel])
        stack.axis = .vertical
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        
        messageBubble.addSubview(stack)
        
        NSLayoutConstraint.activate([
            messageBubble.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            messageBubble.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor, constant: -16),
            messageBubble.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 8),
            messageBubble.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -8),
            
            stack.leadingAnchor.constraint(equalTo: messageBubble.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: messageBubble.trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: messageBubble.topAnchor, constant: 8),
            stack.bottomAnchor.constraint(equalTo: messageBubble.bottomAnchor, constant: -8),
            
            videoContainer.heightAnchor.constraint(equalTo: videoContainer.widthAnchor, multiplier: 9/20),
            videoContainer.widthAnchor.constraint(lessThanOrEqualToConstant: 300),
            
            playIcon.centerXAnchor.constraint(equalTo: videoContainer.centerXAnchor),
            playIcon.centerYAnchor.constraint(equalTo: videoContainer.centerYAnchor),
            playIcon.widthAnchor.constraint(equalToConstant: 50),
            playIcon.heightAnchor.constraint(equalToConstant: 50)
        ])
    }
    
    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        if isFocused {
            messageBubble.transform = CGAffineTransform(scaleX: 1.05, y: 1.05)
            messageBubble.layer.shadowColor = UIColor.white.cgColor
            messageBubble.layer.shadowOpacity = 0.5
            messageBubble.layer.shadowOffset = .zero
            messageBubble.layer.shadowRadius = 5
        } else {
            messageBubble.transform = .identity
            messageBubble.layer.shadowOpacity = 0
        }
    }
    
    func configure(with message: TG.Message, viewController: MessagesViewController, indexPath: IndexPath) {
        self.viewController = viewController
        self.indexPath = indexPath
        messageLabel.text = message.text
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        dateLabel.text = formatter.string(from: message.date)
        
        if let media = message.media, case .video(let path) = media {
            videoContainer.isHidden = false
            self.videoURL = URL(fileURLWithPath: path)
            
            if FileManager.default.fileExists(atPath: path) {
                do {
                    let attrs = try FileManager.default.attributesOfItem(atPath: path)
                    if let fileSize = attrs[.size] as? UInt64, fileSize > 0 {
                        generateThumbnailAsync(from: AVURLAsset(url: self.videoURL!))
                        playIcon?.isHidden = false
                    } else {
                        showLoadingIndicator(withText: "Видео повреждено")
                        playIcon?.isHidden = true
                    }
                } catch {
                    showLoadingIndicator(withText: "Ошибка доступа к видео")
                    playIcon?.isHidden = true
                }
            } else {
                showLoadingIndicator(withText: "Видео загружается...")
                playIcon?.isHidden = true
            }
        } else {
            videoContainer.isHidden = true
            self.videoPreviewImageView?.removeFromSuperview()
            self.videoPreviewImageView = nil
            self.playIcon?.isHidden = true
        }
        
        if message.isOutgoing {
            messageBubble.backgroundColor = UIColor(red: 0, green: 0.5, blue: 1.0, alpha: 1.0)
            messageBubble.removeConstraints(messageBubble.constraints.filter {
                $0.firstAttribute == .leading || $0.firstAttribute == .trailing
            })
            NSLayoutConstraint.activate([
                messageBubble.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
                messageBubble.leadingAnchor.constraint(greaterThanOrEqualTo: contentView.leadingAnchor, constant: 16)
            ])
        } else {
            messageBubble.backgroundColor = UIColor(white: 0.2, alpha: 1.0)
            messageBubble.removeConstraints(messageBubble.constraints.filter {
                $0.firstAttribute == .leading || $0.firstAttribute == .trailing
            })
            NSLayoutConstraint.activate([
                messageBubble.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
                messageBubble.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor, constant: -16)
            ])
        }
    }
    
    private func showLoadingIndicator(withText text: String) {
        videoPreviewImageView?.isHidden = true
        for subview in videoContainer.subviews where subview is UILabel {
            subview.removeFromSuperview()
        }
        let loadingLabel = UILabel()
        loadingLabel.text = text
        loadingLabel.textColor = .white
        loadingLabel.translatesAutoresizingMaskIntoConstraints = false
        loadingLabel.textAlignment = .center
        videoContainer.addSubview(loadingLabel)
        NSLayoutConstraint.activate([
            loadingLabel.centerXAnchor.constraint(equalTo: videoContainer.centerXAnchor),
            loadingLabel.centerYAnchor.constraint(equalTo: videoContainer.centerYAnchor)
        ])
    }
    
    private func generateThumbnailAsync(from asset: AVURLAsset) {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 1280, height: 720)
        let time = CMTime(seconds: 0.1, preferredTimescale: 600)
        
        Task {
            do {
                let cgImage = try await generator.image(at: time).image
                let thumbnail = UIImage(cgImage: cgImage)
                await MainActor.run {
                    self.setupVideoContainer(with: thumbnail)
                }
            } catch {
                print("MessageCell: Ошибка создания превью (Async): \(error.localizedDescription)")
                await MainActor.run {
                    self.playIcon?.isHidden = false
                }
            }
        }
    }
    
    private func setupVideoContainer(with thumbnail: UIImage) {
        self.videoPreviewImageView?.removeFromSuperview()
        self.videoPreviewImageView = nil
        let imageView = UIImageView(image: thumbnail)
        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        videoContainer.insertSubview(imageView, at: 0)
        self.videoPreviewImageView = imageView
        imageView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            imageView.topAnchor.constraint(equalTo: videoContainer.topAnchor),
            imageView.leadingAnchor.constraint(equalTo: videoContainer.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: videoContainer.trailingAnchor),
            imageView.bottomAnchor.constraint(equalTo: videoContainer.bottomAnchor)
        ])
        self.videoPreviewImageView?.isHidden = false
        self.playIcon?.isHidden = false
        print("MessageCell: Превью видео настроено успешно.")
    }
    
    override func prepareForReuse() {
        super.prepareForReuse()
        messageLabel.text = nil
        dateLabel.text = nil
        videoURL = nil
        videoPreviewImageView?.removeFromSuperview()
        videoPreviewImageView = nil
        playIcon?.isHidden = true
        videoContainer.isHidden = true
        for subview in videoContainer.subviews where subview is UILabel {
            subview.removeFromSuperview()
        }
    }
    
    func showErrorAlert(message: String) {
        print("MessageCell: Ошибка: \(message)")
        _ = videoContainer.backgroundColor 
        videoContainer.backgroundColor = UIColor.red.withAlphaComponent(0.3)
        UIView.animate(withDuration: 0.5, animations: {
            self.videoContainer.backgroundColor = UIColor.black 
        })
        if let viewController = self.viewController {
            let alert = UIAlertController(
                title: "Ошибка воспроизведения", 
                message: message,
                preferredStyle: .alert
            )
            alert.addAction(UIAlertAction(title: "OK", style: .default))
            viewController.present(alert, animated: true)
        } else {
            print("MessageCell: Не удалось найти viewController для отображения ошибки")
        }
    }
} 

