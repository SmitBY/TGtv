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
    private var topMenu: TopMenuView?
    private let headerContainer = UIView()
    private var headerTopConstraint: NSLayoutConstraint?
    private var focusGuideDownToSearch: UIFocusGuide?
    private var focusGuideUpToMenu: UIFocusGuide?
    private var focusGuideCollectionToHeader: UIFocusGuide?
    private var pendingMenuFocus = false
    private let loadingIndicator = UIActivityIndicatorView(style: .large)
    private let progressLabel = UILabel()
    private let errorLabel = UILabel()
    private let searchContainer = UIVisualEffectView(effect: UIBlurEffect(style: .dark))
    private let searchBackgroundView = UIView()
    private let searchField = UITextField()
    private let selectionStatusLabel = UILabel()
    private let searchBackgroundNormal = UIColor(white: 0.12, alpha: 0.9)
    private let searchBackgroundFocused = UIColor(white: 0.2, alpha: 0.95)
    private var dataSource: UICollectionViewDiffableDataSource<Section, TG.Chat>!
    
    // tvOS safe area insets (Figma: 80px sides)
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
            widthDimension: .absolute(410),
            heightDimension: .absolute(289)
        )
        let item = NSCollectionLayoutItem(layoutSize: itemSize)
        
        let groupSize = NSCollectionLayoutSize(
            widthDimension: .fractionalWidth(1.0),
            heightDimension: .absolute(289)
        )
        
        // Используем массив subitems и фиксированный интервал 40px
        let group = NSCollectionLayoutGroup.horizontal(layoutSize: groupSize, subitems: [item])
        group.interItemSpacing = .fixed(40)
        
        let section = NSCollectionLayoutSection(group: group)
        section.interGroupSpacing = 28
        section.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 80, bottom: 60, trailing: 80)
        
        // Отключаем автоматические добавки от Safe Area в расчетах layout
        section.contentInsetsReference = .none
        
        return UICollectionViewCompositionalLayout(section: section)
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        restoresFocusAfterTransition = false
        setupBackground()
        setupHeaderContainer()
        setupTopMenuBar()
        setupSearchBar()
        setupSeparator()
        setupCollectionView()
        setupLoadingIndicator()
        configureDataSource()
        setupBindings()
        
        // КРИТИЧЕСКИ ВАЖНО: хедер должен быть над всеми остальными элементами,
        // включая коллекцию, чтобы фокус не "проваливался".
        view.bringSubviewToFront(headerContainer)
    }

    private func setupHeaderContainer() {
        headerContainer.translatesAutoresizingMaskIntoConstraints = false
        headerContainer.backgroundColor = .clear
        view.addSubview(headerContainer)
        view.bringSubviewToFront(headerContainer) // Всегда сверху
        
        headerTopConstraint = headerContainer.topAnchor.constraint(equalTo: view.topAnchor)
        
        NSLayoutConstraint.activate([
            headerTopConstraint!,
            headerContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            headerContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            headerContainer.heightAnchor.constraint(equalToConstant: 400)
        ])
    }

    private func currentFocusedView() -> UIView? {
        if let scene = view.window?.windowScene {
            return scene.focusSystem?.focusedItem as? UIView
        }
        return UIFocusSystem.focusSystem(for: view)?.focusedItem as? UIView
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let isMenuPress = presses.contains(where: { $0.type == .menu || $0.key?.keyCode == .keyboardEscape })
        if isMenuPress {
            // Закрываем клавиатуру/редактирование до смены фокуса
            if searchField.isFirstResponder {
                closeKeyboard()
            }
            if let topMenu, let focused = currentFocusedView(), !focused.isDescendant(of: topMenu) {
                pendingMenuFocus = true
                setNeedsFocusUpdate()
                updateFocusIfNeeded()
                return
            }
        }
        super.pressesBegan(presses, with: event)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setNavigationBarHidden(true, animated: false)
        topMenu?.setCurrentIndex(2) // Синхронизируем вкладку
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        navigationController?.setNavigationBarHidden(false, animated: false)
        topMenu?.cancelPendingTransitions()
    }
    
    private func setupBackground() {
        view.backgroundColor = UIColor(red: 44/255, green: 44/255, blue: 46/255, alpha: 1) // #2C2C2E
    }
    
    private func setupSeparator() {
        let separator = UIView()
        separator.translatesAutoresizingMaskIntoConstraints = false
        separator.backgroundColor = UIColor(white: 1, alpha: 0.3)
        headerContainer.addSubview(separator)
        
        NSLayoutConstraint.activate([
            separator.topAnchor.constraint(equalTo: headerContainer.topAnchor, constant: 371),
            separator.leadingAnchor.constraint(equalTo: headerContainer.leadingAnchor, constant: 80),
            separator.trailingAnchor.constraint(equalTo: headerContainer.trailingAnchor, constant: -80),
            separator.heightAnchor.constraint(equalToConstant: 1)
        ])
    }

    private func setupCollectionView() {
        collectionView.register(ChatCell.self, forCellWithReuseIdentifier: "ChatCell")
        collectionView.backgroundColor = .clear
        collectionView.contentInsetAdjustmentBehavior = .never
        collectionView.insetsLayoutMarginsFromSafeArea = false
        
        // Позволяем коллекции занимать весь экран
        NSLayoutConstraint.activate([
            collectionView.topAnchor.constraint(equalTo: view.topAnchor),
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        
        // Важно: задаём inset целиком. Высота хедера примерно 400.
        collectionView.contentInset = UIEdgeInsets(top: 400, left: 0, bottom: 0, right: 0)
        collectionView.scrollIndicatorInsets = collectionView.contentInset
        collectionView.layoutMargins = .zero
        collectionView.directionalLayoutMargins = .zero
        collectionView.remembersLastFocusedIndexPath = true
        collectionView.clipsToBounds = false
        
        navigationItem.title = ""
    }

    private func setupTopMenuBar() {
        let items = [
            NSLocalizedString("tab.search", comment: ""),
            NSLocalizedString("tab.home", comment: ""),
            NSLocalizedString("tab.channels", comment: ""),
            NSLocalizedString("tab.help", comment: ""),
            NSLocalizedString("tab.settings", comment: "")
        ]
        let menu = TopMenuView(items: items, selectedIndex: 2)
        menu.translatesAutoresizingMaskIntoConstraints = false
        menu.onTabSelected = { [weak self] index in
            self?.handleTabSelection(index)
        }
        headerContainer.addSubview(menu)
        
        NSLayoutConstraint.activate([
            menu.topAnchor.constraint(equalTo: headerContainer.topAnchor, constant: 60), // Стандартный отступ для tvOS
            menu.leadingAnchor.constraint(equalTo: headerContainer.leadingAnchor),
            menu.trailingAnchor.constraint(equalTo: headerContainer.trailingAnchor),
            menu.heightAnchor.constraint(equalToConstant: 74)
        ])
        topMenu = menu
    }
    
    private func handleTabSelection(_ index: Int) {
        let appDelegate = UIApplication.shared.delegate as? AppDelegate
        switch index {
        case 0:
            appDelegate?.showSearch()
        case 1:
            appDelegate?.showHome()
        case 3:
            appDelegate?.showHelp()
        case 4:
            appDelegate?.showSettings()
        default:
            break
        }
    }
    
    private func setupSearchBar() {
        searchContainer.translatesAutoresizingMaskIntoConstraints = false
        // Делаем «капсулу» как в tvOS UI
        searchContainer.layer.cornerRadius = 35
        searchContainer.clipsToBounds = true
        // UIVisualEffectView плохо работает с прямой установкой backgroundColor — используем отдельный слой.
        searchContainer.backgroundColor = .clear
        searchContainer.contentView.backgroundColor = .clear
        headerContainer.addSubview(searchContainer)

        searchBackgroundView.translatesAutoresizingMaskIntoConstraints = false
        searchBackgroundView.backgroundColor = searchBackgroundNormal
        searchContainer.contentView.addSubview(searchBackgroundView)
        
        let searchIcon = UIImageView(image: UIImage(systemName: "magnifyingglass"))
        searchIcon.tintColor = UIColor(white: 0.6, alpha: 1)
        searchIcon.translatesAutoresizingMaskIntoConstraints = false
        searchIcon.contentMode = .scaleAspectFit
        
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.delegate = self
        let searchPlaceholder = NSLocalizedString("search.chats.placeholder", comment: "")
        searchField.placeholder = searchPlaceholder
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
            string: searchPlaceholder,
            attributes: [.foregroundColor: UIColor(white: 0.6, alpha: 1)]
        )
        
        searchContainer.contentView.addSubview(searchIcon)
        searchContainer.contentView.addSubview(searchField)
        
        NSLayoutConstraint.activate([
            searchBackgroundView.topAnchor.constraint(equalTo: searchContainer.contentView.topAnchor),
            searchBackgroundView.bottomAnchor.constraint(equalTo: searchContainer.contentView.bottomAnchor),
            searchBackgroundView.leadingAnchor.constraint(equalTo: searchContainer.contentView.leadingAnchor),
            searchBackgroundView.trailingAnchor.constraint(equalTo: searchContainer.contentView.trailingAnchor),

            searchContainer.topAnchor.constraint(equalTo: topMenu?.bottomAnchor ?? headerContainer.topAnchor, constant: 20),
            searchContainer.leadingAnchor.constraint(equalTo: headerContainer.leadingAnchor, constant: 80),
            searchContainer.trailingAnchor.constraint(equalTo: headerContainer.trailingAnchor, constant: -80),
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
        selectionStatusLabel.text = NSLocalizedString("selection.none", comment: "")
        headerContainer.addSubview(selectionStatusLabel)

        NSLayoutConstraint.activate([
            selectionStatusLabel.topAnchor.constraint(equalTo: searchContainer.bottomAnchor, constant: 10),
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
            let avatar = self?.viewModel.avatarImage(for: chat.id)
            cell.configure(with: chat, selected: isSelected, avatarImage: avatar)
            self?.viewModel.requestAvatarIfNeeded(chatId: chat.id)
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
        
        viewModel.avatarDidUpdate
            .receive(on: DispatchQueue.main)
            .sink { [weak self] chatId in
                self?.refreshSelectionMarks(for: [chatId])
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
                self.errorLabel.text = String(
                    format: NSLocalizedString("channels.errorPrefix", comment: ""),
                    error.localizedDescription
                )
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
    
    override func scrollViewDidScroll(_ scrollView: UIScrollView) {
        let offset = scrollView.contentOffset.y
        // Сдвигаем хедер вместе с прокруткой. 
        // Добавляем contentInset.top, чтобы при начальном положении (offset = -400) константа была 0.
        headerTopConstraint?.constant = -(offset + scrollView.contentInset.top)
    }
    
    private func updateEmptyState(for chats: [TG.Chat]) {
        if !chats.isEmpty {
            errorLabel.isHidden = true
            if loadingIndicator.isAnimating { loadingIndicator.stopAnimating() }
            progressLabel.isHidden = true
            return
        }
        
        if !viewModel.searchQuery.isEmpty {
            errorLabel.text = NSLocalizedString("channels.nothingFound", comment: "")
            errorLabel.textColor = UIColor(white: 0.5, alpha: 1)
            errorLabel.isHidden = false
            loadingIndicator.stopAnimating()
            progressLabel.isHidden = true
        } else if !viewModel.isLoading && viewModel.chats.isEmpty {
            errorLabel.text = NSLocalizedString("channels.noChats", comment: "")
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
        if count == 0 {
            selectionStatusLabel.text = NSLocalizedString("selection.none", comment: "")
        } else {
            selectionStatusLabel.text = String(
                format: NSLocalizedString("selection.count", comment: ""),
                count
            )
        }
    }

    override func shouldUpdateFocus(in context: UIFocusUpdateContext) -> Bool {
        let heading = context.focusHeading
        let nextView = context.nextFocusedView
        
        // Если фокус уже в хедере
        if let prev = context.previouslyFocusedView, prev.isDescendant(of: headerContainer) {
            // Блокируем несанкционированный выход вбок или вверх
            if heading.contains(.left) || heading.contains(.right) || heading.contains(.up) {
                if let next = nextView, !next.isDescendant(of: headerContainer) {
                    return false
                }
            }
        }

        return true
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
        
        // Умное управление гайдами
        if let next = next {
            if let topMenu, next.isDescendant(of: topMenu) {
                focusGuideDownToSearch?.preferredFocusEnvironments = [searchField]
                focusGuideUpToMenu?.preferredFocusEnvironments = []
                focusGuideCollectionToHeader?.preferredFocusEnvironments = [collectionView]
            } else if next === searchField {
                focusGuideDownToSearch?.preferredFocusEnvironments = []
                focusGuideUpToMenu?.preferredFocusEnvironments = [topMenu?.currentFocusTarget()].compactMap { $0 }
                focusGuideCollectionToHeader?.preferredFocusEnvironments = [collectionView]
            } else {
                // Фокус в коллекции или где-то еще
                focusGuideDownToSearch?.preferredFocusEnvironments = []
                focusGuideUpToMenu?.preferredFocusEnvironments = []
                focusGuideCollectionToHeader?.preferredFocusEnvironments = [searchField]
            }
        }
    }

    private func updateSearchFocus(isFocused: Bool) {
        UIView.animate(withDuration: 0.15) {
            self.searchBackgroundView.backgroundColor = isFocused ? self.searchBackgroundFocused : self.searchBackgroundNormal
            self.searchContainer.layer.borderWidth = isFocused ? 2 : 0
            self.searchContainer.layer.borderColor = isFocused ? UIColor.systemBlue.cgColor : UIColor.clear.cgColor
        }
    }
    
    private func closeKeyboard() {
        searchField.resignFirstResponder()
    }

    private func installFocusGuides() {
        guard let topMenu else { return }
        
        // Удаляем старые гайды
        view.layoutGuides.filter { $0 is UIFocusGuide && $0.identifier == "ChatToSearchGuide" }.forEach { view.removeLayoutGuide($0) }
        
        // 1. Глобальный гайд от коллекции вверх К ПОИСКУ
        let guideCol = UIFocusGuide()
        guideCol.identifier = "ChatToSearchGuide"
        guideCol.preferredFocusEnvironments = [searchField]
        view.addLayoutGuide(guideCol)
        NSLayoutConstraint.activate([
            guideCol.topAnchor.constraint(equalTo: headerContainer.bottomAnchor, constant: -100),
            guideCol.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            guideCol.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            guideCol.heightAnchor.constraint(equalToConstant: 200)
        ])
        focusGuideCollectionToHeader = guideCol
        
        // 2. Гайд от меню вниз к поиску (внутренний для хедера)
        let guideDown = UIFocusGuide()
        guideDown.preferredFocusEnvironments = [searchField]
        headerContainer.addLayoutGuide(guideDown)
        NSLayoutConstraint.activate([
            guideDown.topAnchor.constraint(equalTo: topMenu.bottomAnchor),
            guideDown.leadingAnchor.constraint(equalTo: headerContainer.leadingAnchor),
            guideDown.trailingAnchor.constraint(equalTo: headerContainer.trailingAnchor),
            guideDown.heightAnchor.constraint(equalToConstant: 40)
        ])
        focusGuideDownToSearch = guideDown
        
        // 3. Гайд от поиска вверх к меню
        let guideUp = UIFocusGuide()
        guideUp.preferredFocusEnvironments = [topMenu.currentFocusTarget()].compactMap { $0 }
        guideUp.isEnabled = true
        headerContainer.addLayoutGuide(guideUp)
        NSLayoutConstraint.activate([
            guideUp.bottomAnchor.constraint(equalTo: searchContainer.topAnchor),
            guideUp.leadingAnchor.constraint(equalTo: headerContainer.leadingAnchor),
            guideUp.trailingAnchor.constraint(equalTo: headerContainer.trailingAnchor),
            guideUp.heightAnchor.constraint(equalToConstant: 40)
        ])
        focusGuideUpToMenu = guideUp
    }

    override var preferredFocusEnvironments: [UIFocusEnvironment] {
        if pendingMenuFocus, let menu = topMenu, let target = menu.currentFocusTarget() {
            pendingMenuFocus = false
            return [target]
        }
        if let menu = topMenu, let target = menu.currentFocusTarget() {
            return [target]
        }
        return super.preferredFocusEnvironments
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
    private let avatarView = UIView()
    private let avatarImageView = UIImageView()
    private let avatarLabel = UILabel()

    private func applyFocusAppearance(_ focused: Bool) {
        if focused {
            containerView.transform = CGAffineTransform(scaleX: 1.1, y: 1.1)
            avatarView.layer.borderWidth = 4
            avatarView.layer.borderColor = UIColor.white.cgColor
            titleLabel.textColor = .white
        } else {
            containerView.transform = .identity
            avatarView.layer.borderWidth = 0
            avatarView.layer.borderColor = UIColor.clear.cgColor
            titleLabel.textColor = UIColor(white: 1, alpha: 0.5)
        }
    }
    
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
        containerView.layer.cornerRadius = 12
        containerView.clipsToBounds = true
        contentView.addSubview(containerView)
        
        // Background (Image placeholder in Figma)
        avatarView.translatesAutoresizingMaskIntoConstraints = false
        avatarView.backgroundColor = UIColor(white: 1, alpha: 0.1)
        avatarView.layer.cornerRadius = 12
        avatarView.clipsToBounds = true
        containerView.addSubview(avatarView)
        
        avatarImageView.translatesAutoresizingMaskIntoConstraints = false
        avatarImageView.contentMode = .scaleAspectFill
        avatarImageView.clipsToBounds = true
        avatarImageView.isHidden = true
        avatarView.addSubview(avatarImageView)
        
        avatarLabel.translatesAutoresizingMaskIntoConstraints = false
        avatarLabel.textColor = .white
        avatarLabel.font = .systemFont(ofSize: 48, weight: .semibold)
        avatarLabel.textAlignment = .center
        avatarView.addSubview(avatarLabel)
        
        // Title
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.textColor = UIColor(white: 1, alpha: 0.5)
        titleLabel.font = .systemFont(ofSize: 31, weight: .medium)
        titleLabel.textAlignment = .center
        titleLabel.numberOfLines = 1
        containerView.addSubview(titleLabel)
        
        NSLayoutConstraint.activate([
            containerView.topAnchor.constraint(equalTo: contentView.topAnchor),
            containerView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            containerView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            containerView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            
            avatarView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
            avatarView.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
            avatarView.topAnchor.constraint(equalTo: containerView.topAnchor),
            avatarView.heightAnchor.constraint(equalToConstant: 231),
            
            avatarImageView.leadingAnchor.constraint(equalTo: avatarView.leadingAnchor),
            avatarImageView.trailingAnchor.constraint(equalTo: avatarView.trailingAnchor),
            avatarImageView.topAnchor.constraint(equalTo: avatarView.topAnchor),
            avatarImageView.bottomAnchor.constraint(equalTo: avatarView.bottomAnchor),
            
            avatarLabel.centerXAnchor.constraint(equalTo: avatarView.centerXAnchor),
            avatarLabel.centerYAnchor.constraint(equalTo: avatarView.centerYAnchor),
            
            titleLabel.topAnchor.constraint(equalTo: containerView.topAnchor, constant: 234),
            titleLabel.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
            titleLabel.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
            titleLabel.heightAnchor.constraint(equalToConstant: 38)
        ])
    }
    
    override func layoutSubviews() {
        super.layoutSubviews()
    }
    
    func configure(with chat: TG.Chat, selected: Bool, avatarImage: UIImage?) {
        titleLabel.text = chat.title
        
        let initials = chat.title.prefix(2).uppercased()
        avatarLabel.text = String(initials)
        
        let hue = CGFloat(abs(chat.id.hashValue) % 360) / 360.0
        let fallbackColor = UIColor(hue: hue, saturation: 0.5, brightness: 0.7, alpha: 1)
        
        if let avatarImage {
            avatarImageView.image = avatarImage
            avatarImageView.isHidden = false
            avatarLabel.isHidden = true
            avatarView.backgroundColor = .clear
        } else {
            avatarImageView.image = nil
            avatarImageView.isHidden = true
            avatarLabel.isHidden = false
            avatarView.backgroundColor = fallbackColor
        }
        
        updateSelection(selected)
        applyFocusAppearance(isFocused)
    }
    
    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        
        coordinator.addCoordinatedAnimations {
            self.applyFocusAppearance(self.isFocused)
        }
    }
    
    override func prepareForReuse() {
        super.prepareForReuse()
        titleLabel.text = nil
        avatarLabel.text = nil
        avatarLabel.isHidden = false
        avatarImageView.image = nil
        avatarImageView.isHidden = true

        if let mark = containerView.viewWithTag(999) as? UIImageView {
            mark.isHidden = true
        }

        applyFocusAppearance(false)
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
