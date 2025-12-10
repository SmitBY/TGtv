import UIKit
import Combine

final class ChatListViewController: UICollectionViewController {
    enum Section: CaseIterable {
        case main
    }
    
    private let viewModel: ChatListViewModel
    private let onSaveSelection: ((Set<Int64>) -> Void)?
    private var selectedChatIds: Set<Int64>
    private var cancellables = Set<AnyCancellable>()
    private let loadingIndicator = UIActivityIndicatorView(style: .large)
    private let progressLabel = UILabel()
    private let errorLabel = UILabel()
    private let searchContainer = UIVisualEffectView(effect: UIBlurEffect(style: .dark))
    private let searchField = UITextField()
    private let settingsButton = UIButton(type: .system)
    private let selectionStatusLabel = UILabel()
    private let saveButton = UIButton(type: .system)
    private let searchBackgroundNormal = UIColor(white: 0.12, alpha: 0.9)
    private let searchBackgroundFocused = UIColor(white: 0.2, alpha: 0.95)
    private let settingsFocusedBackground = UIColor(white: 1, alpha: 0.14)
    private var dataSource: UICollectionViewDiffableDataSource<Section, TG.Chat>!
    
    // tvOS safe area insets (Apple HIG: 60pt top/bottom, 80pt sides)
    private let tvSafeInsets = UIEdgeInsets(top: 60, left: 80, bottom: 60, right: 80)
    
    init(viewModel: ChatListViewModel, selectedChats: Set<Int64> = [], onSaveSelection: ((Set<Int64>) -> Void)? = nil) {
        self.viewModel = viewModel
        self.selectedChatIds = selectedChats
        self.onSaveSelection = onSaveSelection
        super.init(collectionViewLayout: Self.createLayout())
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    private static func createLayout() -> UICollectionViewCompositionalLayout {
        let itemSize = NSCollectionLayoutSize(
            widthDimension: .fractionalWidth(1/3),
            heightDimension: .estimated(220)
        )
        let item = NSCollectionLayoutItem(layoutSize: itemSize)
        
        let groupSize = NSCollectionLayoutSize(
            widthDimension: .fractionalWidth(1.0),
            heightDimension: .estimated(220)
        )
        let group = NSCollectionLayoutGroup.horizontal(layoutSize: groupSize, subitems: [item])
        group.interItemSpacing = .fixed(40)
        
        let section = NSCollectionLayoutSection(group: group)
        section.interGroupSpacing = 50
        section.contentInsets = NSDirectionalEdgeInsets(top: 40, leading: 80, bottom: 60, trailing: 80)
        
        return UICollectionViewCompositionalLayout(section: section)
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        setupBackground()
        setupSearchBar()
        setupCollectionView()
        setupLoadingIndicator()
        configureDataSource()
        setupBindings()
    }
    
    private func setupBackground() {
        // Gradient background
        let gradient = CAGradientLayer()
        gradient.colors = [
            UIColor(red: 0.08, green: 0.08, blue: 0.12, alpha: 1).cgColor,
            UIColor(red: 0.04, green: 0.04, blue: 0.08, alpha: 1).cgColor
        ]
        gradient.locations = [0, 1]
        gradient.frame = view.bounds
        view.layer.insertSublayer(gradient, at: 0)
    }
    
    private func setupCollectionView() {
        collectionView.register(ChatCell.self, forCellWithReuseIdentifier: "ChatCell")
        collectionView.backgroundColor = .clear
        collectionView.contentInset.top = 120
        collectionView.scrollIndicatorInsets = collectionView.contentInset
        collectionView.remembersLastFocusedIndexPath = true
        collectionView.clipsToBounds = false
        
        if onSaveSelection != nil {
            navigationItem.title = "Выбор чатов"
        } else {
            navigationItem.title = "Список чатов"
        }
    }
    
    private func setupSearchBar() {
        searchContainer.translatesAutoresizingMaskIntoConstraints = false
        searchContainer.layer.cornerRadius = 18
        searchContainer.clipsToBounds = true
        searchContainer.backgroundColor = searchBackgroundNormal
        searchContainer.contentView.backgroundColor = .clear
        view.addSubview(searchContainer)
        
        let searchIcon = UIImageView(image: UIImage(systemName: "magnifyingglass"))
        searchIcon.tintColor = UIColor(white: 0.6, alpha: 1)
        searchIcon.translatesAutoresizingMaskIntoConstraints = false
        searchIcon.contentMode = .scaleAspectFit
        
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.delegate = self
        searchField.placeholder = "Поиск чатов"
        searchField.textColor = .white
        searchField.font = .systemFont(ofSize: 32, weight: .regular)
        searchField.autocapitalizationType = .none
        searchField.autocorrectionType = .no
        searchField.returnKeyType = .search
        searchField.clearButtonMode = .whileEditing
        searchField.backgroundColor = .clear
        searchField.addTarget(self, action: #selector(searchTextDidChange(_:)), for: .editingChanged)
        searchField.tintColor = .systemBlue
        searchField.attributedPlaceholder = NSAttributedString(
            string: "Поиск чатов",
            attributes: [.foregroundColor: UIColor(white: 0.6, alpha: 1)]
        )
        
        settingsButton.translatesAutoresizingMaskIntoConstraints = false
        settingsButton.setTitle("Настройки", for: .normal)
        settingsButton.titleLabel?.font = .systemFont(ofSize: 28, weight: .semibold)
        settingsButton.setTitleColor(.white, for: .normal)
        settingsButton.setTitleColor(.white, for: .focused)
        settingsButton.addTarget(self, action: #selector(openSettings), for: .primaryActionTriggered)
        if #available(tvOS 15.0, *) {
            var settingsConfig = settingsButton.configuration ?? UIButton.Configuration.plain()
            settingsConfig.title = settingsConfig.title ?? settingsButton.title(for: .normal) ?? "Настройки"
            settingsConfig.baseForegroundColor = settingsButton.titleColor(for: .normal)
            settingsConfig.contentInsets = NSDirectionalEdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16)
            settingsConfig.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
                var outgoing = incoming
                outgoing.font = .systemFont(ofSize: 28, weight: .semibold)
                return outgoing
            }
            settingsButton.configuration = settingsConfig
        } else {
            settingsButton.contentEdgeInsets = UIEdgeInsets(top: 12, left: 16, bottom: 12, right: 16)
        }
        
        searchContainer.contentView.addSubview(searchIcon)
        searchContainer.contentView.addSubview(searchField)
        searchContainer.contentView.addSubview(settingsButton)
        
        NSLayoutConstraint.activate([
            searchContainer.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 20),
            searchContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: tvSafeInsets.left),
            searchContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -tvSafeInsets.right),
            searchContainer.heightAnchor.constraint(equalToConstant: 70),
            
