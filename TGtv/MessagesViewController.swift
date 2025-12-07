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
    private var nextVideoSearchFromMessageId: Int64 = 0
    
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
    private var fixedRowHeight: CGFloat = 0
    private var isApplyingInitialHistory = false
    
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
    
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        updateFixedRowHeightIfNeeded()
    }
    
    override var preferredFocusEnvironments: [UIFocusEnvironment] {
        guard view.window != nil,
              tableView.window != nil,
              !messages.isEmpty else {
            return [tableView]
        }
        let lastIndexPath = IndexPath(row: messages.count - 1, section: 0)
        if let lastCell = tableView.cellForRow(at: lastIndexPath),
           lastCell.window != nil,
           lastCell.superview != nil {
            return [lastCell]
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
        
        // Back button with custom focus handling
        let backButton = TVBackButton()
        backButton.translatesAutoresizingMaskIntoConstraints = false
        backButton.addTarget(self, action: #selector(backButtonTapped), for: .primaryActionTriggered)
        view.addSubview(backButton)
        
        tableView.backgroundColor = .clear
        tableView.allowsSelection = true
        tableView.tableFooterView = UIView(frame: .zero)
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
        messageLabel.text = "Загрузка видеосообщений..."
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
        let initialRowHeight = max(1, floor(UIScreen.main.bounds.height / 3))
        tableView.rowHeight = initialRowHeight
        tableView.estimatedRowHeight = initialRowHeight
        tableView.contentInset = .zero
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
            let updatedIndexPaths = applyVideoFileUpdate(update.file)
            if !updatedIndexPaths.isEmpty {
                let visible = tableView.indexPathsForVisibleRows ?? []
                let rowsToReload = updatedIndexPaths.filter { visible.contains($0) }
                print("MessagesViewController: Обновляем \(rowsToReload.count) видимых ячеек из \(updatedIndexPaths.count) обновленных")
                if !rowsToReload.isEmpty {
                    DispatchQueue.main.async {
                        self.tableView.reloadRows(at: rowsToReload, with: .none)
                    }
                }
                // Также обновляем ячейки, которые станут видимыми, чтобы превью генерировалось заранее
                // Но делаем это только для файлов, которые готовы для превью
                let local = update.file.local
                let contiguousSize = max(local.downloadedPrefixSize, 0)
                let fileExists = FileManager.default.fileExists(atPath: local.path)
                let ready = fileExists && isLocalVideoReady(
                    at: local.path,
                    expectedSize: Int64(update.file.size),
                    downloadedSize: contiguousSize,
                    isCompleted: local.isDownloadingCompleted
                )
                if ready {
                    let notVisible = updatedIndexPaths.filter { !visible.contains($0) }
                    if !notVisible.isEmpty {
                        print("MessagesViewController: Файл готов для превью, обновляем \(notVisible.count) невидимых ячеек для предзагрузки превью")
                        DispatchQueue.main.async {
                            self.tableView.reloadRows(at: notVisible, with: .none)
                        }
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
        isApplyingInitialHistory = true
        canLoadMoreHistory = true
        isLoadingOlderMessages = false
        loadedMessageIds.removeAll()
        nextVideoSearchFromMessageId = 0
        
        loadingIndicator.startAnimating()
        messageLabel.isHidden = false
        messageLabel.text = "Загрузка видеосообщений..."
        
        if let appDelegate = UIApplication.shared.delegate as? AppDelegate {
            appDelegate.setMessagesViewController(self)
            print("MessagesViewController: Установлен как текущий VC в AppDelegate перед началом загрузки. ChatID: \(chatId)")
        }
        
        _ = Task { [weak self] in
            guard let self else { return }
            do {
                print("MessagesViewController: Загрузка видеосообщений чата \(self.chatId)")
                let foundMessages = try await self.fetchVideoMessages(from: 0)
                
                await MainActor.run { [weak self] in
                    self?.applyInitialHistory(foundMessages.messages,
                                              nextFromMessageId: foundMessages.nextFromMessageId)
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

    private func applyInitialHistory(_ rawMessages: [TDLibKit.Message],
                                     nextFromMessageId: Int64) {
        print("FirstLoad::ApplyHistory chatId=\(chatId) rawCount=\(rawMessages.count)")
        defer { isLoading = false }
        
        nextVideoSearchFromMessageId = nextFromMessageId
        
        guard !rawMessages.isEmpty else {
            print("FirstLoad::EmptyHistory chatId=\(chatId)")
            messages = []
            loadedMessageIds.removeAll()
            canLoadMoreHistory = nextFromMessageId != 0
            loadingIndicator.stopAnimating()
            messageLabel.isHidden = false
            messageLabel.text = nextFromMessageId != 0
                ? "Ищем видеосообщения..."
                : "В этом чате нет видеосообщений"
            tableView.reloadData()
            ensureVideoMessagesAvailability()
            scheduleInitialHistoryCompletion()
            return
        }
        
        let normalizedMessages = rawMessages
            .reversed()
            .filter { shouldDisplayMessage($0) }
            .map { makeTGMessage(from: $0) }
        messages = normalizedMessages
        loadedMessageIds = Set(normalizedMessages.map(\.id))
        canLoadMoreHistory = nextFromMessageId != 0
        print("FirstLoad::Normalized chatId=\(chatId) normalizedCount=\(messages.count)")
        
        loadingIndicator.stopAnimating()
        tableView.reloadData()
        tableView.layoutIfNeeded()
        print("FirstLoad::ReloadComplete chatId=\(chatId) visibleRows=\(tableView.numberOfRows(inSection: 0))")
        scrollToBottom(animated: false)
        focusLatestMessageAfterReload()
        ensureVideoMessagesAvailability()
        scheduleInitialHistoryCompletion()
    }

    private func handleInitialHistoryError(_ description: String) {
        isLoading = false
        scheduleInitialHistoryCompletion()
        loadingIndicator.stopAnimating()
        messageLabel.isHidden = false
        messageLabel.text = "Ошибка при загрузке сообщений: \(description)"
        showRetryLoadButton()
    }

    private func scheduleInitialHistoryCompletion(after delay: TimeInterval = 0.25) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.isApplyingInitialHistory = false
        }
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
            
            self.tableView.scrollToRow(at: lastIndex, at: .bottom, animated: false)
            self.setNeedsFocusUpdate()
            self.updateFocusIfNeeded()
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
        guard !isApplyingInitialHistory,
              canLoadMoreHistory,
              !isLoadingOlderMessages else { return }
        
        let nextFromId = nextVideoSearchFromMessageId
        guard nextFromId != 0 else {
            canLoadMoreHistory = false
            return
        }
        
        isLoadingOlderMessages = true
        
        let firstVisibleMessageId = tableView.indexPathsForVisibleRows?
            .sorted(by: { $0.row < $1.row })
            .compactMap { messageId(for: $0) }
            .first
        let selectedMessageId = messageId(for: tableView.indexPathForSelectedRow)
        
        _ = Task { [weak self] in
            guard let self else { return }
            do {
                print("MessagesViewController: Догружаем видеосообщения, начиная с \(nextFromId)")
                let history = try await self.fetchVideoMessages(from: nextFromId)
                
                await MainActor.run { [weak self] in
                    self?.prependHistory(history.messages,
                                         nextFromMessageId: history.nextFromMessageId,
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
                                nextFromMessageId: Int64,
                                anchorMessageId: Int64?,
                                selectedMessageId: Int64?) {
        nextVideoSearchFromMessageId = nextFromMessageId
        
        guard !rawMessages.isEmpty else {
            canLoadMoreHistory = nextFromMessageId != 0
            return
        }
        
        canLoadMoreHistory = nextFromMessageId != 0
        
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

    private func fetchVideoMessages(from fromMessageId: Int64) async throws -> FoundChatMessages {
        try await client.searchChatMessages(
            chatId: chatId,
            filter: .searchMessagesFilterVideo,
            fromMessageId: fromMessageId,
            limit: pageSize,
            messageThreadId: nil,
            offset: 0,
            query: nil,
            savedMessagesTopicId: nil,
            senderId: nil
        )
    }
    
    private func updateFixedRowHeightIfNeeded() {
        let adjustedInsets = tableView.adjustedContentInset
        let availableHeight = tableView.bounds.height - adjustedInsets.top - adjustedInsets.bottom
        guard availableHeight > 0 else { return }
        let targetHeight = floor(availableHeight / 3)
        guard targetHeight > 0 else { return }
        if abs(targetHeight - fixedRowHeight) > 0.5 {
            fixedRowHeight = targetHeight
            tableView.rowHeight = targetHeight
            tableView.estimatedRowHeight = targetHeight
            tableView.beginUpdates()
            tableView.endUpdates()
        }
    }
    
    private func getMessageText(from message: TDLibKit.Message) -> String {
        switch message.content {
        case .messageText(let messageText):
            return messageText.text.text
        case .messagePhoto(let messagePhoto):
            return messagePhoto.caption.text
        case .messageVideo(let messageVideo):
            let caption = messageVideo.caption.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return caption
        case .messageDocument(let messageDocument):
            let caption = messageDocument.caption.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return caption.isEmpty ? "Документ" : caption
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
            
            let contiguousSize = max(local.downloadedPrefixSize, 0)
            let expectedSize = max(Int64(file.size), max(local.downloadedSize, contiguousSize))
            let videoInfo = TG.MessageMedia.VideoInfo(
                path: path,
                fileId: file.id,
                expectedSize: expectedSize,
                downloadedSize: contiguousSize,
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
    
    private func applyVideoFileUpdate(_ file: TDLibKit.File) -> [IndexPath] {
        var updatedIndexPaths: [IndexPath] = []
        let local = file.local
        let contiguousSize = max(local.downloadedPrefixSize, 0)
        let expectedSize = max(Int64(file.size), max(local.downloadedSize, contiguousSize))
        
        print("MessagesViewController: applyVideoFileUpdate для файла \(file.id), downloadedPrefixSize: \(contiguousSize), downloadedSize: \(local.downloadedSize), expectedSize: \(expectedSize), path: \(local.path)")
        
        for index in messages.indices {
            guard case .video(let info) = messages[index].media,
                  info.fileId == file.id else { continue }
            
            let updatedInfo = TG.MessageMedia.VideoInfo(
                path: local.path,
                fileId: file.id,
                expectedSize: expectedSize,
                downloadedSize: contiguousSize,
                isDownloadingCompleted: local.isDownloadingCompleted,
                mimeType: info.mimeType
            )
            messages[index] = messages[index].updatingMedia(.video(updatedInfo))
            updatedIndexPaths.append(IndexPath(row: index, section: 0))
            
            // Проверяем, готов ли файл для превью
            let fileExists = FileManager.default.fileExists(atPath: local.path)
            let ready = fileExists && isLocalVideoReady(
                at: local.path,
                expectedSize: expectedSize,
                downloadedSize: contiguousSize,
                isCompleted: local.isDownloadingCompleted
            )
            print("MessagesViewController: Файл \(file.id) в сообщении \(messages[index].id) - готов для превью: \(ready), файл существует: \(fileExists)")
        }
        
        if let pendingInfo = pendingVideoInfo, pendingInfo.fileId == file.id {
            pendingVideoInfo = TG.MessageMedia.VideoInfo(
                path: local.path,
                fileId: file.id,
                expectedSize: expectedSize,
                downloadedSize: contiguousSize,
                isDownloadingCompleted: local.isDownloadingCompleted,
                mimeType: pendingInfo.mimeType
            )
            tryStartPendingPlaybackIfPossible()
        }
        
        return updatedIndexPaths
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
        
        print("MessagesViewController: Запуск воспроизведения файла \(info.fileId), isCompleted: \(info.isDownloadingCompleted), downloadedSize: \(info.downloadedSize), expectedSize: \(info.expectedSize)")
        
        let playerItem: AVPlayerItem?
        // Для воспроизведения используем потоковое воспроизведение, если файл не полностью загружен
        // Это важно, так как обычное воспроизведение не работает с частично загруженными файлами
        if info.isDownloadingCompleted && FileManager.default.fileExists(atPath: info.path) {
            // Файл полностью загружен - используем обычное воспроизведение
            print("MessagesViewController: Файл полностью загружен, используем обычное воспроизведение")
            streamingCoordinator = nil
            let asset = AVURLAsset(url: fileURL, options: assetOptions(for: info.mimeType))
            playerItem = AVPlayerItem(asset: asset)
        } else {
            // Файл не полностью загружен - используем потоковое воспроизведение
            print("MessagesViewController: Файл не полностью загружен, используем потоковое воспроизведение. Загружено: \(info.downloadedSize)/\(info.expectedSize)")
            let coordinator = VideoStreamingCoordinator(video: info, client: client)
            streamingCoordinator = coordinator
            coordinator.startDownloadIfNeeded()
            playerItem = coordinator.makePlayerItem()
        }
        
        guard let preparedItem = playerItem else {
            streamingCoordinator = nil
            print("MessagesViewController: ОШИБКА - не удалось создать playerItem для файла \(info.fileId)")
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
        cell.selectionStyle = .none
        return cell
    }
    
    func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        if fixedRowHeight > 0 {
            return fixedRowHeight
        }
        let adjustedInsets = tableView.adjustedContentInset
        let availableHeight = tableView.bounds.height - adjustedInsets.top - adjustedInsets.bottom
        if availableHeight > 0 {
            return floor(availableHeight / 3)
        }
        return max(1, floor(UIScreen.main.bounds.height / 3))
    }
    
    func tableView(_ tableView: UITableView, willDisplay cell: UITableViewCell, forRowAt indexPath: IndexPath) {
        if !isApplyingInitialHistory && indexPath.row == 0 {
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
    guard FileManager.default.fileExists(atPath: path) else {
        print("isLocalVideoReady: Файл не существует: \(path)")
        return false
    }
    
    if isCompleted {
        print("isLocalVideoReady: Файл полностью загружен: \(path)")
        return true
    }
    
    guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
          let fileSize = attributes[.size] as? UInt64 else {
        print("isLocalVideoReady: Не удалось получить размер файла: \(path)")
        return false
    }
    
    // Минимальный размер для генерации превью (512 КБ достаточно для метаданных и первого кадра)
    let minPreviewBytes: UInt64 = 512 * 1024
    
    // Если файл уже достаточно большой для превью, считаем его готовым
    if fileSize >= minPreviewBytes {
        print("isLocalVideoReady: Файл достаточно большой для превью: \(path), размер: \(fileSize) байт")
        return true
    }
    
    // Если есть информация о загруженных данных, проверяем их
    let contiguousBytes = UInt64(max(downloadedSize, 0))
    if contiguousBytes >= minPreviewBytes {
        // Если загружено достаточно данных, проверяем, что файл на диске соответствует
        // Используем более мягкую проверку: файл должен быть хотя бы 80% от загруженных данных
        let minFileSize = contiguousBytes * 80 / 100
        let ready = fileSize >= minFileSize
        print("isLocalVideoReady: Проверка по загруженным данным: \(path), fileSize: \(fileSize), contiguousBytes: \(contiguousBytes), minFileSize: \(minFileSize), ready: \(ready)")
        return ready
    }
    
    // Если ожидаемый размер известен и файл уже достаточно большой
    if expectedSize > 0 {
        let expectedUInt64 = UInt64(expectedSize)
        // Если файл загружен хотя бы на 1% или больше минимума для превью
        let minRequired = max(expectedUInt64 / 100, minPreviewBytes)
        let ready = fileSize >= minRequired
        print("isLocalVideoReady: Проверка по ожидаемому размеру: \(path), fileSize: \(fileSize), expectedSize: \(expectedUInt64), minRequired: \(minRequired), ready: \(ready)")
        return ready
    }
    
    // В крайнем случае, если файл больше минимума для превью
    let ready = fileSize >= minPreviewBytes
    print("isLocalVideoReady: Финальная проверка: \(path), fileSize: \(fileSize), minPreviewBytes: \(minPreviewBytes), ready: \(ready)")
    return ready
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

// MARK: - Custom Back Button for tvOS

final class TVBackButton: UIButton {
    override init(frame: CGRect) {
        super.init(frame: frame)
        setupButton()
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    private func setupButton() {
        setTitle("← Назад", for: .normal)
        titleLabel?.font = .systemFont(ofSize: 26, weight: .medium)
        setTitleColor(UIColor(red: 0.85, green: 0.85, blue: 0.87, alpha: 1), for: .normal)
        backgroundColor = UIColor(red: 0.22, green: 0.22, blue: 0.24, alpha: 1)
        layer.cornerRadius = 12
    }
    
    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        
        coordinator.addCoordinatedAnimations {
            if self.isFocused {
                self.backgroundColor = UIColor(red: 0.30, green: 0.30, blue: 0.32, alpha: 1)
                self.transform = CGAffineTransform(scaleX: 1.05, y: 1.05)
            } else {
                self.backgroundColor = UIColor(red: 0.22, green: 0.22, blue: 0.24, alpha: 1)
                self.transform = .identity
            }
        }
    }
}

// MARK: - Message Cell

final class MessageCell: UITableViewCell {
    private enum Palette {
        static let incomingBubble = UIColor(red: 0.17, green: 0.19, blue: 0.24, alpha: 1)
        static let outgoingBubble = UIColor(red: 0.21, green: 0.24, blue: 0.30, alpha: 1)
        static let incomingBubbleFocused = UIColor(red: 0.22, green: 0.24, blue: 0.30, alpha: 1)
        static let outgoingBubbleFocused = UIColor(red: 0.26, green: 0.29, blue: 0.36, alpha: 1)
        static let text = UIColor(red: 0.93, green: 0.93, blue: 0.95, alpha: 1)
        static let videoBackground = UIColor(red: 0.11, green: 0.12, blue: 0.16, alpha: 1)
        static let playIcon = UIColor(red: 0.86, green: 0.87, blue: 0.90, alpha: 0.9)
    }
    
    private enum LayoutMetrics {
        static let defaultMargins = UIEdgeInsets(top: 10, left: 12, bottom: 8, right: 12)
        static let compactMargins = UIEdgeInsets(top: 6, left: 12, bottom: 4, right: 12)
        static let defaultSpacing: CGFloat = 6
        static let compactSpacing: CGFloat = 2
        static let spacingAfterVideoWithCaption: CGFloat = 8
        static let spacingAfterVideoWithoutCaption: CGFloat = 2
        static let videoReserveWithCaption: CGFloat = 72
        static let videoReserveWithoutCaption: CGFloat = 28
    }
    private let messageBubble = UIView()
    private let messageLabel = UILabel()
    private let videoContainer = UIView()
    private var videoMaxHeightConstraint: NSLayoutConstraint?
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
    private var isOutgoingMessage = false
    private var isGeneratingThumbnail = false
    
    weak var viewController: MessagesViewController?
    var indexPath: IndexPath?
    
    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        setupUI()
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    private let stackView = UIStackView()
    
    private func setupUI() {
        backgroundColor = .clear
        contentView.backgroundColor = .clear
        selectionStyle = .none
        focusStyle = .custom
        
        messageBubble.translatesAutoresizingMaskIntoConstraints = false
        messageBubble.layer.cornerRadius = 14
        messageBubble.backgroundColor = Palette.incomingBubble
        contentView.addSubview(messageBubble)
        
        let topConstraint = messageBubble.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 6)
        let bottomConstraint = messageBubble.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -6)
        topConstraint.priority = UILayoutPriority(999)
        bottomConstraint.priority = UILayoutPriority(999)
        incomingConstraints = [
            messageBubble.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 32),
            messageBubble.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor, constant: -60)
        ]
        outgoingConstraints = [
            messageBubble.leadingAnchor.constraint(greaterThanOrEqualTo: contentView.leadingAnchor, constant: 60),
            messageBubble.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -32)
        ]
        NSLayoutConstraint.activate(incomingConstraints + [topConstraint, bottomConstraint])

        // Stack view для контента
        stackView.axis = .vertical
        stackView.spacing = LayoutMetrics.defaultSpacing
        stackView.alignment = .fill
        stackView.distribution = .fill
        stackView.isLayoutMarginsRelativeArrangement = true
        stackView.layoutMargins = LayoutMetrics.defaultMargins
        stackView.translatesAutoresizingMaskIntoConstraints = false
        messageBubble.addSubview(stackView)
        
        // Контейнер видео располагаем первым, чтобы подписи шли ниже
        videoContainer.backgroundColor = Palette.videoBackground
        videoContainer.isHidden = true
        videoContainer.layer.cornerRadius = 10
        videoContainer.clipsToBounds = true
        videoContainer.translatesAutoresizingMaskIntoConstraints = false
        stackView.addArrangedSubview(videoContainer)
        
        // Иконка воспроизведения
        let playIcon = UIImageView()
        playIcon.translatesAutoresizingMaskIntoConstraints = false
        playIcon.image = UIImage(systemName: "play.circle.fill")
        playIcon.tintColor = Palette.playIcon
        playIcon.contentMode = .scaleAspectFit
        videoContainer.addSubview(playIcon)
        self.playIcon = playIcon
        
        // Текст сообщения отображается после видео, чтобы его не «выталкивало» вверх
        messageLabel.textColor = Palette.text
        messageLabel.font = .systemFont(ofSize: 22, weight: .regular)
        messageLabel.numberOfLines = 3
        messageLabel.lineBreakMode = .byTruncatingTail
        messageLabel.setContentCompressionResistancePriority(.defaultHigh, for: .vertical)
        messageLabel.setContentHuggingPriority(.defaultHigh, for: .vertical)
        stackView.addArrangedSubview(messageLabel)
        
        updateLayoutForCaption(true)
        
        let equalWidthConstraint = videoContainer.widthAnchor.constraint(equalTo: stackView.widthAnchor)
        equalWidthConstraint.priority = UILayoutPriority(750)
        equalWidthConstraint.isActive = true
        let videoMaxWidthConstraint = videoContainer.widthAnchor.constraint(lessThanOrEqualToConstant: 460)
        videoMaxWidthConstraint.priority = UILayoutPriority(999)
        videoMaxWidthConstraint.isActive = true
        
        let aspectConstraint = videoContainer.heightAnchor.constraint(equalTo: videoContainer.widthAnchor, multiplier: 9/16)
        aspectConstraint.priority = UILayoutPriority(950)
        aspectConstraint.isActive = true
        videoMaxHeightConstraint = videoContainer.heightAnchor.constraint(
            lessThanOrEqualTo: messageBubble.heightAnchor,
            constant: -LayoutMetrics.videoReserveWithCaption
        )
        videoMaxHeightConstraint?.priority = UILayoutPriority(999)
        videoMaxHeightConstraint?.isActive = true
        
        NSLayoutConstraint.activate([
            stackView.topAnchor.constraint(equalTo: messageBubble.topAnchor),
            stackView.leadingAnchor.constraint(equalTo: messageBubble.leadingAnchor),
            stackView.trailingAnchor.constraint(equalTo: messageBubble.trailingAnchor),
            stackView.bottomAnchor.constraint(equalTo: messageBubble.bottomAnchor),
            
            playIcon.centerXAnchor.constraint(equalTo: videoContainer.centerXAnchor),
            playIcon.centerYAnchor.constraint(equalTo: videoContainer.centerYAnchor),
            playIcon.widthAnchor.constraint(equalToConstant: 50),
            playIcon.heightAnchor.constraint(equalToConstant: 50)
        ])
    }
    
    override var canBecomeFocused: Bool {
        return true
    }
    
    private func applyAlignment(isOutgoing: Bool) {
        isOutgoingMessage = isOutgoing
        if isOutgoing {
            NSLayoutConstraint.deactivate(incomingConstraints)
            NSLayoutConstraint.activate(outgoingConstraints)
            messageBubble.backgroundColor = Palette.outgoingBubble
        } else {
            NSLayoutConstraint.deactivate(outgoingConstraints)
            NSLayoutConstraint.activate(incomingConstraints)
            messageBubble.backgroundColor = Palette.incomingBubble
        }
        contentView.layoutIfNeeded()
    }
    
    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        
        coordinator.addCoordinatedAnimations {
            if self.isFocused {
                self.messageBubble.transform = .identity
                self.messageBubble.layer.borderWidth = 2
                self.messageBubble.layer.borderColor = UIColor.white.withAlphaComponent(0.08).cgColor
                self.messageBubble.backgroundColor = self.isOutgoingMessage ? Palette.outgoingBubbleFocused : Palette.incomingBubbleFocused
            } else {
                self.messageBubble.transform = .identity
                self.messageBubble.layer.borderWidth = 0
                self.messageBubble.layer.borderColor = nil
                self.messageBubble.backgroundColor = self.isOutgoingMessage ? Palette.outgoingBubble : Palette.incomingBubble
            }
        }
    }
    
    func configure(with message: TG.Message, viewController: MessagesViewController, indexPath: IndexPath) {
        self.viewController = viewController
        self.indexPath = indexPath
        
        // Текст сообщения
        messageLabel.text = message.text
        messageLabel.isHidden = message.text.isEmpty
        updateLayoutForCaption(!message.text.isEmpty)
        
        // Видео
        if let media = message.media, case .video(let info) = media {
            print("MessageCell: configure вызван для сообщения \(message.id), файл \(info.fileId), путь: \(info.path), downloadedSize: \(info.downloadedSize), expectedSize: \(info.expectedSize), isCompleted: \(info.isDownloadingCompleted)")
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
                        // Если превью еще нет и не генерируется, генерируем его
                        if videoPreviewImageView == nil && !isGeneratingThumbnail, let url = videoURL {
                            print("MessageCell: Генерируем превью для файла \(info.fileId), путь: \(path), размер: \(info.downloadedSize)/\(info.expectedSize)")
                            generateThumbnailAsync(for: info, url: url)
                        } else if videoPreviewImageView != nil {
                            print("MessageCell: Превью уже есть для файла \(info.fileId)")
                        } else if isGeneratingThumbnail {
                            print("MessageCell: Превью уже генерируется для файла \(info.fileId)")
                        }
                        // Показываем превью, если оно есть
                        videoPreviewImageView?.isHidden = false
                        playIcon?.isHidden = false
                        // Убираем индикатор загрузки, если он есть и превью уже есть
                        if videoPreviewImageView != nil {
                            for subview in videoContainer.subviews where subview is UILabel {
                                subview.removeFromSuperview()
                            }
                        }
                    } else if !info.isDownloadingCompleted {
                        print("MessageCell: Файл \(info.fileId) еще не готов для превью, загружено: \(info.downloadedSize)/\(info.expectedSize)")
                        // Если файл еще загружается, показываем индикатор
                        // Но не скрываем превью, если оно уже есть (чтобы не мигало)
                        if videoPreviewImageView == nil {
                            showLoadingIndicator(withText: "Загрузка...")
                        }
                        playIcon?.isHidden = true
                    } else {
                        showLoadingIndicator(withText: "Повреждено")
                        playIcon?.isHidden = true
                    }
                } else {
                    // Файл еще не существует на диске
                    if videoPreviewImageView == nil {
                        showLoadingIndicator(withText: "Загрузка...")
                    }
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
        
        // Принудительно обновляем layout
        setNeedsLayout()
        layoutIfNeeded()
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
        // Предотвращаем множественную генерацию
        guard !isGeneratingThumbnail else {
            print("MessageCell: Превью уже генерируется, пропускаем")
            return
        }
        
        // Проверяем, что это тот же файл
        guard let currentInfo = videoInfo, currentInfo.fileId == info.fileId else {
            print("MessageCell: Информация о видео изменилась, пропускаем генерацию превью")
            return
        }
        
        isGeneratingThumbnail = true
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
                    // Проверяем, что информация о видео не изменилась
                    if let currentInfo = self.videoInfo, currentInfo.fileId == info.fileId {
                        self.setupVideoContainer(with: thumbnail)
                    }
                    self.isGeneratingThumbnail = false
                }
            } catch {
                print("MessageCell: Ошибка создания превью (Async): \(error.localizedDescription)")
                await MainActor.run {
                    self.isGeneratingThumbnail = false
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
        // Убираем индикатор загрузки
        for subview in videoContainer.subviews where subview is UILabel {
            subview.removeFromSuperview()
        }
        if let fileId = videoInfo?.fileId {
            print("MessageCell: Превью видео настроено успешно для файла \(fileId).")
        }
    }
    
    private func updateLayoutForCaption(_ hasCaption: Bool) {
        stackView.spacing = hasCaption ? LayoutMetrics.defaultSpacing : LayoutMetrics.compactSpacing
        stackView.layoutMargins = hasCaption ? LayoutMetrics.defaultMargins : LayoutMetrics.compactMargins
        stackView.setCustomSpacing(
            hasCaption ? LayoutMetrics.spacingAfterVideoWithCaption : LayoutMetrics.spacingAfterVideoWithoutCaption,
            after: videoContainer
        )
        let reserve = hasCaption ? LayoutMetrics.videoReserveWithCaption : LayoutMetrics.videoReserveWithoutCaption
        videoMaxHeightConstraint?.constant = -reserve
    }
    
    override func prepareForReuse() {
        super.prepareForReuse()
        messageLabel.text = nil
        messageLabel.isHidden = false
        videoInfo = nil
        isUnsupportedVideo = false
        isOutgoingMessage = false
        isGeneratingThumbnail = false
        videoPreviewImageView?.removeFromSuperview()
        videoPreviewImageView = nil
        playIcon?.isHidden = true
        messageBubble.transform = .identity
        messageBubble.backgroundColor = Palette.incomingBubble
        videoContainer.isHidden = true
        for subview in videoContainer.subviews where subview is UILabel {
            subview.removeFromSuperview()
        }
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
        print("VideoStreamingCoordinator: Создаем playerItem для файла \(video.fileId), downloadedSize: \(video.downloadedSize), expectedSize: \(video.expectedSize)")
        
        // Проверяем, что файл существует и имеет данные
        guard FileManager.default.fileExists(atPath: video.path) else {
            print("VideoStreamingCoordinator: Файл не существует: \(video.path)")
            return nil
        }
        
        // Проверяем размер файла
        if let attributes = try? FileManager.default.attributesOfItem(atPath: video.path),
           let fileSize = attributes[.size] as? UInt64 {
            print("VideoStreamingCoordinator: Размер файла на диске: \(fileSize) байт")
            if fileSize == 0 {
                print("VideoStreamingCoordinator: Файл пустой, не можем создать playerItem")
                return nil
            }
        }
        
        let asset = AVURLAsset(url: loader.streamURL)
        self.asset = asset
        asset.resourceLoader.setDelegate(loader, queue: loader.queue)
        let playerItem = AVPlayerItem(asset: asset)
        print("VideoStreamingCoordinator: playerItem создан успешно")
        return playerItem
    }
    
    func handleFileUpdate(_ file: TDLibKit.File) {
        guard file.id == video.fileId else { return }
        let local = file.local
        let contiguousSize = max(local.downloadedPrefixSize, 0)
        let expectedSize = max(Int64(file.size), max(local.downloadedSize, contiguousSize))
        loader.update(downloadedSize: contiguousSize,
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
        
        // Получаем реальный размер файла на диске
        guard let fileSize = getFileSize() else {
            print("ProgressiveFileResourceLoader: Не удалось получить размер файла")
            if !isCompleted {
                return false
            }
            finish(loadingRequest)
            return true
        }
        
        let endOffset = requestedOffset + requestedLength
        // Используем минимум из загруженных данных и реального размера файла
        let availableBytes = min(Int64(fileSize), downloadedSize)
        
        if availableBytes <= currentOffset {
            print("ProgressiveFileResourceLoader: Запрос за пределами доступных данных: offset=\(currentOffset), available=\(availableBytes), fileSize=\(fileSize), downloadedSize=\(downloadedSize), isCompleted=\(isCompleted)")
            // Если файл еще загружается, не завершаем запрос - он будет обработан позже
            if !isCompleted {
                return false
            }
            // Если файл завершен, но данных нет - это ошибка
            finish(loadingRequest)
            return true
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
            print("ProgressiveFileResourceLoader: Не удалось прочитать данные: offset=\(currentOffset), length=\(bytesToRead), fileSize=\(fileSize)")
            if isCompleted {
                finish(loadingRequest)
                return true
            }
            return false
        }
        
        dataRequest.respond(with: data)
        print("ProgressiveFileResourceLoader: Отправлено \(data.count) байт из \(bytesToRead) запрошенных, offset=\(currentOffset), requested=\(requestedLength)")
        
        let fullySatisfied = (currentOffset + Int64(data.count)) >= endOffset
        if fullySatisfied {
            finish(loadingRequest)
            return true
        }
        
        return false
    }
    
    private func getFileSize() -> UInt64? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
              let size = attributes[.size] as? UInt64 else {
            return nil
        }
        return size
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
            guard FileManager.default.fileExists(atPath: fileURL.path) else {
                print("ProgressiveFileResourceLoader: Файл не существует: \(fileURL.path)")
                return nil
            }
            
            // Проверяем размер файла перед чтением
            guard let fileSize = getFileSize() else {
                print("ProgressiveFileResourceLoader: Не удалось получить размер файла")
                return nil
            }
            
            // Защита от чтения за пределами файла
            let safeOffset = min(UInt64(offset), fileSize)
            let availableBytes = fileSize - safeOffset
            let safeLength = min(length, Int(availableBytes))
            
            guard safeLength > 0 else {
                print("ProgressiveFileResourceLoader: Нет данных для чтения: offset=\(offset), fileSize=\(fileSize), requestedLength=\(length)")
                return nil
            }
            
            do {
                let handle = try FileHandle(forReadingFrom: fileURL)
                defer {
                    try? handle.close()
                }
                try handle.seek(toOffset: safeOffset)
                let data = handle.readData(ofLength: safeLength)
                
                if data.isEmpty {
                    print("ProgressiveFileResourceLoader: Прочитано 0 байт: offset=\(safeOffset), length=\(safeLength), fileSize=\(fileSize)")
                }
                
                return data
            } catch {
                print("ProgressiveFileResourceLoader: Ошибка чтения файла: \(error), offset=\(safeOffset), length=\(safeLength)")
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

