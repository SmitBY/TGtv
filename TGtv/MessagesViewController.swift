import UIKit
import TDLibKit
import Combine
import AVFoundation
import AVKit

final class MessagesViewController: UIViewController, AVPlayerViewControllerDelegate {
    private let client: TDLibClient
    private var messages: [TG.Message] = []
    private let pageSize: Int = 50
    private var canLoadMoreHistory = true
    private var isLoadingOlderMessages = false
    private var loadedMessageIds = Set<Int64>()
    private var cancellables = Set<AnyCancellable>()
    private(set) var isLoading = false
    private var selectedVideoIndexPath: IndexPath?
    private weak var currentlyPlayingVideoCell: MessageCell?
    private weak var pendingPlayerViewController: AVPlayerViewController?
    private weak var pendingLoadingOverlay: UIView?
    private var pendingVideoInfo: TG.MessageMedia.VideoInfo?
    private let loadingOverlayTag = 0xC0FFEE
    private let playerBackgroundTag = 0xBACC0B
    private var oldestLoadedMessageId: Int64?
    
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
    
    private var streamingCoordinator: VideoStreamingCoordinator?
    
    private var isVideoActive = false
    
    private lazy var playerBackgroundImage: UIImage? = {
        if let assetImage = UIImage(named: "Back") {
            return assetImage
        }
        if let path = Bundle.main.path(forResource: "back", ofType: "png") {
            return UIImage(contentsOfFile: path)
        }
        return nil
    }()
    
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
        
        if !messages.isEmpty {
            scrollToBottom(animated: false)
            focusLatestMessageAfterReload(delay: 0)
        }
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
    
    // tvOS safe area (Apple HIG: 60pt top/bottom, 80pt sides)
    private let tvSafeInsets = UIEdgeInsets(top: 60, left: 80, bottom: 60, right: 80)
    
    private func setupUI() {
        // Gradient background
        let gradient = CAGradientLayer()
        gradient.colors = [
            UIColor(red: 0.06, green: 0.06, blue: 0.10, alpha: 1).cgColor,
            UIColor(red: 0.03, green: 0.03, blue: 0.06, alpha: 1).cgColor
        ]
        gradient.frame = view.bounds
        view.layer.insertSublayer(gradient, at: 0)
        
        // Back button with tvOS style
        let backButton = UIButton(type: .system)
        backButton.translatesAutoresizingMaskIntoConstraints = false
        backButton.setTitle("← Назад", for: .normal)
        backButton.titleLabel?.font = .systemFont(ofSize: 28, weight: .semibold)
        backButton.setTitleColor(UIColor(white: 0.8, alpha: 1), for: .normal)
        backButton.setTitleColor(.white, for: .focused)
        backButton.backgroundColor = UIColor(white: 0.15, alpha: 1)
        backButton.layer.cornerRadius = 12
        backButton.addTarget(self, action: #selector(backButtonTapped), for: .primaryActionTriggered)
        view.addSubview(backButton)
        
        tableView.backgroundColor = .clear
        tableView.separatorStyle = .none
        view.addSubview(tableView)
        
        loadingIndicator.translatesAutoresizingMaskIntoConstraints = false
        loadingIndicator.hidesWhenStopped = true
        loadingIndicator.color = .white
        loadingIndicator.startAnimating()
        view.addSubview(loadingIndicator)
        
        messageLabel.translatesAutoresizingMaskIntoConstraints = false
        messageLabel.textColor = UIColor(white: 0.7, alpha: 1)
        messageLabel.textAlignment = .center
        messageLabel.numberOfLines = 0
        messageLabel.font = .systemFont(ofSize: 28, weight: .medium)
        messageLabel.text = "Загрузка сообщений..."
        view.addSubview(messageLabel)
        
        NSLayoutConstraint.activate([
            backButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -tvSafeInsets.right),
            backButton.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -tvSafeInsets.bottom),
            backButton.widthAnchor.constraint(equalToConstant: 180),
            backButton.heightAnchor.constraint(equalToConstant: 60),
            
            tableView.topAnchor.constraint(equalTo: view.topAnchor, constant: tvSafeInsets.top),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: tvSafeInsets.left),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -tvSafeInsets.right),
            tableView.bottomAnchor.constraint(equalTo: backButton.topAnchor, constant: -30),
            
            loadingIndicator.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            loadingIndicator.centerYAnchor.constraint(equalTo: view.centerYAnchor, constant: -40),
            
            messageLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            messageLabel.topAnchor.constraint(equalTo: loadingIndicator.bottomAnchor, constant: 24),
            messageLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: tvSafeInsets.left),
            messageLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -tvSafeInsets.right)
        ])
        
        tableView.register(MessageCell.self, forCellReuseIdentifier: "MessageCell")
        tableView.delegate = self
        tableView.dataSource = self
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 140
        tableView.contentInset = UIEdgeInsets(top: 20, left: 0, bottom: 30, right: 0)
        tableView.clipsToBounds = false
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
            streamingCoordinator?.handleFileUpdate(update.file)
            if applyVideoFileUpdate(update.file) {
                if tableView.indexPathsForVisibleRows != nil {
                    DispatchQueue.main.async {
                        self.tableView.reloadData()
                    }
                }
            }
        } else if case .updateDeleteMessages(let deleteInfo) = update, deleteInfo.chatId == self.chatId {
            print("MessagesViewController: Получено обновление на удаление сообщений: \(deleteInfo.messageIds) в чате \(deleteInfo.chatId)")
            handleDeletedMessages(deleteInfo.messageIds)
        }
    }
    
    private func handleNewMessage(_ message: TDLibKit.Message) {
        print("MessagesViewController: Получено новое сообщение: \(message.id)")
        guard shouldDisplayMessage(message) else {
            print("MessagesViewController: Сообщение \(message.id) пропущено — нет видео")
            return
        }
        let newMessage = TG.Message(
            id: message.id,
            text: getMessageText(from: message),
            isOutgoing: message.isOutgoing,
            media: getMedia(from: message),
            date: Date(timeIntervalSince1970: TimeInterval(message.date))
        )
        
        if loadedMessageIds.contains(newMessage.id) {
            print("MessagesViewController: Сообщение \(newMessage.id) уже отображено, пропускаем добавление")
            return
        }
        
        // Добавляем новое сообщение и обновляем таблицу через batch updates
        let newIndex = messages.count
        messages.append(newMessage)
        loadedMessageIds.insert(newMessage.id)
        let indexPath = IndexPath(row: newIndex, section: 0)
        ensureVideoMessagesAvailability(triggerAutoLoad: false)
        
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
        var idsToDelete: [Int64] = []
        
        // Находим индексы сообщений, которые нужно удалить
        for (index, message) in messages.enumerated() {
            if deletedMessageIds.contains(message.id) {
                indexPathsToDelete.append(IndexPath(row: index, section: 0))
                indicesToDelete.insert(index)
                idsToDelete.append(message.id)
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
            idsToDelete.forEach { loadedMessageIds.remove($0) }
            tableView.deleteRows(at: indexPathsToDelete, with: .automatic)
        }) { completed in
            if completed {
                 print("MessagesViewController: Удалено \(indexPathsToDelete.count) сообщений. Новое количество: \(self.messages.count)")
                 if self.messages.isEmpty {
                     self.loadingIndicator.stopAnimating()
                 }
                 self.ensureVideoMessagesAvailability()
            }
        }
    }
    
    private func loadMessages() {
        guard !isLoading else { return }
        print("FirstLoad::Start chatId=\(chatId)")
        
        isLoading = true
        canLoadMoreHistory = true
        isLoadingOlderMessages = false
        loadedMessageIds.removeAll()
        oldestLoadedMessageId = nil
        
        loadingIndicator.startAnimating()
        messageLabel.isHidden = false
        messageLabel.text = "Загрузка сообщений..."
        
        if let appDelegate = UIApplication.shared.delegate as? AppDelegate {
            appDelegate.setMessagesViewController(self)
            print("MessagesViewController: Установлен как текущий VC в AppDelegate перед началом загрузки. ChatID: \(chatId)")
        }
        
        _ = Task { [weak self] in
            guard let self else { return }
            do {
                print("MessagesViewController: Загрузка истории чата \(self.chatId)")
                let primaryHistory = try await self.client.getChatHistory(
                    chatId: self.chatId,
                    fromMessageId: 0,
                    limit: self.pageSize,
                    offset: -self.pageSize,
                    onlyLocal: false
                )
                
                var historyMessages = primaryHistory.messages ?? []
                print("FirstLoad::HistoryReceived chatId=\(self.chatId) count=\(historyMessages.count) offset=-\(self.pageSize)")
                
                if historyMessages.isEmpty {
                    print("FirstLoad::HistoryEmptyWithNegativeOffset chatId=\(self.chatId) — пробуем offset=0")
                    let fallbackHistory = try await self.client.getChatHistory(
                        chatId: self.chatId,
                        fromMessageId: 0,
                        limit: self.pageSize,
                        offset: 0,
                        onlyLocal: false
                    )
                    historyMessages = fallbackHistory.messages ?? []
                    print("FirstLoad::HistoryReceivedFallback chatId=\(self.chatId) count=\(historyMessages.count)")
                }
                
                await MainActor.run { [weak self] in
                    self?.applyInitialHistory(historyMessages)
                }
            } catch {
                let errorDescription = String(describing: error)
                let errorType = type(of: error)
                print("MessagesViewController: Ошибка загрузки сообщений для чата \(self.chatId): \(errorDescription). Тип ошибки: \(errorType)")
                let nsError = error as NSError
                print("MessagesViewController: NSError: domain=\(nsError.domain), code=\(nsError.code), userInfo=\(nsError.userInfo)")
                
                await MainActor.run { [weak self] in
                    self?.handleInitialHistoryError(error.localizedDescription)
                }
            }
        }
    }

    private func applyInitialHistory(_ rawMessages: [TDLibKit.Message]) {
        print("FirstLoad::ApplyHistory chatId=\(chatId) rawCount=\(rawMessages.count)")
        defer { isLoading = false }
        
        if let newOldest = rawMessages.last?.id {
            oldestLoadedMessageId = newOldest
        }
        
        guard !rawMessages.isEmpty else {
            print("FirstLoad::EmptyHistory chatId=\(chatId)")
            messages = []
            loadedMessageIds.removeAll()
            canLoadMoreHistory = false
            loadingIndicator.stopAnimating()
            messageLabel.isHidden = false
            messageLabel.text = "Нет сообщений в этом чате"
            tableView.reloadData()
            return
        }
        
        let normalizedMessages = rawMessages
            .reversed()
            .filter { shouldDisplayMessage($0) }
            .map { makeTGMessage(from: $0) }
        messages = normalizedMessages
        loadedMessageIds = Set(normalizedMessages.map(\.id))
        canLoadMoreHistory = rawMessages.count == Int(pageSize)
        print("FirstLoad::Normalized chatId=\(chatId) normalizedCount=\(messages.count)")
        
        loadingIndicator.stopAnimating()
        tableView.reloadData()
        tableView.layoutIfNeeded()
        print("FirstLoad::ReloadComplete chatId=\(chatId) visibleRows=\(tableView.numberOfRows(inSection: 0))")
        scrollToBottom(animated: false)
        focusLatestMessageAfterReload()
        ensureVideoMessagesAvailability()
    }

    private func handleInitialHistoryError(_ description: String) {
        isLoading = false
        loadingIndicator.stopAnimating()
        messageLabel.isHidden = false
        messageLabel.text = "Ошибка при загрузке сообщений: \(description)"
        showRetryLoadButton()
    }

    private func showRetryLoadButton() {
        if view.subviews.contains(where: { ($0 as? UIButton)?.accessibilityIdentifier == "retryLoadMessagesButton" }) {
            return
        }
        
        let retryButton = UIButton(type: .system)
        retryButton.accessibilityIdentifier = "retryLoadMessagesButton"
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

    private func focusLatestMessageAfterReload(delay: TimeInterval = 0.5) {
        guard !messages.isEmpty else {
            print("MessagesViewController: Нет сообщений для выбора")
            return
        }
        
        let lastIndex = IndexPath(row: messages.count - 1, section: 0)
        let workItem = { [weak self] in
            guard let self else { return }
            if let appDelegate = UIApplication.shared.delegate as? AppDelegate {
                appDelegate.setMessagesViewController(self)
            }
            
            self.tableView.selectRow(at: lastIndex, animated: false, scrollPosition: .none)
            self.setNeedsFocusUpdate()
            self.updateFocusIfNeeded()
            
            if let cell = self.tableView.cellForRow(at: lastIndex) as? MessageCell {
                print("MessagesViewController: Устанавливаем фокус на последнее сообщение \(lastIndex.row)")
                cell.setSelected(true, animated: true)
            } else {
                print("MessagesViewController: Не удалось получить ячейку для последнего сообщения (focusLatestMessageAfterReload)")
            }
        }
        
        if delay > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
        } else {
            DispatchQueue.main.async(execute: workItem)
        }
    }

    private func messageId(for indexPath: IndexPath?) -> Int64? {
        guard let indexPath,
              messages.indices.contains(indexPath.row) else { return nil }
        return messages[indexPath.row].id
    }

    private func loadOlderMessages() {
        guard canLoadMoreHistory,
              !isLoadingOlderMessages,
              let oldestId = oldestLoadedMessageId else { return }
        
        isLoadingOlderMessages = true
        
        let firstVisibleMessageId = tableView.indexPathsForVisibleRows?
            .sorted(by: { $0.row < $1.row })
            .compactMap { messageId(for: $0) }
            .first
        let selectedMessageId = messageId(for: tableView.indexPathForSelectedRow)
        
        _ = Task { [weak self] in
            guard let self else { return }
            do {
                print("MessagesViewController: Догружаем историю до сообщения \(oldestId)")
                let history = try await self.client.getChatHistory(
                    chatId: self.chatId,
                    fromMessageId: oldestId,
                    limit: self.pageSize,
                    offset: -self.pageSize,
                    onlyLocal: false
                )
                
                await MainActor.run { [weak self] in
                    self?.prependHistory(history.messages ?? [],
                                         anchorMessageId: firstVisibleMessageId,
                                         selectedMessageId: selectedMessageId)
                }
            } catch {
                print("MessagesViewController: Ошибка догрузки старых сообщений: \(error)")
            }
            
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.isLoadingOlderMessages = false
                self.ensureVideoMessagesAvailability()
            }
        }
    }

    private func prependHistory(_ rawMessages: [TDLibKit.Message],
                                anchorMessageId: Int64?,
                                selectedMessageId: Int64?) {
        guard !rawMessages.isEmpty else {
            canLoadMoreHistory = false
            return
        }
        
        if let newOldest = rawMessages.last?.id {
            if let currentOldest = oldestLoadedMessageId {
                oldestLoadedMessageId = min(currentOldest, newOldest)
            } else {
                oldestLoadedMessageId = newOldest
            }
        }
        
        canLoadMoreHistory = rawMessages.count == Int(pageSize)
        
        let normalizedMessages = rawMessages
            .reversed()
            .filter { shouldDisplayMessage($0) }
            .map { makeTGMessage(from: $0) }
        let uniqueMessages = normalizedMessages.filter { !loadedMessageIds.contains($0.id) }
        
        guard !uniqueMessages.isEmpty else { return }
        
        messages.insert(contentsOf: uniqueMessages, at: 0)
        uniqueMessages.forEach { loadedMessageIds.insert($0.id) }
        
        tableView.reloadData()
        tableView.layoutIfNeeded()
        
        if let anchorId = anchorMessageId,
           let anchorRow = messages.firstIndex(where: { $0.id == anchorId }) {
            let anchorIndexPath = IndexPath(row: anchorRow, section: 0)
            tableView.scrollToRow(at: anchorIndexPath, at: .top, animated: false)
        }
        
        if let selectedId = selectedMessageId,
           let selectedRow = messages.firstIndex(where: { $0.id == selectedId }) {
            let selectedIndexPath = IndexPath(row: selectedRow, section: 0)
            tableView.selectRow(at: selectedIndexPath, animated: false, scrollPosition: .none)
        }
    }

    private func makeTGMessage(from message: TDLibKit.Message) -> TG.Message {
        TG.Message(
            id: message.id,
            text: getMessageText(from: message),
            isOutgoing: message.isOutgoing,
            media: getMedia(from: message),
            date: Date(timeIntervalSince1970: TimeInterval(message.date))
        )
    }
    
    private func shouldDisplayMessage(_ message: TDLibKit.Message) -> Bool {
        if case .messageVideo = message.content {
            return true
        }
        return false
    }
    
    @objc private func retryLoadMessages() {
        // Находим и удаляем кнопку повтора
        for subview in view.subviews {
            if let button = subview as? UIButton,
               button.accessibilityIdentifier == "retryLoadMessagesButton" {
                button.removeFromSuperview()
                break
            }
        }
        
        // Запускаем загрузку заново
        loadMessages()
    }
    
    private func scrollToBottom(animated: Bool = true) {
        guard !messages.isEmpty else { return }
        tableView.layoutIfNeeded()
        let lastIndex = IndexPath(row: messages.count - 1, section: 0)
        tableView.scrollToRow(at: lastIndex, at: .bottom, animated: animated)
    }
    
    private func ensureVideoMessagesAvailability(triggerAutoLoad: Bool = true) {
        if messages.isEmpty {
            loadingIndicator.stopAnimating()
            messageLabel.isHidden = false
            messageLabel.text = canLoadMoreHistory
                ? "Ищем видеосообщения..."
                : "В этом чате нет видеосообщений"
            if triggerAutoLoad && canLoadMoreHistory && !isLoadingOlderMessages {
                loadOlderMessages()
            }
        } else {
            messageLabel.isHidden = true
        }
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
            let file = messageVideo.video.video
            let local = file.local
            let path = local.path
            print("MessagesViewController: Путь к видео: \(path), доступно: \(local.isDownloadingCompleted), размер: \(file.size)")
            
            if !local.isDownloadingCompleted {
                requestDownload(for: file.id)
            }
            
            let expectedSize = max(Int64(file.size), local.downloadedSize)
            let videoInfo = TG.MessageMedia.VideoInfo(
                path: path,
                fileId: file.id,
                expectedSize: expectedSize,
                downloadedSize: local.downloadedSize,
                isDownloadingCompleted: local.isDownloadingCompleted,
                mimeType: messageVideo.video.mimeType.isEmpty ? "video/mp4" : messageVideo.video.mimeType
            )
            
            return .video(videoInfo)
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
        streamingCoordinator?.stop()
        streamingCoordinator = nil
        // Находим и останавливаем все воспроизводимые видео
        // Если используется AVPlayerViewController, он должен быть закрыт
        if let presentedVC = presentedViewController as? AVPlayerViewController {
            presentedVC.player?.pause()
            presentedVC.dismiss(animated: false) { // Закрываем синхронно, если нужно немедленно
                UIApplication.shared.isIdleTimerDisabled = false
            }
        }
        pendingLoadingOverlay?.removeFromSuperview()
        pendingLoadingOverlay = nil
        pendingVideoInfo = nil
        pendingPlayerViewController = nil
        // Старая логика для MessageCell, если она где-то осталась (должна быть удалена)
        for _ in tableView.visibleCells {
            // Удаляем этот блок, так как messageCell не используется и логика устарела
            // if let messageCell = cell as? MessageCell {
            //     // messageCell.stopAndCleanupPlayer() // Этот метод удален
            // }
        }
    }
    
    private func applyVideoFileUpdate(_ file: TDLibKit.File) -> Bool {
        var didUpdate = false
        let local = file.local
        let expectedSize = max(Int64(file.size), local.downloadedSize)
        for index in messages.indices {
            guard case .video(let info) = messages[index].media,
                  info.fileId == file.id else { continue }
            
            let updatedInfo = TG.MessageMedia.VideoInfo(
                path: local.path,
                fileId: file.id,
                expectedSize: expectedSize,
                downloadedSize: local.downloadedSize,
                isDownloadingCompleted: local.isDownloadingCompleted,
                mimeType: info.mimeType
            )
            messages[index] = messages[index].updatingMedia(.video(updatedInfo))
            didUpdate = true
        }
        
        if let pendingInfo = pendingVideoInfo, pendingInfo.fileId == file.id {
            pendingVideoInfo = TG.MessageMedia.VideoInfo(
                path: local.path,
                fileId: file.id,
                expectedSize: expectedSize,
                downloadedSize: local.downloadedSize,
                isDownloadingCompleted: local.isDownloadingCompleted,
                mimeType: pendingInfo.mimeType
            )
            tryStartPendingPlaybackIfPossible()
        }
        
        return didUpdate
    }
    
    private func requestDownload(for fileId: Int) {
        Task {
            do {
                print("MessagesViewController: Запускаем загрузку файла \(fileId)")
                _ = try await client.downloadFile(
                    fileId: fileId,
                    limit: 0,
                    offset: 0,
                    priority: 32,
                    synchronous: false
                )
            } catch {
                print("MessagesViewController: Ошибка загрузки файла \(fileId): \(error)")
            }
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

        guard let videoInfo = cell.videoInfo else {
            if cell.isUnsupportedVideo {
                showAlert(title: "Формат не поддерживается", message: "tvOS воспроизводит только MP4/MOV/HLS.")
            } else {
                print("MessagesViewController: videoInfo отсутствует для выбранной ячейки.")
            }
            return
        }

        // Если уже есть представленный AVPlayerViewController, закрываем его
        if let existingPlayerVC = presentedViewController as? AVPlayerViewController {
            existingPlayerVC.player?.pause()
            existingPlayerVC.dismiss(animated: true) { [weak self] in
                self?.presentNewPlayerViewController(for: videoInfo)
            }
            return
        }
        
        presentNewPlayerViewController(for: videoInfo)
    }

    private func presentNewPlayerViewController(for videoInfo: TG.MessageMedia.VideoInfo?) {
        guard let videoInfo = videoInfo else {
            print("MessagesViewController: videoInfo is nil")
            showAlert(title: "Ошибка", message: "Не удалось получить URL видео.")
            return
        }
        
        guard videoInfo.isPlayable else {
            showAlert(title: "Формат не поддерживается", message: "tvOS воспроизводит только MP4/MOV/HLS.")
            return
        }

        print("MessagesViewController: Настраиваем аудио сессию")
        setupGlobalAudioSession()
        
        if videoInfo.path.isEmpty {
            print("MessagesViewController: Локальный путь ещё не готов, запускаем воспроизведение в ожидании")
            preparePendingPlayback(for: videoInfo)
            return
        }
        
        startPlayback(with: videoInfo)
    }

    // Этот метод должен быть частью AVPlayerViewControllerDelegate
    // и не требует override, если класс MessagesViewController напрямую реализует протокол.
    func playerViewControllerDidEndFullScreenPresentation(_ playerViewController: AVPlayerViewController) {
        print("MessagesViewController: AVPlayerViewController был закрыт (playerViewControllerDidEndFullScreenPresentation).")
        UIApplication.shared.isIdleTimerDisabled = false
        streamingCoordinator?.stop()
        streamingCoordinator = nil
        if pendingPlayerViewController === playerViewController {
            pendingPlayerViewController = nil
            pendingVideoInfo = nil
            pendingLoadingOverlay?.removeFromSuperview()
            pendingLoadingOverlay = nil
        }
    }
    
    private func preparePendingPlayback(for info: TG.MessageMedia.VideoInfo) {
        requestDownload(for: info.fileId)
        
        if let existing = pendingPlayerViewController {
            pendingLoadingOverlay?.removeFromSuperview()
            pendingLoadingOverlay = nil
            pendingVideoInfo = nil
            pendingPlayerViewController = nil
            existing.dismiss(animated: false)
        }
        
        let playerVC = AVPlayerViewController()
        playerVC.delegate = self
        playerVC.loadViewIfNeeded()
        applyPlayerBackground(to: playerVC)
        if let overlay = addLoadingOverlay(to: playerVC, text: "Видео загружается...") {
            pendingLoadingOverlay = overlay
        }
        
        pendingPlayerViewController = playerVC
        pendingVideoInfo = info
        
        present(playerVC, animated: true) {
            print("MessagesViewController: Плеер показан и ожидает данные для файла \(info.fileId)")
        }
    }
    
    private func addLoadingOverlay(to playerVC: AVPlayerViewController, text: String) -> UIView? {
        guard let hostView = playerVC.view else { return nil }
        
        let overlay = UIView()
        overlay.translatesAutoresizingMaskIntoConstraints = false
        overlay.backgroundColor = UIColor.black.withAlphaComponent(0.3)
        overlay.tag = loadingOverlayTag
        overlay.isUserInteractionEnabled = false
        
        hostView.addSubview(overlay)
        hostView.bringSubviewToFront(overlay)
        
        NSLayoutConstraint.activate([
            overlay.topAnchor.constraint(equalTo: hostView.topAnchor),
            overlay.leadingAnchor.constraint(equalTo: hostView.leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: hostView.trailingAnchor),
            overlay.bottomAnchor.constraint(equalTo: hostView.bottomAnchor)
        ])
        
        let content = UIView()
        content.translatesAutoresizingMaskIntoConstraints = false
        content.isUserInteractionEnabled = false
        overlay.addSubview(content)
        
        NSLayoutConstraint.activate([
            content.centerXAnchor.constraint(equalTo: overlay.centerXAnchor),
            content.centerYAnchor.constraint(equalTo: overlay.centerYAnchor),
            content.leadingAnchor.constraint(greaterThanOrEqualTo: overlay.leadingAnchor, constant: 60),
            overlay.trailingAnchor.constraint(greaterThanOrEqualTo: content.trailingAnchor, constant: 60)
        ])
        
        let indicator = UIActivityIndicatorView(style: .large)
        indicator.translatesAutoresizingMaskIntoConstraints = false
        indicator.startAnimating()
        
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.text = text
        label.textColor = .white
        label.font = .systemFont(ofSize: 22, weight: .medium)
        label.numberOfLines = 0
        label.textAlignment = .center
        
        content.addSubview(indicator)
        content.addSubview(label)
        
        NSLayoutConstraint.activate([
            indicator.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            indicator.topAnchor.constraint(equalTo: content.topAnchor),
            label.topAnchor.constraint(equalTo: indicator.bottomAnchor, constant: 12),
            label.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            label.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            label.bottomAnchor.constraint(equalTo: content.bottomAnchor)
        ])
        
        return overlay
    }
    
    private func removeLoadingOverlay(from playerVC: AVPlayerViewController?) {
        if let overlay = pendingLoadingOverlay {
            overlay.removeFromSuperview()
            pendingLoadingOverlay = nil
            return
        }
        
        let container = playerVC?.view
        container?.viewWithTag(loadingOverlayTag)?.removeFromSuperview()
    }
    
    private func startPlayback(with info: TG.MessageMedia.VideoInfo, reuse controller: AVPlayerViewController? = nil) {
        guard !info.path.isEmpty else {
            print("MessagesViewController: Нельзя запустить воспроизведение — путь пустой")
            return
        }
        
        if !FileManager.default.fileExists(atPath: info.path) {
            let created = FileManager.default.createFile(atPath: info.path, contents: nil)
            print("MessagesViewController: Файл \(info.path) отсутствовал, создан: \(created)")
        }
        
        let fileURL = URL(fileURLWithPath: info.path)
        streamingCoordinator?.stop()
        
        let playerItem: AVPlayerItem?
        if isLocalVideoReady(at: info.path, expectedSize: info.expectedSize, downloadedSize: info.downloadedSize, isCompleted: info.isDownloadingCompleted) {
            streamingCoordinator = nil
            let asset = AVURLAsset(url: fileURL, options: assetOptions(for: info.mimeType))
            playerItem = AVPlayerItem(asset: asset)
        } else {
            let coordinator = VideoStreamingCoordinator(video: info, client: client)
            streamingCoordinator = coordinator
            coordinator.startDownloadIfNeeded()
            playerItem = coordinator.makePlayerItem()
        }
        
        guard let preparedItem = playerItem else {
            streamingCoordinator = nil
            showAlert(title: "Ошибка", message: "Не удалось подготовить потоковое воспроизведение.")
            return
        }
        
        let player = AVPlayer(playerItem: preparedItem)
        player.automaticallyWaitsToMinimizeStalling = false
        
        let playerVC = controller ?? AVPlayerViewController()
        playerVC.loadViewIfNeeded()
        applyPlayerBackground(to: playerVC)
        playerVC.player = player
        playerVC.delegate = self
        
        let startPlaybackBlock = {
            self.removeLoadingOverlay(from: playerVC)
            self.setPlayerBackgroundHidden(true, for: playerVC)
            player.play()
            UIApplication.shared.isIdleTimerDisabled = true
            print("MessagesViewController: Воспроизведение видео \(info.fileId) запущено")
        }
        
        if controller == nil {
            self.present(playerVC, animated: true, completion: startPlaybackBlock)
        } else {
            startPlaybackBlock()
        }
    }
    
    private func tryStartPendingPlaybackIfPossible() {
        guard let info = pendingVideoInfo,
              !info.path.isEmpty,
              let controller = pendingPlayerViewController else {
            return
        }
        startPlayback(with: info, reuse: controller)
        if let overlay = pendingLoadingOverlay {
            overlay.removeFromSuperview()
            pendingLoadingOverlay = nil
        }
        pendingVideoInfo = nil
        pendingPlayerViewController = nil
    }

    private func applyPlayerBackground(to playerVC: AVPlayerViewController) {
        guard let image = playerBackgroundImage else {
            return
        }
        
        setPlayerBackgroundHidden(false, for: playerVC)

        if let existing = playerVC.view.viewWithTag(playerBackgroundTag) as? UIImageView {
            existing.image = image
            playerVC.view.sendSubviewToBack(existing)
            return
        }
        
        let backgroundView = UIImageView(image: image)
        backgroundView.translatesAutoresizingMaskIntoConstraints = false
        backgroundView.contentMode = .scaleAspectFill
        backgroundView.clipsToBounds = true
        backgroundView.isUserInteractionEnabled = false
        backgroundView.tag = playerBackgroundTag
        
        playerVC.view.addSubview(backgroundView)
        playerVC.view.sendSubviewToBack(backgroundView)
        
        NSLayoutConstraint.activate([
            backgroundView.topAnchor.constraint(equalTo: playerVC.view.topAnchor),
            backgroundView.leadingAnchor.constraint(equalTo: playerVC.view.leadingAnchor),
            backgroundView.trailingAnchor.constraint(equalTo: playerVC.view.trailingAnchor),
            backgroundView.bottomAnchor.constraint(equalTo: playerVC.view.bottomAnchor)
        ])
    }
    
    private func setPlayerBackgroundHidden(_ hidden: Bool, for playerVC: AVPlayerViewController) {
        if let backgroundView = playerVC.view.viewWithTag(playerBackgroundTag) as? UIImageView {
            backgroundView.isHidden = hidden
        }
        playerVC.view.backgroundColor = hidden ? .black : .clear
        playerVC.contentOverlayView?.backgroundColor = .clear
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
    
    func tableView(_ tableView: UITableView, willDisplay cell: UITableViewCell, forRowAt indexPath: IndexPath) {
        if indexPath.row == 0 {
            loadOlderMessages()
        }
    }
    
    // НОВЫЙ МЕТОД ДЕЛЕГАТА
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        print("MessagesViewController: Ячейка выбрана по индексу \(indexPath.row)")
        guard let cell = tableView.cellForRow(at: indexPath) as? MessageCell else {
            print("MessagesViewController: Не удалось получить MessageCell для индекса \(indexPath.row)")
            return
        }

        // Проверяем, есть ли в ячейке видео
        if cell.videoInfo != nil {
            print("MessagesViewController: В ячейке есть видео, вызываем handleVideoTapInCell")
            handleVideoTapInCell(at: indexPath, cell: cell)
        } else if cell.isUnsupportedVideo {
            showAlert(title: "Формат не поддерживается", message: "tvOS воспроизводит только MP4/MOV/HLS.")
        } else {
            print("MessagesViewController: В ячейке нет видео.")
        }
        
        // Снимаем выделение с ячейки, если не хотим, чтобы она оставалась подсвеченной
        // tableView.deselectRow(at: indexPath, animated: true)
    }
}

