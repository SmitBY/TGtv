import UIKit
import Combine

final class ChatListViewController: UICollectionViewController {
    // Определяем тип секции для DiffableDataSource
    enum Section: CaseIterable {
        case main
    }
    
    private let viewModel: ChatListViewModel
    private var cancellables = Set<AnyCancellable>()
    private let loadingIndicator = UIActivityIndicatorView(style: .large)
    private let progressLabel = UILabel()
    private let errorLabel = UILabel()
    private let searchContainer = UIVisualEffectView(effect: UIBlurEffect(style: .dark))
    private let searchField = UITextField()
    
    // Свойство для DiffableDataSource
    private var dataSource: UICollectionViewDiffableDataSource<Section, TG.Chat>!
    
    init(viewModel: ChatListViewModel) {
        self.viewModel = viewModel
        let layout = UICollectionViewFlowLayout()
        layout.itemSize = CGSize(width: 400, height: 200)
        layout.minimumLineSpacing = 20
        layout.minimumInteritemSpacing = 20
        super.init(collectionViewLayout: layout)
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        setupSearchBar()
        setupCollectionView()
        setupLoadingIndicator()
        configureDataSource() // Настраиваем DiffableDataSource
        setupBindings()
    }
    
    private func setupCollectionView() {
        collectionView.register(ChatCell.self, forCellWithReuseIdentifier: "ChatCell")
        collectionView.backgroundColor = .black
        collectionView.contentInset.top = 140
        collectionView.scrollIndicatorInsets = collectionView.contentInset
        
        // Настройка для tvOS
        collectionView.remembersLastFocusedIndexPath = true
        
        if let layout = collectionViewLayout as? UICollectionViewFlowLayout {
            layout.scrollDirection = .vertical
            layout.sectionInset = UIEdgeInsets(top: 50, left: 50, bottom: 50, right: 50)
        }
    }
    
