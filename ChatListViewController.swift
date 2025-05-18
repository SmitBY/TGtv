import UIKit
import Combine

final class ChatListViewController: UICollectionViewController {
    private let viewModel: ChatListViewModel
    private var cancellables = Set<AnyCancellable>()
    private let loadingIndicator = UIActivityIndicatorView(style: .large)
    private let progressLabel = UILabel()
    private let errorLabel = UILabel()
    
    init(viewModel: ChatListViewModel) {
        self.viewModel = viewModel
        let layout = UICollectionViewFlowLayout()
        // Размеры ячеек лучше настраивать через layout delegate для адаптивности
        // layout.itemSize = CGSize(width: 400, height: 200)
        layout.minimumLineSpacing = 20
        layout.minimumInteritemSpacing = 20
        super.init(collectionViewLayout: layout)
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        setupCollectionView()
        setupLoadingIndicator()
        setupBindings()
        // Начальная загрузка инициируется ViewModel
    }
    
    private func setupCollectionView() {
        collectionView.register(ChatCell.self, forCellWithReuseIdentifier: "ChatCell")
        collectionView.backgroundColor = .black
        collectionView.remembersLastFocusedIndexPath = true
        
        if let layout = collectionViewLayout as? UICollectionViewFlowLayout {
            layout.scrollDirection = .vertical
            layout.sectionInset = UIEdgeInsets(top: 50, left: 50, bottom: 50, right: 50)
            // Настраиваем размер ячеек через делегат для большей гибкости
            // layout.itemSize будет установлено в методе делегата
        }
        collectionView.delegate = self // Устанавливаем делегат для UICollectionViewDelegateFlowLayout
    }
    
    private func setupLoadingIndicator() {
        loadingIndicator.translatesAutoresizingMaskIntoConstraints = false
        loadingIndicator.hidesWhenStopped = true
        loadingIndicator.color = .white
        // loadingIndicator.startAnimating() // ViewModel управляет этим через isLoading
        view.addSubview(loadingIndicator)
        
        progressLabel.translatesAutoresizingMaskIntoConstraints = false
        progressLabel.textColor = .white
        progressLabel.textAlignment = .center
        progressLabel.numberOfLines = 0
        progressLabel.font = .systemFont(ofSize: 22)
        view.addSubview(progressLabel)
        
        errorLabel.translatesAutoresizingMaskIntoConstraints = false
        errorLabel.textColor = .red
        errorLabel.textAlignment = .center
        errorLabel.numberOfLines = 0
        errorLabel.font = .systemFont(ofSize: 22)
        errorLabel.isHidden = true
        view.addSubview(errorLabel)
        
        NSLayoutConstraint.activate([
            loadingIndicator.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            loadingIndicator.centerYAnchor.constraint(equalTo: view.centerYAnchor, constant: -50),
            
            progressLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            progressLabel.topAnchor.constraint(equalTo: loadingIndicator.bottomAnchor, constant: 20),
            progressLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 40),
            progressLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -40),
            
            errorLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            errorLabel.topAnchor.constraint(equalTo: progressLabel.bottomAnchor, constant: 20),
            errorLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 40),
            errorLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -40)
        ])
    }
    
    private func setupBindings() {
        viewModel.$chats
            .receive(on: DispatchQueue.main)
            .sink { [weak self] chats in
                guard let self = self else { return }
                print("ChatListViewController: Получено \(chats.count) чатов для отображения.")
                self.collectionView.reloadData()
                
                if !chats.isEmpty {
                    self.errorLabel.isHidden = true
                }
            }
            .store(in: &cancellables)
        
        viewModel.$isLoading
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isLoading in
                guard let self = self else { return }
                if isLoading && !self.viewModel.isLoadingMore { // Показываем главный индикатор только если не идет дозагрузка
                    self.loadingIndicator.startAnimating()
                    self.progressLabel.isHidden = false // progressLabel для начальной загрузки
                    self.errorLabel.isHidden = true
                } else if !isLoading && !self.viewModel.isLoadingMore {
                    self.loadingIndicator.stopAnimating()
                    self.progressLabel.isHidden = true
                    if self.viewModel.chats.isEmpty && !self.viewModel.canLoadMoreChats { // Если чатов нет и больше не будет
                        self.errorLabel.text = "Нет доступных чатов."
                        self.errorLabel.isHidden = false
                    }
                }
            }
            .store(in: &cancellables)

        // Отдельный биндинг для isLoadingMore, если нужен другой UI (например, маленький спиннер внизу)
        // viewModel.$isLoadingMore
        //     .receive(on: DispatchQueue.main)
        //     .sink { [weak self] isLoadingMore in
        //         // Показать/скрыть индикатор дозагрузки
        //     }
        //     .store(in: &cancellables)
        
        viewModel.$loadingProgress
            .receive(on: DispatchQueue.main)
            .sink { [weak self] progress in
                // Отображаем прогресс только если это не дозагрузка (isLoadingMore == false)
                if !(self?.viewModel.isLoadingMore ?? false) {
                    self?.progressLabel.text = progress
                }
            }
            .store(in: &cancellables)
        
        viewModel.$error
            .receive(on: DispatchQueue.main)
            .sink { [weak self] error in
                guard let self = self, let error = error else { return }
                // Показываем ошибку только если это не ошибка пагинации (или обрабатываем ее иначе)
                if !self.viewModel.isLoadingMore { 
                    self.errorLabel.text = "Ошибка: \(error.localizedDescription). Повторная попытка через 5 сек."
                    self.errorLabel.isHidden = false
                    self.loadingIndicator.stopAnimating()
                    self.progressLabel.isHidden = true
                    
                    DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                        // Повторяем только начальную загрузку при критической ошибке
                        Task { await self.viewModel.loadInitialChats() }
                    }
                }
            }
            .store(in: &cancellables)
    }
    
    // Удаляем viewDidAppear и loadChats(), ViewModel управляет этим
    // override func viewDidAppear(_ animated: Bool) { ... }
    // private func loadChats() { ... }
    
    override func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        let count = viewModel.chats.count
        // print("ChatListViewController: numberOfItemsInSection: \(count)") // Уже логируется в $chats.sink
        return count
    }
    
    override func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "ChatCell", for: indexPath) as! ChatCell
        let chat = viewModel.chats[indexPath.item]
        cell.configure(with: chat)
        return cell
    }
    
    override func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        let chat = viewModel.chats[indexPath.item]
        
        if let appDelegate = UIApplication.shared.delegate as? AppDelegate,
           let existingVC = appDelegate.messagesViewController,
           existingVC.chatId == chat.id {
            print("ChatListViewController: Переходим к уже открытому чату")
            navigationController?.pushViewController(existingVC, animated: true)
            return
        }
        
        let messagesVC = MessagesViewController(chatId: chat.id, client: viewModel.client)
        // Установка messagesViewController в AppDelegate теперь делается внутри MessagesViewController
        navigationController?.pushViewController(messagesVC, animated: true)
    }

    // Пагинация: загрузка следующих чатов при отображении одной из последних ячеек
    override func collectionView(_ collectionView: UICollectionView, willDisplay cell: UICollectionViewCell, forItemAt indexPath: IndexPath) {
        let chatsCount = viewModel.chats.count
        // Загружаем следующую порцию, если это одна из последних 5 ячеек, есть что грузить и не идет уже загрузка
        if indexPath.item >= chatsCount - 5 && viewModel.canLoadMoreChats && !viewModel.isLoadingMore && !viewModel.isLoading {
            print("ChatListViewController: Запрос на дозагрузку чатов...")
            Task {
                await viewModel.loadMoreChats()
            }
        }
    }
    
    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        if let cell = context.nextFocusedView as? ChatCell {
            coordinator.addCoordinatedAnimations {
                cell.transform = CGAffineTransform(scaleX: 1.1, y: 1.1)
            }
        }
        if let cell = context.previouslyFocusedView as? ChatCell {
            coordinator.addCoordinatedAnimations {
                cell.transform = .identity
            }
        }
        
        // Если ошибка видна (не ошибка пагинации) и пользователь нажимает на нее (фокусируется)
        if !errorLabel.isHidden && context.nextFocusedView == errorLabel && !viewModel.isLoadingMore {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                Task { await self.viewModel.loadInitialChats() } // Повторная попытка начальной загрузки
            }
        }
    }
}