private func isLocalVideoReady(at path: String, expectedSize: Int64, downloadedSize: Int64, isCompleted: Bool) -> Bool {
    if isCompleted {
        return true
    }
    guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
          let fileSize = attributes[.size] as? UInt64 else {
        return false
    }
    if expectedSize > 0 {
        return UInt64(expectedSize) <= fileSize
    }
    if downloadedSize > 0 {
        return UInt64(downloadedSize) <= fileSize
    }
    return fileSize > 0
}

private func assetOptions(for mimeType: String) -> [String: Any] {
    var options: [String: Any] = [
        AVURLAssetPreferPreciseDurationAndTimingKey: true
    ]
    if !mimeType.isEmpty {
        options["AVURLAssetOutOfBandMIMETypeKey"] = mimeType
    }
    return options
}

final class MessageCell: UITableViewCell {
    private let messageBubble = UIView()
    private let messageLabel = UILabel()
    private let dateLabel = UILabel()
    private let videoContainer = UIView()
    private var gradientLayer: CAGradientLayer?
    var videoInfo: TG.MessageMedia.VideoInfo?
    private var videoURL: URL? {
        guard let info = videoInfo, !info.path.isEmpty else { return nil }
        return URL(fileURLWithPath: info.path)
    }
    private var videoPreviewImageView: UIImageView?
    private var playIcon: UIImageView?
    private var playButton: UIButton?
    private var incomingConstraints: [NSLayoutConstraint] = []
    private var outgoingConstraints: [NSLayoutConstraint] = []
    var isUnsupportedVideo = false
    
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
        contentView.backgroundColor = .clear
        selectionStyle = .none
        clipsToBounds = false
        contentView.clipsToBounds = false
        