    private func setupSearchBar() {
        searchContainer.translatesAutoresizingMaskIntoConstraints = false
        searchContainer.layer.cornerRadius = 20
        searchContainer.clipsToBounds = true
        view.addSubview(searchContainer)
        
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.delegate = self
        searchField.placeholder = "Поиск"
        searchField.textColor = .white
        searchField.font = .systemFont(ofSize: 28, weight: .regular)
        searchField.autocapitalizationType = .none
        searchField.autocorrectionType = .no
        searchField.returnKeyType = .search
        searchField.clearButtonMode = .whileEditing
        searchField.backgroundColor = UIColor(white: 1, alpha: 0.08)
        searchField.layer.cornerRadius = 16
        searchField.layer.masksToBounds = true
        let paddingView = UIView(frame: CGRect(x: 0, y: 0, width: 16, height: 50))
        searchField.leftView = paddingView
        searchField.leftViewMode = .always
        searchField.addTarget(self, action: #selector(searchTextDidChange(_:)), for: .editingChanged)
        searchContainer.contentView.addSubview(searchField)
        
        NSLayoutConstraint.activate([
            searchContainer.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 16),
            searchContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 80),
            searchContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -80),
            searchContainer.heightAnchor.constraint(equalToConstant: 80),
            
            searchField.leadingAnchor.constraint(equalTo: searchContainer.leadingAnchor, constant: 0),
            searchField.trailingAnchor.constraint(equalTo: searchContainer.trailingAnchor, constant: 0),
            searchField.topAnchor.constraint(equalTo: searchContainer.topAnchor),
            searchField.bottomAnchor.constraint(equalTo: searchContainer.bottomAnchor)
        ])
    }
    
    private func setupLoadingIndicator() {
        loadingIndicator.translatesAutoresizingMaskIntoConstraints = false
        loadingIndicator.hidesWhenStopped = true
        loadingIndicator.color = .white
        loadingIndicator.startAnimating()
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
    
    private func configureDataSource() {
        dataSource = UICollectionViewDiffableDataSource<Section, TG.Chat>(collectionView: collectionView) { (collectionView, indexPath, chat) -> UICollectionViewCell? in
            let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "ChatCell", for: indexPath) as! ChatCell
            cell.configure(with: chat)
            return cell
        }
        // Применяем начальный пустой снимок, чтобы dataSource был готов
        var initialSnapshot = NSDiffableDataSourceSnapshot<Section, TG.Chat>()
        initialSnapshot.appendSections([.main])
        initialSnapshot.appendItems([])
        dataSource.apply(initialSnapshot, animatingDifferences: false)
    }
    
    private func setupBindings() {
        viewModel.$filteredChats
            .receive(on: DispatchQueue.main)
            .sink { [weak self] chats in
                guard let self = self else { return }
                print("ChatListViewController: Получено \(chats.count) чатов для DiffableDataSource")
                
                var snapshot = NSDiffableDataSourceSnapshot<Section, TG.Chat>()
                snapshot.appendSections([.main])
                snapshot.appendItems(chats, toSection: .main)
                self.dataSource.apply(snapshot, animatingDifferences: true) // Можно настроить анимацию
                self.updateEmptyState(for: chats)
            }
            .store(in: &cancellables)
        
        viewModel.$isLoading
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isLoading in
                guard let self = self else { return }
                if isLoading {
                    self.loadingIndicator.startAnimating()
                    self.progressLabel.isHidden = false
                    self.errorLabel.isHidden = true
                } else {
                    self.loadingIndicator.stopAnimating()
                    self.progressLabel.isHidden = true
                    
                    self.updateEmptyState(for: self.viewModel.filteredChats)
                }
            }
            .store(in: &cancellables)
        
        viewModel.$loadingProgress
            .receive(on: DispatchQueue.main)
            .sink { [weak self] progress in
                guard let self = self else { return }
                self.progressLabel.text = progress
                
                // Если прогресс загрузки пустой, скрываем метку
                if progress.isEmpty {
                    self.progressLabel.isHidden = true
                    // Также останавливаем индикатор, если он все еще анимирует
                    if self.loadingIndicator.isAnimating {
                        self.loadingIndicator.stopAnimating()
                    }
                }
            }
            .store(in: &cancellables)
        
        viewModel.$error
            .receive(on: DispatchQueue.main)
            .sink { [weak self] error in
                guard let self = self, let error = error else { return }
                self.errorLabel.text = "Ошибка: \(error.localizedDescription)"
                self.errorLabel.isHidden = false
                
                // Останавливаем индикатор загрузки при ошибке
                self.loadingIndicator.stopAnimating()
                self.progressLabel.isHidden = true
                
                // Автоматически пробуем еще раз через 5 секунд
                DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                    self.loadChats()
                }
            }
            .store(in: &cancellables)
    }
    
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // Загружаем чаты только если они еще не загружены и не загружаются
        if viewModel.chats.isEmpty && !viewModel.isLoading {
            print("ChatListViewController: Запуск загрузки чатов из viewDidAppear")
            loadChats()
        } else if !viewModel.chats.isEmpty {
            print("ChatListViewController: Чаты уже загружены, пропускаем повторную загрузку")
            // Убедимся, что индикатор загрузки скрыт
            loadingIndicator.stopAnimating()
            progressLabel.isHidden = true
        } else if viewModel.isLoading {
            print("ChatListViewController: Загрузка чатов уже идет, ожидаем")
        }
    }
    
    private func updateEmptyState(for chats: [TG.Chat]) {
        if !chats.isEmpty {
            errorLabel.isHidden = true
            if loadingIndicator.isAnimating {
                loadingIndicator.stopAnimating()
            }
            progressLabel.isHidden = true
            return
        }
        
        if !viewModel.searchQuery.isEmpty {
            errorLabel.text = "Ничего не найдено"
            errorLabel.textColor = .lightGray
            errorLabel.isHidden = false
            loadingIndicator.stopAnimating()
            progressLabel.isHidden = true
        } else if !viewModel.isLoading && viewModel.chats.isEmpty {
            errorLabel.text = "Нет доступных чатов. Нажмите OK для повторной загрузки."
            errorLabel.textColor = .red
            errorLabel.isHidden = false
        } else {
            errorLabel.isHidden = true
        }
    }
    
    private func loadChats() {
        Task {
            try? await viewModel.loadChats()
        }
    }
    
    override func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        // Получаем элемент из dataSource, а не из viewModel.chats напрямую, на случай если они рассинхронизированы
        // (хотя при правильном использовании DiffableDataSource они должны быть синхронны)
        guard let chat = dataSource.itemIdentifier(for: indexPath) else {
            print("ChatListViewController: Не удалось получить чат для indexPath \(indexPath) из dataSource")
            return
        }
        
        // Проверяем, есть ли уже открытый MessagesViewController
        if let appDelegate = UIApplication.shared.delegate as? AppDelegate,
           let existingVC = appDelegate.messagesViewController,
           existingVC.chatId == chat.id {
            print("ChatListViewController: Переходим к уже открытому чату")
            navigationController?.pushViewController(existingVC, animated: true)
            return
        }
        
        let messagesVC = MessagesViewController(chatId: chat.id, client: viewModel.client)
        if let appDelegate = UIApplication.shared.delegate as? AppDelegate {
            appDelegate.setMessagesViewController(messagesVC)
        }
        navigationController?.pushViewController(messagesVC, animated: true)
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
        
        // Если ошибка видна и пользователь нажимает OK, пробуем загрузить чаты снова
        if !errorLabel.isHidden && context.nextFocusedView == errorLabel {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                self.loadChats()
            }
        }
    }
    
    @objc private func searchTextDidChange(_ sender: UITextField) {
        Task { @MainActor [weak self] in
            self?.viewModel.updateSearchQuery(sender.text ?? "")
        }
    }
    
    private func closeKeyboard() {
        searchField.resignFirstResponder()
    }
}

extension ChatListViewController: UITextFieldDelegate {
    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        closeKeyboard()
        return true
    }
    
    func textFieldShouldClear(_ textField: UITextField) -> Bool {
        Task { @MainActor [weak self] in
            self?.viewModel.updateSearchQuery("")
        }
        return true
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
        
        messageLabel.textColor = .lightGray
        messageLabel.font = .systemFont(ofSize: 18)
        
        let stack = UIStackView(arrangedSubviews: [titleLabel, messageLabel])
        stack.axis = .vertical
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        
        contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            stack.centerYAnchor.constraint(equalTo: contentView.centerYAnchor)
        ])
    }
    
    func configure(with chat: TG.Chat) {
        titleLabel.text = chat.title
        messageLabel.text = chat.lastMessage
    }
} 