// Добавляем UICollectionViewDelegateFlowLayout для управления размерами ячеек
extension ChatListViewController: UICollectionViewDelegateFlowLayout {
    func collectionView(_ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout, sizeForItemAt indexPath: IndexPath) -> CGSize {
        // Например, 2 ячейки в ряд с отступами
        let padding: CGFloat = 50 // отступы секции (лево/право)
        let interitemSpacing: CGFloat = 20 // минимальный отступ между ячейками
        let availableWidth = collectionView.bounds.width - (padding * 2) - interitemSpacing
        let itemWidth = availableWidth / 2
        return CGSize(width: itemWidth, height: 200) // Высота фиксированная или также можно вычислять
    }
}


final class ChatCell: UICollectionViewCell {
    private let titleLabel = UILabel()
    private let messageLabel = UILabel()
    
    override init(frame: CGRect) {
        super.init(frame: frame)
        setupUI()
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    private func setupUI() {
        backgroundColor = .darkGray
        layer.cornerRadius = 10
        
        titleLabel.textColor = .white
        titleLabel.font = .systemFont(ofSize: 24, weight: .bold)
        titleLabel.numberOfLines = 1 // Ограничим одной строкой для заголовка
        titleLabel.lineBreakMode = .byTruncatingTail
        
        messageLabel.textColor = .lightGray
        messageLabel.font = .systemFont(ofSize: 18)
        messageLabel.numberOfLines = 2 // Ограничим двумя строками для сообщения
        messageLabel.lineBreakMode = .byTruncatingTail
        
        let stack = UIStackView(arrangedSubviews: [titleLabel, messageLabel])
        stack.axis = .vertical
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        
        contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            // stack.centerYAnchor.constraint(equalTo: contentView.centerYAnchor) // Лучше привязать к top/bottom или задать отступы
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor, constant: -16) // Чтобы текст не вылезал
        ])
    }
    
    func configure(with chat: TG.Chat) {
        titleLabel.text = chat.title
        messageLabel.text = chat.lastMessage
    }
} 