        messageBubble.translatesAutoresizingMaskIntoConstraints = false
        messageBubble.layer.cornerRadius = 20
        messageBubble.clipsToBounds = true
        contentView.addSubview(messageBubble)
        
        // Gradient for incoming messages
        let gradient = CAGradientLayer()
        gradient.colors = [
            UIColor(red: 0.16, green: 0.16, blue: 0.20, alpha: 1).cgColor,
            UIColor(red: 0.12, green: 0.12, blue: 0.16, alpha: 1).cgColor
        ]
        gradient.cornerRadius = 20
        messageBubble.layer.insertSublayer(gradient, at: 0)
        gradientLayer = gradient
        
        let topConstraint = messageBubble.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 12)
        let bottomConstraint = messageBubble.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -12)
        topConstraint.priority = UILayoutPriority(999)
        bottomConstraint.priority = UILayoutPriority(999)
        incomingConstraints = [
            messageBubble.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            messageBubble.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor, constant: -100)
        ]
        outgoingConstraints = [
            messageBubble.leadingAnchor.constraint(greaterThanOrEqualTo: contentView.leadingAnchor, constant: 100),
            messageBubble.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20)
        ]
        NSLayoutConstraint.activate(incomingConstraints + [topConstraint, bottomConstraint])
        
        messageLabel.textColor = .white
        messageLabel.font = .systemFont(ofSize: 28, weight: .regular)
        messageLabel.numberOfLines = 0
        messageLabel.lineBreakMode = .byWordWrapping
        messageLabel.backgroundColor = .clear
        
        dateLabel.textColor = UIColor(white: 0.5, alpha: 1)
        dateLabel.font = .systemFont(ofSize: 18, weight: .regular)
        
        videoContainer.translatesAutoresizingMaskIntoConstraints = false
        videoContainer.backgroundColor = UIColor(white: 0.08, alpha: 1)
        videoContainer.isHidden = true
        videoContainer.layer.cornerRadius = 16
        videoContainer.clipsToBounds = true
        
        self.playButton = nil

        let playIcon = UIImageView()
        playIcon.translatesAutoresizingMaskIntoConstraints = false
        playIcon.image = UIImage(systemName: "play.circle.fill")
        playIcon.tintColor = .white
        playIcon.contentMode = .scaleAspectFit
        playIcon.alpha = 0.9
        
        // Play icon shadow
        playIcon.layer.shadowColor = UIColor.black.cgColor
        playIcon.layer.shadowOpacity = 0.5
        playIcon.layer.shadowOffset = CGSize(width: 0, height: 2)
        playIcon.layer.shadowRadius = 4
        
        videoContainer.addSubview(playIcon)
        self.playIcon = playIcon
        
        let stack = UIStackView(arrangedSubviews: [messageLabel, videoContainer, dateLabel])
        stack.axis = .vertical
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        
        messageBubble.addSubview(stack)
        
        let videoHeightConstraint = videoContainer.heightAnchor.constraint(equalTo: videoContainer.widthAnchor, multiplier: 9/16)
        videoHeightConstraint.priority = .defaultHigh
        
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: messageBubble.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: messageBubble.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: messageBubble.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(equalTo: messageBubble.bottomAnchor, constant: -16),
            
            videoHeightConstraint,
            videoContainer.widthAnchor.constraint(lessThanOrEqualToConstant: 500),
            
            playIcon.centerXAnchor.constraint(equalTo: videoContainer.centerXAnchor),
            playIcon.centerYAnchor.constraint(equalTo: videoContainer.centerYAnchor),
            playIcon.widthAnchor.constraint(equalToConstant: 80),
            playIcon.heightAnchor.constraint(equalToConstant: 80)
        ])
        
        stack.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        stack.setContentHuggingPriority(.defaultLow, for: .vertical)
    }
    
    override func layoutSubviews() {
        super.layoutSubviews()
        gradientLayer?.frame = messageBubble.bounds
    }
    
    private func applyAlignment(isOutgoing: Bool) {
        if isOutgoing {
            NSLayoutConstraint.deactivate(incomingConstraints)
            NSLayoutConstraint.activate(outgoingConstraints)
            // Blue gradient for outgoing
            gradientLayer?.colors = [
                UIColor(red: 0.2, green: 0.5, blue: 0.95, alpha: 1).cgColor,
                UIColor(red: 0.15, green: 0.4, blue: 0.85, alpha: 1).cgColor
            ]
        } else {
            NSLayoutConstraint.deactivate(outgoingConstraints)
            NSLayoutConstraint.activate(incomingConstraints)
            // Dark gradient for incoming
            gradientLayer?.colors = [
                UIColor(red: 0.16, green: 0.16, blue: 0.20, alpha: 1).cgColor,
                UIColor(red: 0.12, green: 0.12, blue: 0.16, alpha: 1).cgColor
            ]
        }
        contentView.layoutIfNeeded()
    }
    
    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        
        coordinator.addCoordinatedAnimations {
            if self.isFocused {
                self.messageBubble.transform = CGAffineTransform(scaleX: 1.04, y: 1.04)
                self.messageBubble.layer.shadowColor = UIColor.white.cgColor
                self.messageBubble.layer.shadowOpacity = 0.25
                self.messageBubble.layer.shadowOffset = CGSize(width: 0, height: 10)
                self.messageBubble.layer.shadowRadius = 15
            } else {
                self.messageBubble.transform = .identity
                self.messageBubble.layer.shadowOpacity = 0
            }
        }
    }
    
    func configure(with message: TG.Message, viewController: MessagesViewController, indexPath: IndexPath) {
        self.viewController = viewController
        self.indexPath = indexPath
        messageLabel.text = message.text.isEmpty ? nil : message.text
        messageLabel.isHidden = message.text.isEmpty
        
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        dateLabel.text = formatter.string(from: message.date)
        
        if let media = message.media, case .video(let info) = media {
            videoContainer.isHidden = false
            isUnsupportedVideo = !info.isPlayable
            
            if info.isPlayable {
                videoInfo = info
                let path = info.path
                
                if !path.isEmpty && FileManager.default.fileExists(atPath: path) {
                    let ready = isLocalVideoReady(
                        at: path,
                        expectedSize: info.expectedSize,
                        downloadedSize: info.downloadedSize,
                        isCompleted: info.isDownloadingCompleted
                    )
                    
                    if ready {
                        if let url = videoURL {
                            generateThumbnailAsync(for: info, url: url)
                        }
                        playIcon?.isHidden = false
                    } else if !info.isDownloadingCompleted {
                        showLoadingIndicator(withText: "Загрузка...")
                        playIcon?.isHidden = true
                    } else {
                        showLoadingIndicator(withText: "Повреждено")
                        playIcon?.isHidden = true
                    }
                } else {
                    showLoadingIndicator(withText: "Загрузка...")
                    playIcon?.isHidden = true
                }
            } else {
                videoInfo = nil
                videoPreviewImageView?.removeFromSuperview()
                videoPreviewImageView = nil
                showLoadingIndicator(withText: "Формат не поддерживается")
                playIcon?.isHidden = true
            }
        } else {
            videoContainer.isHidden = true
            videoInfo = nil
            isUnsupportedVideo = false
            videoPreviewImageView?.removeFromSuperview()
            videoPreviewImageView = nil
            playIcon?.isHidden = true
        }
        
        applyAlignment(isOutgoing: message.isOutgoing)
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
    
    private func generateThumbnailAsync(for info: TG.MessageMedia.VideoInfo, url: URL) {
        let asset = AVURLAsset(url: url, options: assetOptions(for: info.mimeType))
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
        messageLabel.isHidden = false
        dateLabel.text = nil
        videoInfo = nil
        isUnsupportedVideo = false
        videoPreviewImageView?.removeFromSuperview()
        videoPreviewImageView = nil
        playIcon?.isHidden = true
        messageBubble.transform = .identity
        messageBubble.layer.shadowOpacity = 0
        videoContainer.isHidden = true
        for subview in videoContainer.subviews where subview is UILabel {
            subview.removeFromSuperview()
        }
        messageBubble.backgroundColor = UIColor(white: 0.2, alpha: 1.0)
        applyAlignment(isOutgoing: false)
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

// MARK: - Потоковое воспроизведение больших файлов

private final class VideoStreamingCoordinator {
    private let video: TG.MessageMedia.VideoInfo
    private let client: TDLibClient
    private let loader: ProgressiveFileResourceLoader
    private var downloadTask: Task<Void, Never>?
    private weak var asset: AVURLAsset?
    
    init(video: TG.MessageMedia.VideoInfo, client: TDLibClient) {
        self.video = video
        self.client = client
        let fileURL = URL(fileURLWithPath: video.path)
        self.loader = ProgressiveFileResourceLoader(
            fileURL: fileURL,
            mimeType: video.mimeType,
            expectedSize: video.expectedSize,
            initialDownloadedSize: video.downloadedSize,
            isCompleted: video.isDownloadingCompleted
        )
    }
    
    func startDownloadIfNeeded() {
        guard downloadTask == nil, !video.isDownloadingCompleted else { return }
        downloadTask = Task { [client, fileId = video.fileId] in
            do {
                _ = try await client.downloadFile(
                    fileId: fileId,
                    limit: 0,
                    offset: 0,
                    priority: 32,
                    synchronous: false
                )
            } catch {
                print("VideoStreamingCoordinator: Ошибка загрузки файла \(fileId): \(error)")
            }
        }
    }
    
    func makePlayerItem() -> AVPlayerItem? {
        let asset = AVURLAsset(url: loader.streamURL)
        self.asset = asset
        asset.resourceLoader.setDelegate(loader, queue: loader.queue)
        return AVPlayerItem(asset: asset)
    }
    
    func handleFileUpdate(_ file: TDLibKit.File) {
        guard file.id == video.fileId else { return }
        let local = file.local
        let expectedSize = max(Int64(file.size), local.downloadedSize)
        loader.update(downloadedSize: local.downloadedSize,
                      isCompleted: local.isDownloadingCompleted,
                      expectedSize: expectedSize)
    }
    
    func stop() {
        downloadTask?.cancel()
        downloadTask = nil
        loader.invalidate()
        asset = nil
    }
}

private final class ProgressiveFileResourceLoader: NSObject, AVAssetResourceLoaderDelegate {
    let queue = DispatchQueue(label: "com.tgtv.videostream.loader")
    let streamURL: URL
    
    private let fileURL: URL
    private let mimeType: String
    private var expectedSize: Int64
    private var downloadedSize: Int64
    private var isCompleted: Bool
    private var pendingRequests: [AVAssetResourceLoadingRequest] = []
    private var isInvalidated = false
    private let fileReadQueue = DispatchQueue(label: "com.tgtv.videostream.reader", qos: .userInitiated)
    private var hasProvidedContentInformation = false
    
    init(fileURL: URL, mimeType: String, expectedSize: Int64, initialDownloadedSize: Int64, isCompleted: Bool) {
        self.fileURL = fileURL
        self.mimeType = mimeType
        self.expectedSize = expectedSize
        self.downloadedSize = initialDownloadedSize
        self.isCompleted = isCompleted
        self.streamURL = URL(string: "tgstream://\(UUID().uuidString)")!
    }
    
    func update(downloadedSize: Int64, isCompleted: Bool, expectedSize: Int64? = nil) {
        queue.async {
            guard !self.isInvalidated else { return }
            self.downloadedSize = downloadedSize
            self.isCompleted = isCompleted
            if let expectedSize, expectedSize > self.expectedSize {
                self.expectedSize = expectedSize
            } else if downloadedSize > self.expectedSize {
                self.expectedSize = downloadedSize
            }
            self.processPendingRequests()
        }
    }
    
    func invalidate() {
        queue.async {
            self.isInvalidated = true
            self.pendingRequests.forEach { $0.finishLoading() }
            self.pendingRequests.removeAll()
        }
    }
    
    // MARK: AVAssetResourceLoaderDelegate
    
    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
        queue.async {
            guard !self.isInvalidated else {
                loadingRequest.finishLoading()
                return
            }
            self.pendingRequests.append(loadingRequest)
            _ = self.respond(to: loadingRequest)
        }
        return true
    }
    
    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, didCancel loadingRequest: AVAssetResourceLoadingRequest) {
        queue.async {
            self.pendingRequests.removeAll { $0 == loadingRequest }
        }
    }
    
    // MARK: Internal helpers
    
    private func processPendingRequests() {
        pendingRequests = pendingRequests.filter { !respond(to: $0) }
    }
    
    @discardableResult
    private func respond(to loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
        provideContentInformationIfNeeded(for: loadingRequest)
        
        guard let dataRequest = loadingRequest.dataRequest else {
            loadingRequest.finishLoading()
            return true
        }
        
        let requestedOffset = dataRequest.requestedOffset
        let requestedLength = Int64(dataRequest.requestedLength)
        var currentOffset = dataRequest.currentOffset
        if currentOffset < requestedOffset {
            currentOffset = requestedOffset
        }
        
        let endOffset = requestedOffset + requestedLength
        let availableBytes = downloadedSize
        
        if availableBytes <= currentOffset {
            return false
        }
        
        let bytesToRead = min(endOffset - currentOffset, availableBytes - currentOffset)
        guard bytesToRead > 0 else {
            if isCompleted {
                finish(loadingRequest)
                return true
            }
            return false
        }
        
        guard let data = readData(offset: currentOffset, length: Int(bytesToRead)), !data.isEmpty else {
            if isCompleted {
                finish(loadingRequest)
                return true
            }
            return false
        }
        
        dataRequest.respond(with: data)
        
        let fullySatisfied = (currentOffset + Int64(data.count)) >= endOffset
        if fullySatisfied {
            finish(loadingRequest)
            return true
        }
        
        return false
    }
    
    private func finish(_ loadingRequest: AVAssetResourceLoadingRequest) {
        provideContentInformationIfNeeded(for: loadingRequest)
        loadingRequest.finishLoading()
    }
    
    private func provideContentInformationIfNeeded(for loadingRequest: AVAssetResourceLoadingRequest) {
        guard !hasProvidedContentInformation,
              let infoRequest = loadingRequest.contentInformationRequest else { return }
        infoRequest.contentType = contentType(for: mimeType)
        infoRequest.contentLength = expectedSize
        infoRequest.isByteRangeAccessSupported = true
        hasProvidedContentInformation = true
    }
    
    private func readData(offset: Int64, length: Int) -> Data? {
        fileReadQueue.sync {
            guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
            do {
                let handle = try FileHandle(forReadingFrom: fileURL)
                try handle.seek(toOffset: UInt64(offset))
                let data = handle.readData(ofLength: length)
                try handle.close()
                return data
            } catch {
                print("ProgressiveFileResourceLoader: Ошибка чтения файла \(error)")
                return nil
            }
        }
    }
    
    private func contentType(for mimeType: String) -> String {
        if mimeType.contains("mp4") {
            return AVFileType.mp4.rawValue
        } else if mimeType.contains("quicktime") || mimeType.contains("mov") {
            return AVFileType.mov.rawValue
        } else if mimeType.contains("m4v") {
            return AVFileType.m4v.rawValue
        }
        return AVFileType.mp4.rawValue
    }
}

private func isSupportedVideoFormat(mimeType: String, path: String) -> Bool {
    let lowerMime = mimeType.lowercased()
    let mimeMatches = ["video/mp4", "video/quicktime", "video/x-m4v", "application/vnd.apple.mpegurl", "application/x-mpegurl", "video/h264", "video/hevc"]
        .contains(where: { lowerMime.contains($0) })
    
    if mimeMatches { return true }
    
    let ext = URL(fileURLWithPath: path).pathExtension.lowercased()
    let extensionMatches = ["mp4", "mov", "m4v", "m3u8"]
    return extensionMatches.contains(ext)
}

private extension TG.MessageMedia.VideoInfo {
    var isPlayable: Bool {
        isSupportedVideoFormat(mimeType: mimeType, path: path)
    }
}

private extension TG.Message {
    func updatingMedia(_ media: TG.MessageMedia?) -> TG.Message {
        TG.Message(
            id: id,
            text: text,
            isOutgoing: isOutgoing,
            media: media,
            date: date
        )
    }
}

