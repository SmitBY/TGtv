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
        setupCollectionView()
        setupLoadingIndicator()
        setupBindings()
    }
    
    private func setupCollectionView() {
        collectionView.register(ChatCell.self, forCellWithReuseIdentifier: "ChatCell")
        collectionView.backgroundColor = .black
        
        // Настройка для tvOS
        collectionView.remembersLastFocusedIndexPath = true
        
        if let layout = collectionViewLayout as? UICollectionViewFlowLayout {
            layout.scrollDirection = .vertical
            layout.sectionInset = UIEdgeInsets(top: 50, left: 50, bottom: 50, right: 50)
        }
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
    
    private func setupBindings() {
        viewModel.$chats
            .receive(on: DispatchQueue.main)
            .sink { [weak self] chats in
                guard let self = self else { return }
                print("ChatListViewController: Получено \(chats.count) чатов")
                self.collectionView.reloadData()
                
                if chats.isEmpty && !self.viewModel.isLoading {
                    self.errorLabel.text = "Нет доступных чатов"
                    self.errorLabel.isHidden = false
                } else if !chats.isEmpty {
                    self.errorLabel.isHidden = true
                }
            }
            .store(in: &cancellables)
        
        viewModel.$isLoading
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isLoading in
                guard let self = self else { return }
                if isLoading {
                    self.loadingIndicator.startAnimating()
                    self.progressLabel.isHidden = false
                } else {
                    self.loadingIndicator.stopAnimating()
                    self.progressLabel.isHidden = true
                    
                    // Если после загрузки список пуст, показываем кнопку повтора
                    if self.viewModel.chats.isEmpty {
                        self.errorLabel.text = "Нет доступных чатов. Нажмите OK для повторной загрузки."
                        self.errorLabel.isHidden = false
                    }
                }
            }
            .store(in: &cancellables)
        
        viewModel.$loadingProgress
            .receive(on: DispatchQueue.main)
            .sink { [weak self] progress in
                self?.progressLabel.text = progress
            }
            .store(in: &cancellables)
        
        viewModel.$error
            .receive(on: DispatchQueue.main)
            .sink { [weak self] error in
                guard let self = self, let error = error else { return }
                self.errorLabel.text = "Ошибка: \(error.localizedDescription)"
                self.errorLabel.isHidden = false
                
                // Автоматически пробуем еще раз через 5 секунд
                DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                    self.loadChats()
                }
            }
            .store(in: &cancellables)
    }
    
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if viewModel.chats.isEmpty {
            loadChats()
        }
    }
    
    private func loadChats() {
        Task {
            try? await viewModel.loadChats()
        }
    }
    
    override func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        let count = viewModel.chats.count
        print("ChatListViewController: numberOfItemsInSection: \(count)")
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