            searchIcon.leadingAnchor.constraint(equalTo: searchContainer.leadingAnchor, constant: 24),
            searchIcon.centerYAnchor.constraint(equalTo: searchContainer.centerYAnchor),
            searchIcon.widthAnchor.constraint(equalToConstant: 32),
            searchIcon.heightAnchor.constraint(equalToConstant: 32),
            
            searchField.leadingAnchor.constraint(equalTo: searchIcon.trailingAnchor, constant: 16),
            searchField.trailingAnchor.constraint(equalTo: settingsButton.leadingAnchor, constant: -24),
            searchField.topAnchor.constraint(equalTo: searchContainer.topAnchor),
            searchField.bottomAnchor.constraint(equalTo: searchContainer.bottomAnchor),

            settingsButton.trailingAnchor.constraint(equalTo: searchContainer.trailingAnchor, constant: -24),
            settingsButton.centerYAnchor.constraint(equalTo: searchContainer.centerYAnchor)
        ])
        
        setupSelectionControls()
    }
    
    private func setupSelectionControls() {
        guard onSaveSelection != nil else { return }
        
        selectionStatusLabel.translatesAutoresizingMaskIntoConstraints = false
        selectionStatusLabel.textColor = .white
        selectionStatusLabel.font = .systemFont(ofSize: 24, weight: .medium)
        selectionStatusLabel.textAlignment = .left
        selectionStatusLabel.text = "Не выбрано"
        view.addSubview(selectionStatusLabel)
        
        saveButton.translatesAutoresizingMaskIntoConstraints = false
        saveButton.setTitle("Сохранить", for: .normal)
        saveButton.titleLabel?.font = .systemFont(ofSize: 26, weight: .semibold)
        saveButton.setTitleColor(.white, for: .normal)
        saveButton.setTitleColor(UIColor(white: 1, alpha: 0.5), for: .disabled)
        saveButton.backgroundColor = UIColor.systemBlue.withAlphaComponent(0.8)
        saveButton.layer.cornerRadius = 12
        if #available(tvOS 15.0, *) {
            var saveConfig = saveButton.configuration ?? UIButton.Configuration.plain()
            saveConfig.title = saveConfig.title ?? saveButton.title(for: .normal) ?? "Сохранить"
            saveConfig.baseForegroundColor = saveButton.titleColor(for: .normal)
            saveConfig.contentInsets = NSDirectionalEdgeInsets(top: 14, leading: 24, bottom: 14, trailing: 24)
            saveConfig.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
                var outgoing = incoming
                outgoing.font = .systemFont(ofSize: 26, weight: .semibold)
                return outgoing
            }
            saveButton.configuration = saveConfig
        } else {
            saveButton.contentEdgeInsets = UIEdgeInsets(top: 14, left: 24, bottom: 14, right: 24)
        }
        saveButton.addTarget(self, action: #selector(saveSelection), for: .primaryActionTriggered)
        view.addSubview(saveButton)
        
        NSLayoutConstraint.activate([
            selectionStatusLabel.topAnchor.constraint(equalTo: searchContainer.bottomAnchor, constant: 16),
            selectionStatusLabel.leadingAnchor.constraint(equalTo: searchContainer.leadingAnchor),
            
            saveButton.centerYAnchor.constraint(equalTo: selectionStatusLabel.centerYAnchor),
            saveButton.trailingAnchor.constraint(equalTo: searchContainer.trailingAnchor),
        ])
        
        updateSelectionUI()
    }
    
    private func setupLoadingIndicator() {
        loadingIndicator.translatesAutoresizingMaskIntoConstraints = false
        loadingIndicator.hidesWhenStopped = true
        loadingIndicator.color = .white
        loadingIndicator.startAnimating()
        view.addSubview(loadingIndicator)
        
        progressLabel.translatesAutoresizingMaskIntoConstraints = false
        progressLabel.textColor = UIColor(white: 0.7, alpha: 1)
        progressLabel.textAlignment = .center
        progressLabel.numberOfLines = 0
        progressLabel.font = .systemFont(ofSize: 28, weight: .medium)
        view.addSubview(progressLabel)
        
        errorLabel.translatesAutoresizingMaskIntoConstraints = false
        errorLabel.textColor = UIColor(red: 1, green: 0.4, blue: 0.4, alpha: 1)
        errorLabel.textAlignment = .center
        errorLabel.numberOfLines = 0
        errorLabel.font = .systemFont(ofSize: 24, weight: .regular)
        errorLabel.isHidden = true
        view.addSubview(errorLabel)
        
        NSLayoutConstraint.activate([
            loadingIndicator.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            loadingIndicator.centerYAnchor.constraint(equalTo: view.centerYAnchor, constant: -40),
            
            progressLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            progressLabel.topAnchor.constraint(equalTo: loadingIndicator.bottomAnchor, constant: 24),
            progressLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: tvSafeInsets.left),
            progressLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -tvSafeInsets.right),
            
            errorLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            errorLabel.topAnchor.constraint(equalTo: progressLabel.bottomAnchor, constant: 16),
            errorLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: tvSafeInsets.left),
            errorLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -tvSafeInsets.right)
        ])
    }
    
    private func configureDataSource() {
        dataSource = UICollectionViewDiffableDataSource<Section, TG.Chat>(collectionView: collectionView) { [weak self] collectionView, indexPath, chat in
            let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "ChatCell", for: indexPath) as! ChatCell
            let isSelected = self?.selectedChatIds.contains(chat.id) ?? false
            cell.configure(with: chat, selected: isSelected)
            return cell
        }
        
        var initialSnapshot = NSDiffableDataSourceSnapshot<Section, TG.Chat>()
        initialSnapshot.appendSections([.main])
        initialSnapshot.appendItems([])
        dataSource.apply(initialSnapshot, animatingDifferences: false)
    }
    
    private func setupBindings() {
        viewModel.$filteredChats
            .receive(on: DispatchQueue.main)
            .sink { [weak self] chats in
                guard let self else { return }
                var snapshot = NSDiffableDataSourceSnapshot<Section, TG.Chat>()
                snapshot.appendSections([.main])
                snapshot.appendItems(chats, toSection: .main)
                self.dataSource.apply(snapshot, animatingDifferences: true)
                self.updateEmptyState(for: chats)
            }
            .store(in: &cancellables)
        
        viewModel.$isLoading
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isLoading in
                guard let self else { return }
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
                guard let self else { return }
                self.progressLabel.text = progress
                if progress.isEmpty {
                    self.progressLabel.isHidden = true
                    if self.loadingIndicator.isAnimating {
                        self.loadingIndicator.stopAnimating()
                    }
                }
            }
            .store(in: &cancellables)
        
        viewModel.$error
            .receive(on: DispatchQueue.main)
            .sink { [weak self] error in
                guard let self, let error else { return }
                self.errorLabel.text = "Ошибка: \(error.localizedDescription)"
                self.errorLabel.isHidden = false
                self.loadingIndicator.stopAnimating()
                self.progressLabel.isHidden = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                    self.loadChats()
                }
            }
            .store(in: &cancellables)
    }
    
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if viewModel.chats.isEmpty && !viewModel.isLoading {
            loadChats()
        } else if !viewModel.chats.isEmpty {
            loadingIndicator.stopAnimating()
            progressLabel.isHidden = true
        }
    }
    
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        if let gradient = view.layer.sublayers?.first as? CAGradientLayer {
            gradient.frame = view.bounds
        }
    }
    
    private func updateEmptyState(for chats: [TG.Chat]) {
        if !chats.isEmpty {
            errorLabel.isHidden = true
            if loadingIndicator.isAnimating { loadingIndicator.stopAnimating() }
            progressLabel.isHidden = true
            return
        }
        
        if !viewModel.searchQuery.isEmpty {
            errorLabel.text = "Ничего не найдено"
            errorLabel.textColor = UIColor(white: 0.5, alpha: 1)
            errorLabel.isHidden = false
            loadingIndicator.stopAnimating()
            progressLabel.isHidden = true
        } else if !viewModel.isLoading && viewModel.chats.isEmpty {
            errorLabel.text = "Нет доступных чатов"
            errorLabel.textColor = UIColor(red: 1, green: 0.4, blue: 0.4, alpha: 1)
            errorLabel.isHidden = false
        } else {
            errorLabel.isHidden = true
        }
    }
    
    private func loadChats() {
        Task { try? await viewModel.loadChats() }
    }
    
    override func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        guard let chat = dataSource.itemIdentifier(for: indexPath) else { return }
        if selectedChatIds.contains(chat.id) {
            selectedChatIds.remove(chat.id)
        } else {
            selectedChatIds.insert(chat.id)
        }
        refreshSelectionMarks(for: [chat.id])
        updateSelectionUI()
    }
    
    @objc private func searchTextDidChange(_ sender: UITextField) {
        Task { @MainActor [weak self] in
            self?.viewModel.updateSearchQuery(sender.text ?? "")
        }
    }

    @objc private func openSettings() {
        (UIApplication.shared.delegate as? AppDelegate)?.openSettings()
    }
    
    @objc private func saveSelection() {
        onSaveSelection?(selectedChatIds)
    }
    
    private func applyCurrentSnapshot(animated: Bool) {
        var snapshot = NSDiffableDataSourceSnapshot<Section, TG.Chat>()
        snapshot.appendSections([.main])
        snapshot.appendItems(viewModel.filteredChats, toSection: .main)
        dataSource.apply(snapshot, animatingDifferences: animated)
        updateEmptyState(for: viewModel.filteredChats)
    }
    
    private func refreshSelectionMarks(for chatIds: [Int64]? = nil) {
        var snapshot = dataSource.snapshot()
        let idsToUpdate = Set(chatIds ?? snapshot.itemIdentifiers.map(\.id))
        let chatsToUpdate = snapshot.itemIdentifiers.filter { idsToUpdate.contains($0.id) }
        guard !chatsToUpdate.isEmpty else { return }
        
        if #available(tvOS 15.0, *) {
            snapshot.reconfigureItems(chatsToUpdate)
        } else {
            snapshot.reloadItems(chatsToUpdate)
        }
        
        dataSource.apply(snapshot, animatingDifferences: false)
    }
    
    private func updateSelectionUI() {
        guard onSaveSelection != nil else { return }
        let count = selectedChatIds.count
        selectionStatusLabel.text = count == 0 ? "Не выбрано" : "Выбрано: \(count)"
        saveButton.isEnabled = count > 0
        saveButton.alpha = count > 0 ? 1.0 : 0.5
    }

    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)

        let next = context.nextFocusedView
        let prev = context.previouslyFocusedView

        if next === searchField {
            updateSearchFocus(isFocused: true)
        } else if prev === searchField {
            updateSearchFocus(isFocused: false)
        }

        if next === settingsButton {
            updateSettingsFocus(isFocused: true)
        } else if prev === settingsButton {
            updateSettingsFocus(isFocused: false)
        }
    }

    private func updateSearchFocus(isFocused: Bool) {
        UIView.animate(withDuration: 0.15) {
            self.searchContainer.backgroundColor = isFocused ? self.searchBackgroundFocused : self.searchBackgroundNormal
            self.searchContainer.layer.borderWidth = isFocused ? 2 : 0
            self.searchContainer.layer.borderColor = isFocused ? UIColor.systemBlue.cgColor : UIColor.clear.cgColor
        }
    }

    private func updateSettingsFocus(isFocused: Bool) {
        UIView.animate(withDuration: 0.15) {
            self.settingsButton.backgroundColor = isFocused ? self.settingsFocusedBackground : .clear
            self.settingsButton.layer.cornerRadius = 12
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

// MARK: - ChatCell with tvOS Focus & Parallax

final class ChatCell: UICollectionViewCell {
    private let containerView = UIView()
    private let titleLabel = UILabel()
    private let messageLabel = UILabel()
    private let avatarView = UIView()
    private let avatarLabel = UILabel()
    private var gradientLayer: CAGradientLayer?
    
    override init(frame: CGRect) {
        super.init(frame: frame)
        setupUI()
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    private func setupUI() {
        clipsToBounds = false
        contentView.clipsToBounds = false
        
        // Container with shadow
        containerView.translatesAutoresizingMaskIntoConstraints = false
        containerView.layer.cornerRadius = 20
        containerView.clipsToBounds = true
        contentView.addSubview(containerView)
        
        // Gradient background
        let gradient = CAGradientLayer()
        gradient.colors = [
            UIColor(red: 0.18, green: 0.18, blue: 0.22, alpha: 1).cgColor,
            UIColor(red: 0.12, green: 0.12, blue: 0.16, alpha: 1).cgColor
        ]
        gradient.locations = [0, 1]
        gradient.cornerRadius = 20
        containerView.layer.insertSublayer(gradient, at: 0)
        gradientLayer = gradient
        
        // Avatar circle
        avatarView.translatesAutoresizingMaskIntoConstraints = false
        avatarView.backgroundColor = UIColor(red: 0.3, green: 0.5, blue: 0.9, alpha: 1)
        avatarView.layer.cornerRadius = 32
        containerView.addSubview(avatarView)
        
        avatarLabel.translatesAutoresizingMaskIntoConstraints = false
        avatarLabel.textColor = .white
        avatarLabel.font = .systemFont(ofSize: 28, weight: .semibold)
        avatarLabel.textAlignment = .center
        avatarView.addSubview(avatarLabel)
        
        // Title
        titleLabel.textColor = .white
        titleLabel.font = .systemFont(ofSize: 28, weight: .bold)
        titleLabel.numberOfLines = 2
        titleLabel.lineBreakMode = .byTruncatingTail
        
        // Message preview
        messageLabel.textColor = UIColor(white: 0.6, alpha: 1)
        messageLabel.font = .systemFont(ofSize: 22, weight: .regular)
        messageLabel.numberOfLines = 2
        messageLabel.lineBreakMode = .byTruncatingTail
        messageLabel.isHidden = true
        
        let textStack = UIStackView(arrangedSubviews: [titleLabel, messageLabel])
        textStack.axis = .vertical
        textStack.spacing = 8
        textStack.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(textStack)
        
        NSLayoutConstraint.activate([
            containerView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 10),
            containerView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 10),
            containerView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -10),
            containerView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -10),
            
            avatarView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 20),
            avatarView.topAnchor.constraint(equalTo: containerView.topAnchor, constant: 20),
            avatarView.widthAnchor.constraint(equalToConstant: 64),
            avatarView.heightAnchor.constraint(equalToConstant: 64),
            
            avatarLabel.centerXAnchor.constraint(equalTo: avatarView.centerXAnchor),
            avatarLabel.centerYAnchor.constraint(equalTo: avatarView.centerYAnchor),
            
            textStack.leadingAnchor.constraint(equalTo: avatarView.trailingAnchor, constant: 16),
            textStack.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -20),
            textStack.topAnchor.constraint(equalTo: containerView.topAnchor, constant: 24),
            textStack.bottomAnchor.constraint(lessThanOrEqualTo: containerView.bottomAnchor, constant: -24)
        ])
    }
    
    override func layoutSubviews() {
        super.layoutSubviews()
        gradientLayer?.frame = containerView.bounds
    }
    
    func configure(with chat: TG.Chat, selected: Bool) {
        titleLabel.text = chat.title
        messageLabel.isHidden = true
        messageLabel.text = nil
        
        let initials = chat.title.prefix(2).uppercased()
        avatarLabel.text = String(initials)
        
        let hue = CGFloat(abs(chat.id.hashValue) % 360) / 360.0
        avatarView.backgroundColor = UIColor(hue: hue, saturation: 0.5, brightness: 0.7, alpha: 1)
        
        updateSelection(selected)
    }
    
    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        
        coordinator.addCoordinatedAnimations {
            if self.isFocused {
                // Scale up with parallax-like shadow
                self.containerView.transform = CGAffineTransform(scaleX: 1.08, y: 1.08)
                self.containerView.layer.shadowColor = UIColor.white.cgColor
                self.containerView.layer.shadowOpacity = 0.3
                self.containerView.layer.shadowOffset = CGSize(width: 0, height: 15)
                self.containerView.layer.shadowRadius = 20
                
                // Lighten gradient
                self.gradientLayer?.colors = [
                    UIColor(red: 0.25, green: 0.25, blue: 0.32, alpha: 1).cgColor,
                    UIColor(red: 0.18, green: 0.18, blue: 0.24, alpha: 1).cgColor
                ]
            } else {
                self.containerView.transform = .identity
                self.containerView.layer.shadowOpacity = 0
                
                self.gradientLayer?.colors = [
                    UIColor(red: 0.18, green: 0.18, blue: 0.22, alpha: 1).cgColor,
                    UIColor(red: 0.12, green: 0.12, blue: 0.16, alpha: 1).cgColor
                ]
            }
        }
    }
    
    override func prepareForReuse() {
        super.prepareForReuse()
        containerView.transform = .identity
        containerView.layer.shadowOpacity = 0
    }
    
    private func updateSelection(_ isSelected: Bool) {
        if let mark = containerView.viewWithTag(999) as? UIImageView {
            mark.isHidden = !isSelected
            return
        }
        
        let selectionMark = UIImageView(image: UIImage(systemName: "checkmark.circle.fill"))
        selectionMark.translatesAutoresizingMaskIntoConstraints = false
        selectionMark.tintColor = UIColor.systemGreen
        selectionMark.backgroundColor = UIColor(white: 0, alpha: 0.25)
        selectionMark.layer.cornerRadius = 18
        selectionMark.clipsToBounds = true
        selectionMark.tag = 999
        selectionMark.isHidden = !isSelected
        containerView.addSubview(selectionMark)
        
        NSLayoutConstraint.activate([
            selectionMark.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -16),
            selectionMark.topAnchor.constraint(equalTo: containerView.topAnchor, constant: 16),
            selectionMark.widthAnchor.constraint(equalToConstant: 36),
            selectionMark.heightAnchor.constraint(equalToConstant: 36)
        ])
    }
}
