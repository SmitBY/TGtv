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
    private var topMenuControl: UISegmentedControl?
    private var focusGuideDownToSearch: UIFocusGuide?
    private var focusGuideUpToMenu: UIFocusGuide?
    private var pendingMenuFocus = false
    private let loadingIndicator = UIActivityIndicatorView(style: .large)
    private let progressLabel = UILabel()
    private let errorLabel = UILabel()
    private let searchContainer = UIVisualEffectView(effect: UIBlurEffect(style: .dark))
    private let searchField = UITextField()
    private let selectionStatusLabel = UILabel()
    private let searchBackgroundNormal = UIColor(white: 0.12, alpha: 0.9)
    private let searchBackgroundFocused = UIColor(white: 0.2, alpha: 0.95)
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
        setupTopMenuBar()
        setupSearchBar()
        setupCollectionView()
        setupLoadingIndicator()
        configureDataSource()
        setupBindings()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setNavigationBarHidden(true, animated: false)
        topMenuControl?.selectedSegmentIndex = 1
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        navigationController?.setNavigationBarHidden(false, animated: false)
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
        collectionView.contentInset.top = 220
        collectionView.scrollIndicatorInsets = collectionView.contentInset
        collectionView.remembersLastFocusedIndexPath = true
        collectionView.clipsToBounds = false
        
        navigationItem.title = ""
    }

    private func setupTopMenuBar() {
        let control = UISegmentedControl(items: ["Главная", "Список", "Настройки"])
        control.translatesAutoresizingMaskIntoConstraints = false
        control.selectedSegmentIndex = 1
        control.backgroundColor = UIColor(white: 0, alpha: 0.55)
        control.selectedSegmentTintColor = UIColor.white
        control.addTarget(self, action: #selector(topMenuChanged(_:)), for: .valueChanged)
        control.setTitleTextAttributes([
            .foregroundColor: UIColor.black,
            .font: UIFont.systemFont(ofSize: 30, weight: .regular)
        ], for: .normal)
        control.setTitleTextAttributes([
            .foregroundColor: UIColor.black,
            .font: UIFont.systemFont(ofSize: 32, weight: .semibold)
        ], for: .selected)
        view.addSubview(control)
        NSLayoutConstraint.activate([
            control.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 10),
            control.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: tvSafeInsets.left),
            control.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -tvSafeInsets.right),
            control.heightAnchor.constraint(equalToConstant: 80)
        ])
        topMenuControl = control
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
        
        searchContainer.contentView.addSubview(searchIcon)
        searchContainer.contentView.addSubview(searchField)
        
        NSLayoutConstraint.activate([
            searchContainer.topAnchor.constraint(equalTo: topMenuControl?.bottomAnchor ?? view.safeAreaLayoutGuide.topAnchor, constant: 20),
            searchContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: tvSafeInsets.left),
            searchContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -tvSafeInsets.right),
            searchContainer.heightAnchor.constraint(equalToConstant: 70),
            
            searchIcon.leadingAnchor.constraint(equalTo: searchContainer.leadingAnchor, constant: 24),
            searchIcon.centerYAnchor.constraint(equalTo: searchContainer.centerYAnchor),
            searchIcon.widthAnchor.constraint(equalToConstant: 32),
            searchIcon.heightAnchor.constraint(equalToConstant: 32),
            
            searchField.leadingAnchor.constraint(equalTo: searchIcon.trailingAnchor, constant: 16),
            searchField.trailingAnchor.constraint(equalTo: searchContainer.trailingAnchor, constant: -24),
            searchField.topAnchor.constraint(equalTo: searchContainer.topAnchor),
            searchField.bottomAnchor.constraint(equalTo: searchContainer.bottomAnchor),
        ])
        
        setupSelectionControls()
        installFocusGuides()
    }
    
    private func setupSelectionControls() {
        guard onSaveSelection != nil else { return }
        
        selectionStatusLabel.translatesAutoresizingMaskIntoConstraints = false
        selectionStatusLabel.textColor = .white
        selectionStatusLabel.font = .systemFont(ofSize: 24, weight: .medium)
        selectionStatusLabel.textAlignment = .left
        selectionStatusLabel.text = "Не выбрано"
        view.addSubview(selectionStatusLabel)

        NSLayoutConstraint.activate([
            selectionStatusLabel.topAnchor.constraint(equalTo: searchContainer.bottomAnchor, constant: 16),
            selectionStatusLabel.leadingAnchor.constraint(equalTo: searchContainer.leadingAnchor)
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
        // #region agent log
        agentLog(
            hypothesisId: "H3",
            location: "ChatListViewController:viewDidLayoutSubviews",
            message: "frames after layout",
            data: [
                "menuFrame": NSCoder.string(for: topMenuControl?.frame ?? .zero),
                "searchFrame": NSCoder.string(for: searchContainer.frame),
                "guideDownHeight": focusGuideDownToSearch?.layoutFrame.height ?? 0,
                "guideUpHeight": focusGuideUpToMenu?.layoutFrame.height ?? 0,
                "guideUpEnabled": focusGuideUpToMenu?.isEnabled ?? false
            ]
        )
        // #endregion
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
        onSaveSelection?(selectedChatIds)
    }
    
    @objc private func searchTextDidChange(_ sender: UITextField) {
        Task { @MainActor [weak self] in
            self?.viewModel.updateSearchQuery(sender.text ?? "")
        }
    }

    @objc private func topMenuChanged(_ sender: UISegmentedControl) {
        switch sender.selectedSegmentIndex {
        case 0:
            if let nav = navigationController {
                nav.popToRootViewController(animated: true)
            }
        case 2:
            (UIApplication.shared.delegate as? AppDelegate)?.openSettings()
        default:
            break
        }
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

        // #region agent log
        agentLog(
            hypothesisId: "H1",
            location: "ChatListViewController:didUpdateFocus",
            message: "focus transition",
            data: [
                "heading": context.focusHeading.rawValue,
                "next": String(describing: next),
                "prev": String(describing: prev)
            ]
        )
        // #endregion
    }

    private func updateSearchFocus(isFocused: Bool) {
        UIView.animate(withDuration: 0.15) {
            self.searchContainer.backgroundColor = isFocused ? self.searchBackgroundFocused : self.searchBackgroundNormal
            self.searchContainer.layer.borderWidth = isFocused ? 2 : 0
            self.searchContainer.layer.borderColor = isFocused ? UIColor.systemBlue.cgColor : UIColor.clear.cgColor
        }
    }
    
    private func closeKeyboard() {
        searchField.resignFirstResponder()
    }

    private func installFocusGuides() {
        guard let topMenuControl else { return }
        
        let guideDown = UIFocusGuide()
        guideDown.preferredFocusEnvironments = [searchField]
        view.addLayoutGuide(guideDown)
        NSLayoutConstraint.activate([
            guideDown.topAnchor.constraint(equalTo: topMenuControl.bottomAnchor, constant: 4),
            guideDown.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            guideDown.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            guideDown.heightAnchor.constraint(equalToConstant: 24)
        ])
        focusGuideDownToSearch = guideDown
        
        let guideUp = UIFocusGuide()
        guideUp.preferredFocusEnvironments = [topMenuControl]
        guideUp.isEnabled = true
        view.addLayoutGuide(guideUp)
        NSLayoutConstraint.activate([
            guideUp.bottomAnchor.constraint(equalTo: searchContainer.topAnchor, constant: -4),
            guideUp.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            guideUp.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            guideUp.heightAnchor.constraint(equalToConstant: 24)
        ])
        focusGuideUpToMenu = guideUp

        // #region agent log
        agentLog(
            hypothesisId: "H2",
            location: "ChatListViewController:installFocusGuides",
            message: "focus guides created",
            data: [
                "guideDownPreferred": guideDown.preferredFocusEnvironments.count,
                "guideUpPreferred": guideUp.preferredFocusEnvironments.count,
                "guideUpEnabled": guideUp.isEnabled
            ]
        )
        // #endregion
    }

    override func shouldUpdateFocus(in context: UIFocusUpdateContext) -> Bool {
        let headingValue = context.focusHeading.rawValue
        let next = context.nextFocusedView
        let prev = context.previouslyFocusedView

        // #region agent log
        agentLog(
            hypothesisId: "H4",
            location: "ChatListViewController:shouldUpdateFocus",
            message: "focus decision",
            data: [
                "heading": headingValue,
                "next": String(describing: next),
                "prev": String(describing: prev),
                "guideUpEnabled": focusGuideUpToMenu?.isEnabled ?? false,
                "menuCanFocus": topMenuControl?.canBecomeFocused ?? false,
                "isPrevSearch": prev === searchField,
                "headingUp": context.focusHeading.contains(.up)
            ]
        )
        // #endregion

        let isPrevSearch = (prev === searchField)
        let headingUp = context.focusHeading.contains(.up)

        if isPrevSearch, headingUp {
            pendingMenuFocus = true
            // #region agent log
            agentLog(
                hypothesisId: "H5",
                location: "ChatListViewController:shouldUpdateFocus",
                message: "attempt focus to menu",
                data: [
                    "menuCanFocus": topMenuControl?.canBecomeFocused ?? false,
                    "focusSystemNil": UIFocusSystem.focusSystem(for: view) == nil
                ]
            )
            // #endregion
            setNeedsFocusUpdate()
            UIFocusSystem.focusSystem(for: view)?.updateFocusIfNeeded()
            // #region agent log
            agentLog(
                hypothesisId: "H5",
                location: "ChatListViewController:shouldUpdateFocus",
                message: "requested focus update to menu",
                data: [
                    "menuCanFocus": topMenuControl?.canBecomeFocused ?? false,
                    "guideUpEnabled": focusGuideUpToMenu?.isEnabled ?? false
                ]
            )
            // #endregion
            return false
        }
        return true
    }

    override var preferredFocusEnvironments: [UIFocusEnvironment] {
        if pendingMenuFocus, let menu = topMenuControl {
            // #region agent log
            agentLog(
                hypothesisId: "H6",
                location: "ChatListViewController:preferredFocusEnvironments",
                message: "directing focus to menu",
                data: ["menuCanFocus": menu.canBecomeFocused]
            )
            // #endregion
            pendingMenuFocus = false
            return [menu]
        }
        return super.preferredFocusEnvironments
    }

    // #region agent log
    private func agentLog(
        hypothesisId: String,
        location: String,
        message: String,
        data: [String: Any] = [:]
    ) {
        let payload: [String: Any] = [
            "sessionId": "debug-session",
            "runId": "pre-fix",
            "hypothesisId": hypothesisId,
            "location": location,
            "message": message,
            "data": data,
            "timestamp": Int(Date().timeIntervalSince1970 * 1000)
        ]
        guard let jsonData = try? JSONSerialization.data(withJSONObject: payload),
              var line = String(data: jsonData, encoding: .utf8) else { return }
        line.append("\n")
        let url = URL(fileURLWithPath: "/Users/dmitriy/Documents/Projects/TGtv/.cursor/debug.log")
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            if let data = line.data(using: .utf8) {
                handle.write(data)
            }
            try? handle.close()
        } else {
            try? line.write(to: url, atomically: true, encoding: .utf8)
        }
    }
    // #endregion
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
