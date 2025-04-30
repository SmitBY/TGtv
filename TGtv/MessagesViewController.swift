import UIKit
import TDLibKit
import Combine
import AVFoundation
import AVKit

final class MessagesViewController: UIViewController {
    private let client: TDLibClient
    private var messages: [TG.Message] = []
    private var cancellables = Set<AnyCancellable>()
    private var isLoading = false
    
    let chatId: Int64
    
    private let tableView: UITableView = {
        let tv = UITableView()
        tv.backgroundColor = .black
        tv.translatesAutoresizingMaskIntoConstraints = false
        return tv
    }()
    
    private let loadingIndicator = UIActivityIndicatorView(style: .large)
    private let messageLabel = UILabel()
    
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
        setupUI()
        loadMessages()
        
        // Регистрируем контроллер в AppDelegate для получения обновлений
        if let appDelegate = UIApplication.shared.delegate as? AppDelegate {
            appDelegate.setMessagesViewController(self)
        }
        
        // Устанавливаем фокус на таблицу
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            self.tableView.becomeFirstResponder()
        }
    }
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        print("MessagesViewController: viewWillAppear")
        navigationController?.setNavigationBarHidden(true, animated: false)
        
        // Устанавливаем этот контроллер как обработчик обновлений
        if let appDelegate = UIApplication.shared.delegate as? AppDelegate {
            appDelegate.setMessagesViewController(self)
        }
    }
    
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        print("MessagesViewController: viewDidAppear")
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
        print("MessagesViewController: viewDidDisappear")
        
        // Проверяем, что нас действительно нужно удалить
        if navigationController == nil || navigationController?.viewControllers.contains(self) == false {
            if let appDelegate = UIApplication.shared.delegate as? AppDelegate, 
               appDelegate.messagesViewController === self {
                appDelegate.setMessagesViewController(nil)
            }
        } else {
            print("MessagesViewController: Остаемся в стеке навигации")
        }
    }
    
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        print("MessagesViewController: viewWillDisappear")
    }
    
    private func setupUI() {
        view.backgroundColor = .black
        
        // Добавляем кнопку назад
        let backButton = UIButton(type: .system)
        backButton.translatesAutoresizingMaskIntoConstraints = false
        backButton.setTitle("< Назад", for: .normal)
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
            backButton.topAnchor.constraint(equalTo: view.topAnchor, constant: 50),
            backButton.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 50),
            backButton.widthAnchor.constraint(equalToConstant: 120),
            backButton.heightAnchor.constraint(equalToConstant: 50),
            
            tableView.topAnchor.constraint(equalTo: backButton.bottomAnchor, constant: 20),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            
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
        
        // Устанавливаем ссылку на контроллер в nil только при явном нажатии кнопки назад
        if let appDelegate = UIApplication.shared.delegate as? AppDelegate, 
           appDelegate.messagesViewController === self {
            appDelegate.setMessagesViewController(nil)
        }
        
        navigationController?.popViewController(animated: true)
    }
    
    @MainActor
    func handleUpdate(_ update: TDLibKit.Update) {
        do {
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
            }
        } catch {
            print("MessagesViewController: Ошибка обработки обновления: \(error)")
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
        messages.append(newMessage)
        tableView.reloadData()
        
        // Прокручиваем к новому сообщению и выделяем его
        let lastIndex = IndexPath(row: messages.count - 1, section: 0)
        tableView.scrollToRow(at: lastIndex, at: .bottom, animated: true)
        
        // Устанавливаем фокус на новое сообщение
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            self.tableView.selectRow(at: lastIndex, animated: true, scrollPosition: .none)
            if let cell = self.tableView.cellForRow(at: lastIndex) as? MessageCell {
                cell.setSelected(true, animated: true)
            }
        }
    }
    
    private func loadMessages() {
        guard !isLoading else { return }
        
        isLoading = true
        loadingIndicator.startAnimating()
        messageLabel.isHidden = false
        messageLabel.text = "Загрузка сообщений..."
        
        Task {
            do {
                print("MessagesViewController: Загрузка истории чата \(chatId)")
                let history = try await client.getChatHistory(
                    chatId: chatId,
                    fromMessageId: 0,
                    limit: 50,
                    offset: 0,
                    onlyLocal: false
                )
                
                print("MessagesViewController: Получено \(history.messages?.count ?? 0) сообщений")
                
                await MainActor.run {
                    if let historyMessages = history.messages {
                        if !historyMessages.isEmpty {
                            messages = historyMessages.map { message in
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
                            
                            // Даем время таблице обновиться
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                                if self.messages.count > 0 {
                                    let lastIndex = IndexPath(row: self.messages.count - 1, section: 0)
                                    
                                    // Сначала прокручиваем к последнему сообщению
                                    self.tableView.scrollToRow(at: lastIndex, at: .bottom, animated: false)
                                    
                                    // Затем устанавливаем фокус и выделение
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
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
                print("MessagesViewController: Ошибка загрузки сообщений: \(error)")
                await MainActor.run {
                    loadingIndicator.stopAnimating()
                    messageLabel.text = "Ошибка при загрузке сообщений: \(error.localizedDescription)"
                }
            }
            
            isLoading = false
        }
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
        cell.configure(with: message)
        return cell
    }
    
    func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        return UITableView.automaticDimension
    }
}

final class MessageCell: UITableViewCell {
    private let messageBubble = UIView()
    private let messageLabel = UILabel()
    private let dateLabel = UILabel()
    private let videoContainer = UIView()
    private var player: AVPlayer?
    private var playerItem: AVPlayerItem?
    private var videoURL: URL?
    private var playerVC: AVPlayerViewController?
    private var isPlayingVideo = false
    
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
            
            videoContainer.heightAnchor.constraint(equalTo: videoContainer.widthAnchor, multiplier: 9/16)
        ])
    }
    
    func configure(with message: TG.Message) {
        messageLabel.text = message.text
        
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        dateLabel.text = formatter.string(from: message.date)
        
        // Обработка видео
        if let media = message.media, case .video(let path) = media {
            videoContainer.isHidden = false
            videoURL = URL(fileURLWithPath: path)
            
            // Проверяем существование файла
            if FileManager.default.fileExists(atPath: path) {
                do {
                    let attrs = try FileManager.default.attributesOfItem(atPath: path)
                    let fileSize = attrs[.size] as? UInt64 ?? 0
                    print("MessageCell: Файл видео существует: \(path), размер: \(fileSize)")
                    prepareVideoPlayer()
                } catch {
                    print("MessageCell: Ошибка при получении атрибутов файла: \(error)")
                    prepareVideoPlayer()
                }
            } else {
                print("MessageCell: Ошибка - видео файл не существует: \(path)")
                // Показываем плейсхолдер или сообщение о необходимости загрузки
                videoContainer.backgroundColor = .darkGray
                
                // Добавляем индикатор загрузки
                let loadingLabel = UILabel()
                loadingLabel.text = "Видео загружается..."
                loadingLabel.textColor = .white
                loadingLabel.translatesAutoresizingMaskIntoConstraints = false
                loadingLabel.textAlignment = .center
                
                videoContainer.subviews.forEach { $0.removeFromSuperview() }
                videoContainer.addSubview(loadingLabel)
                
                NSLayoutConstraint.activate([
                    loadingLabel.centerXAnchor.constraint(equalTo: videoContainer.centerXAnchor),
                    loadingLabel.centerYAnchor.constraint(equalTo: videoContainer.centerYAnchor)
                ])
            }
        } else {
            videoContainer.isHidden = true
            cleanupPlayer()
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
    
    private func prepareVideoPlayer() {
        guard let url = videoURL else { return }
        
        // Используем AVURLAsset вместо устаревшего AVAsset(url:)
        let asset = AVURLAsset(url: url)
        
        // Используем современный API для загрузки метаданных
        Task {
            do {
                // Загружаем необходимые свойства
                _ = try await asset.load(.isPlayable, .duration)
                
                // Проверяем, можно ли воспроизвести видео
                let isPlayable = try await asset.load(.isPlayable)
                
                // Обрабатываем результат в основном потоке
                await MainActor.run {
                    if isPlayable {
                        self.playerItem = AVPlayerItem(asset: asset)
                        self.player = AVPlayer(playerItem: self.playerItem)
                        self.player?.automaticallyWaitsToMinimizeStalling = true
                    } else {
                        print("MessageCell: Видео не может быть воспроизведено")
                    }
                }
            } catch {
                await MainActor.run {
                    print("MessageCell: Ошибка загрузки видео: \(error.localizedDescription)")
                }
            }
        }
    }
    
    private func playVideo() {
        if isPlayingVideo { return }
        
        guard let player = self.player else {
            print("MessageCell: Плеер не инициализирован")
            return
        }
        
        // Создаем и настраиваем AVPlayerViewController
        playerVC = AVPlayerViewController()
        playerVC?.player = player
        
        // Настраиваем представление до показа
        if let playerVC = playerVC {
            playerVC.showsPlaybackControls = true
            
            if let messagesVC = window?.rootViewController?.children.last as? MessagesViewController {
                isPlayingVideo = true
                messagesVC.present(playerVC, animated: true) {
                    player.play()
                }
            }
        }
    }
    
    private func cleanupPlayer() {
        player?.pause()
        player = nil
        playerItem = nil
        videoURL = nil
        playerVC = nil
        isPlayingVideo = false
    }
    
    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        if isFocused {
            messageBubble.transform = CGAffineTransform(scaleX: 1.05, y: 1.05)
            messageBubble.layer.shadowColor = UIColor.white.cgColor
            messageBubble.layer.shadowOpacity = 0.5
            messageBubble.layer.shadowOffset = .zero
            messageBubble.layer.shadowRadius = 5
            
            // При фокусе на сообщении с видео, показываем его в полноэкранном режиме
            if videoURL != nil && player != nil {
                playVideo()
            }
        } else {
            messageBubble.transform = .identity
            messageBubble.layer.shadowOpacity = 0
        }
    }
    
    override func prepareForReuse() {
        super.prepareForReuse()
        cleanupPlayer()
        videoContainer.isHidden = true
    }
} 