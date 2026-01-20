import UIKit
import Combine
import TDLibKit
import AVKit

final class SearchViewController: UIViewController, AVPlayerViewControllerDelegate {
    enum Section: CaseIterable {
        case main
    }

    private let viewModel: SearchViewModel

    private var cancellables = Set<AnyCancellable>()

    private var topMenu: TopMenuView?
    private let headerContainer = UIView()
    private let searchContainer = UIVisualEffectView(effect: UIBlurEffect(style: .dark))
    private let searchBackgroundView = UIView()
    private let searchField = UITextField()

    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Section, HomeVideoItem>!

    private let loadingIndicator = UIActivityIndicatorView(style: .large)
    private let errorLabel = UILabel()

    private var pendingMenuFocus = false
    private var pendingSearchFocus = true
    
    private var focusGuideDownToSearch: UIFocusGuide?
    private var focusGuideUpToMenu: UIFocusGuide?

    // Playback
    private var streamingCoordinator: VideoStreamingCoordinator?
    private var fileUpdateObserver: NSObjectProtocol?
    private var playTask: Task<Void, Never>?
    private var currentSelectionId: String?

    // Fullscreen loading overlay
    private var fullscreenLoadingView: UIView?
    private var fullscreenSpinner: UIActivityIndicatorView?
    private var fullscreenLabel: UILabel?
    private var fullscreenCancelButton: UIButton?

    init(client: TDLibClient) {
        self.viewModel = SearchViewModel(client: client)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var preferredFocusEnvironments: [UIFocusEnvironment] {
        if pendingMenuFocus, let menu = topMenu, let target = menu.currentFocusTarget() {
            pendingMenuFocus = false
            return [target]
        }
        if pendingSearchFocus {
            pendingSearchFocus = false
            return [searchField]
        }
        return super.preferredFocusEnvironments
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        restoresFocusAfterTransition = false
        setupBackground()
        setupHeaderContainer()
        setupTopMenuBar()
        setupSearchBar()
        setupCollectionView()
        setupLoadingAndError()
        configureDataSource()
        setupBindings()
        observeFileUpdates()

        view.bringSubviewToFront(headerContainer)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setNavigationBarHidden(true, animated: false)
        topMenu?.setCurrentIndex(0) // Синхронизируем вкладку "Поиск"
        pendingSearchFocus = true
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        setNeedsFocusUpdate()
        updateFocusIfNeeded()
        _ = searchField.becomeFirstResponder()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        navigationController?.setNavigationBarHidden(false, animated: false)
        topMenu?.cancelPendingTransitions()
        searchField.resignFirstResponder()
    }

    deinit {
        streamingCoordinator?.stop()
        playTask?.cancel()
        if let observer = fileUpdateObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    private func setupBackground() {
        let bg = UIImageView()
        bg.translatesAutoresizingMaskIntoConstraints = false
        bg.contentMode = .scaleAspectFill
        bg.image = UIImage(named: "Background Image")
        view.addSubview(bg)
        NSLayoutConstraint.activate([
            bg.topAnchor.constraint(equalTo: view.topAnchor),
            bg.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            bg.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            bg.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])

        let overlay = UIView()
        overlay.translatesAutoresizingMaskIntoConstraints = false
        overlay.backgroundColor = UIColor(white: 0, alpha: 0.15)
        overlay.isUserInteractionEnabled = false
        view.addSubview(overlay)
        NSLayoutConstraint.activate([
            overlay.topAnchor.constraint(equalTo: view.topAnchor),
            overlay.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            overlay.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])
    }

    private func setupHeaderContainer() {
        headerContainer.translatesAutoresizingMaskIntoConstraints = false
        headerContainer.backgroundColor = .clear
        view.addSubview(headerContainer)

        NSLayoutConstraint.activate([
            headerContainer.topAnchor.constraint(equalTo: view.topAnchor),
            headerContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            headerContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            headerContainer.heightAnchor.constraint(equalToConstant: 300)
        ])

        // Logo (как на Home)
        let logoImageView = UIImageView(image: UIImage(named: "Logo"))
        logoImageView.translatesAutoresizingMaskIntoConstraints = false
        logoImageView.contentMode = .scaleAspectFit
        headerContainer.addSubview(logoImageView)
        NSLayoutConstraint.activate([
            logoImageView.leadingAnchor.constraint(equalTo: headerContainer.leadingAnchor, constant: 64),
            logoImageView.topAnchor.constraint(equalTo: headerContainer.topAnchor, constant: 59),
            logoImageView.widthAnchor.constraint(equalToConstant: 175),
            logoImageView.heightAnchor.constraint(equalToConstant: 66)
        ])
    }

    private func setupTopMenuBar() {
        let items = [
            NSLocalizedString("tab.search", comment: ""),
            NSLocalizedString("tab.home", comment: ""),
            NSLocalizedString("tab.channels", comment: ""),
            NSLocalizedString("tab.help", comment: ""),
            NSLocalizedString("tab.settings", comment: "")
        ]
        let menu = TopMenuView(items: items, selectedIndex: 0)
        menu.translatesAutoresizingMaskIntoConstraints = false
        menu.onTabSelected = { [weak self] index in
            self?.handleTabSelection(index)
        }
        headerContainer.addSubview(menu)

        NSLayoutConstraint.activate([
            menu.topAnchor.constraint(equalTo: headerContainer.topAnchor, constant: 60),
            menu.leadingAnchor.constraint(equalTo: headerContainer.leadingAnchor),
            menu.trailingAnchor.constraint(equalTo: headerContainer.trailingAnchor),
            menu.heightAnchor.constraint(equalToConstant: 74)
        ])
        topMenu = menu
    }

    private func handleTabSelection(_ index: Int) {
        let appDelegate = UIApplication.shared.delegate as? AppDelegate
        switch index {
        case 1:
            appDelegate?.showHome()
        case 2:
            appDelegate?.showChannels()
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
        searchContainer.layer.cornerRadius = 35
        searchContainer.clipsToBounds = true
        searchContainer.backgroundColor = .clear
        searchContainer.contentView.backgroundColor = .clear
        headerContainer.addSubview(searchContainer)

        searchBackgroundView.translatesAutoresizingMaskIntoConstraints = false
        searchBackgroundView.backgroundColor = UIColor(white: 0.12, alpha: 0.9)
        searchContainer.contentView.addSubview(searchBackgroundView)

        let searchIcon = UIImageView(image: UIImage(systemName: "magnifyingglass"))
        searchIcon.tintColor = UIColor(white: 0.6, alpha: 1)
        searchIcon.translatesAutoresizingMaskIntoConstraints = false
        searchIcon.contentMode = .scaleAspectFit

        let placeholder = NSLocalizedString("search.videos.placeholder", comment: "")
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.placeholder = placeholder
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
            string: placeholder,
            attributes: [.foregroundColor: UIColor(white: 0.6, alpha: 1)]
        )

        searchContainer.contentView.addSubview(searchIcon)
        searchContainer.contentView.addSubview(searchField)

        NSLayoutConstraint.activate([
            searchContainer.topAnchor.constraint(equalTo: topMenu?.bottomAnchor ?? headerContainer.topAnchor, constant: 20),
            searchContainer.leadingAnchor.constraint(equalTo: headerContainer.leadingAnchor, constant: 80),
            searchContainer.trailingAnchor.constraint(equalTo: headerContainer.trailingAnchor, constant: -80),
            searchContainer.heightAnchor.constraint(equalToConstant: 70),

            searchBackgroundView.topAnchor.constraint(equalTo: searchContainer.contentView.topAnchor),
            searchBackgroundView.bottomAnchor.constraint(equalTo: searchContainer.contentView.bottomAnchor),
            searchBackgroundView.leadingAnchor.constraint(equalTo: searchContainer.contentView.leadingAnchor),
            searchBackgroundView.trailingAnchor.constraint(equalTo: searchContainer.contentView.trailingAnchor),

            searchIcon.leadingAnchor.constraint(equalTo: searchContainer.leadingAnchor, constant: 24),
            searchIcon.centerYAnchor.constraint(equalTo: searchContainer.centerYAnchor),
            searchIcon.widthAnchor.constraint(equalToConstant: 32),
            searchIcon.heightAnchor.constraint(equalToConstant: 32),

            searchField.leadingAnchor.constraint(equalTo: searchIcon.trailingAnchor, constant: 16),
            searchField.trailingAnchor.constraint(equalTo: searchContainer.trailingAnchor, constant: -24),
            searchField.topAnchor.constraint(equalTo: searchContainer.topAnchor),
            searchField.bottomAnchor.constraint(equalTo: searchContainer.bottomAnchor)
        ])
        
        installFocusGuides()
    }
    
    private func installFocusGuides() {
        guard let topMenu else { return }
        
        // Удаляем старые гайды (если пересоздаём UI/экран)
        headerContainer.layoutGuides
            .filter { $0 is UIFocusGuide && ($0.identifier == "SearchMenuDownToSearchGuide" || $0.identifier == "SearchSearchUpToMenuGuide") }
            .forEach { headerContainer.removeLayoutGuide($0) }
        
        // 1) Гайд от меню вниз к поиску
        let guideDown = UIFocusGuide()
        guideDown.identifier = "SearchMenuDownToSearchGuide"
        guideDown.preferredFocusEnvironments = [searchField]
        guideDown.isEnabled = false
        headerContainer.addLayoutGuide(guideDown)
        NSLayoutConstraint.activate([
            guideDown.topAnchor.constraint(equalTo: topMenu.bottomAnchor),
            guideDown.leadingAnchor.constraint(equalTo: headerContainer.leadingAnchor),
            guideDown.trailingAnchor.constraint(equalTo: headerContainer.trailingAnchor),
            guideDown.heightAnchor.constraint(equalToConstant: 40)
        ])
        focusGuideDownToSearch = guideDown
        
        // 2) Гайд от поиска вверх к меню (важно: при подъёме фокуса всегда попадаем на текущую вкладку "Поиск")
        let guideUp = UIFocusGuide()
        guideUp.identifier = "SearchSearchUpToMenuGuide"
        guideUp.preferredFocusEnvironments = [topMenu.currentFocusTarget()].compactMap { $0 }
        guideUp.isEnabled = false
        headerContainer.addLayoutGuide(guideUp)
        NSLayoutConstraint.activate([
            guideUp.bottomAnchor.constraint(equalTo: searchContainer.topAnchor),
            guideUp.leadingAnchor.constraint(equalTo: headerContainer.leadingAnchor),
            guideUp.trailingAnchor.constraint(equalTo: headerContainer.trailingAnchor),
            guideUp.heightAnchor.constraint(equalToConstant: 40)
        ])
        focusGuideUpToMenu = guideUp
    }
    
    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        
        guard let topMenu else { return }
        let next = context.nextFocusedView
        
        if let next, next.isDescendant(of: topMenu) {
            // Фокус в меню: вниз ведём к поиску, вверх-гайд выключаем, чтобы не «залипать» в меню
            focusGuideDownToSearch?.preferredFocusEnvironments = [searchField]
            focusGuideDownToSearch?.isEnabled = true
            focusGuideUpToMenu?.isEnabled = false
        } else if next === searchField {
            // Фокус в поиске: вверх ведём на текущую вкладку меню (на SearchViewController это индекс 0)
            focusGuideDownToSearch?.isEnabled = false
            focusGuideUpToMenu?.preferredFocusEnvironments = [topMenu.currentFocusTarget()].compactMap { $0 }
            focusGuideUpToMenu?.isEnabled = true
        } else {
            focusGuideDownToSearch?.isEnabled = false
            focusGuideUpToMenu?.isEnabled = false
        }
    }

    private func setupCollectionView() {
        collectionView = UICollectionView(frame: .zero, collectionViewLayout: Self.createLayout())
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        collectionView.backgroundColor = .clear
        collectionView.contentInsetAdjustmentBehavior = .never
        collectionView.insetsLayoutMarginsFromSafeArea = false
        collectionView.remembersLastFocusedIndexPath = true
        collectionView.delegate = self
        view.addSubview(collectionView)

        NSLayoutConstraint.activate([
            collectionView.topAnchor.constraint(equalTo: headerContainer.bottomAnchor, constant: 10),
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -40)
        ])

        collectionView.register(VideoCell.self, forCellWithReuseIdentifier: "VideoCell")
    }

    private static func createLayout() -> UICollectionViewCompositionalLayout {
        let itemSize = NSCollectionLayoutSize(widthDimension: .absolute(320), heightDimension: .absolute(280))
        let item = NSCollectionLayoutItem(layoutSize: itemSize)
        item.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 10, bottom: 0, trailing: 10)

        let groupSize = NSCollectionLayoutSize(widthDimension: .fractionalWidth(1.0), heightDimension: .absolute(280))
        let group = NSCollectionLayoutGroup.horizontal(layoutSize: groupSize, repeatingSubitem: item, count: 5)
        group.interItemSpacing = .fixed(20)

        let section = NSCollectionLayoutSection(group: group)
        section.interGroupSpacing = 40
        section.contentInsetsReference = .none
        section.contentInsets = NSDirectionalEdgeInsets(top: 20, leading: 54, bottom: 40, trailing: 64)
        return UICollectionViewCompositionalLayout(section: section)
    }

    private func setupLoadingAndError() {
        loadingIndicator.translatesAutoresizingMaskIntoConstraints = false
        loadingIndicator.hidesWhenStopped = true
        loadingIndicator.color = .white
        view.addSubview(loadingIndicator)

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

            errorLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            errorLabel.topAnchor.constraint(equalTo: loadingIndicator.bottomAnchor, constant: 16),
            errorLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 80),
            errorLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -80)
        ])
    }

    private func configureDataSource() {
        dataSource = UICollectionViewDiffableDataSource<Section, HomeVideoItem>(collectionView: collectionView) { collectionView, indexPath, item in
            let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "VideoCell", for: indexPath) as! VideoCell
            cell.configure(
                title: item.title,
                thumbnailPath: item.thumbnailPath,
                minithumbnailData: item.minithumbnailData
            )
            return cell
        }

        var snapshot = NSDiffableDataSourceSnapshot<Section, HomeVideoItem>()
        snapshot.appendSections([.main])
        snapshot.appendItems([])
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    private func setupBindings() {
        viewModel.$items
            .receive(on: DispatchQueue.main)
            .sink { [weak self] items in
                guard let self else { return }
                var snapshot = NSDiffableDataSourceSnapshot<Section, HomeVideoItem>()
                snapshot.appendSections([.main])
                snapshot.appendItems(items, toSection: .main)
                self.dataSource.apply(snapshot, animatingDifferences: true)
            }
            .store(in: &cancellables)

        viewModel.$isLoading
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isLoading in
                guard let self else { return }
                if isLoading {
                    self.loadingIndicator.startAnimating()
                } else {
                    self.loadingIndicator.stopAnimating()
                }
            }
            .store(in: &cancellables)

        viewModel.$error
            .receive(on: DispatchQueue.main)
            .sink { [weak self] error in
                guard let self else { return }
                if let error {
                    self.errorLabel.text = String(format: NSLocalizedString("channels.errorPrefix", comment: ""), error.localizedDescription)
                    self.errorLabel.isHidden = false
                } else {
                    self.errorLabel.isHidden = true
                }
            }
            .store(in: &cancellables)
    }

    private func observeFileUpdates() {
        fileUpdateObserver = NotificationCenter.default.addObserver(forName: .tgFileUpdated, object: nil, queue: .main) { [weak self] note in
            guard let self, let file = note.object as? TDLibKit.File else { return }
            self.streamingCoordinator?.handleFileUpdate(file)
        }
    }

    @objc private func searchTextDidChange(_ sender: UITextField) {
        viewModel.updateQuery(sender.text ?? "")
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
            // Если идёт подготовка/плейбек — позволяем отменить
            if fullscreenLoadingView?.isHidden == false {
                cancelPlaybackPreparation()
                return
            }
            if searchField.isFirstResponder {
                searchField.resignFirstResponder()
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

    private func showFullscreenLoading(message: String) {
        if fullscreenLoadingView == nil {
            let overlay = UIView()
            overlay.translatesAutoresizingMaskIntoConstraints = false
            overlay.backgroundColor = UIColor(white: 0, alpha: 0.6)

            let spinner = UIActivityIndicatorView(style: .large)
            spinner.translatesAutoresizingMaskIntoConstraints = false
            spinner.startAnimating()

            let label = UILabel()
            label.translatesAutoresizingMaskIntoConstraints = false
            label.textColor = .white
            label.font = .systemFont(ofSize: 22, weight: .medium)
            label.textAlignment = .center
            label.numberOfLines = 0

            let cancelButton = UIButton(type: .system)
            cancelButton.translatesAutoresizingMaskIntoConstraints = false
            cancelButton.setTitle(NSLocalizedString("button.back", comment: ""), for: .normal)
            cancelButton.titleLabel?.font = .systemFont(ofSize: 22, weight: .semibold)
            cancelButton.addTarget(self, action: #selector(cancelPlaybackPreparation), for: .primaryActionTriggered)

            overlay.addSubview(spinner)
            overlay.addSubview(label)
            overlay.addSubview(cancelButton)
            view.addSubview(overlay)

            NSLayoutConstraint.activate([
                overlay.topAnchor.constraint(equalTo: view.topAnchor),
                overlay.bottomAnchor.constraint(equalTo: view.bottomAnchor),
                overlay.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                overlay.trailingAnchor.constraint(equalTo: view.trailingAnchor),

                spinner.centerXAnchor.constraint(equalTo: overlay.centerXAnchor),
                spinner.centerYAnchor.constraint(equalTo: overlay.centerYAnchor, constant: -12),

                label.centerXAnchor.constraint(equalTo: overlay.centerXAnchor),
                label.topAnchor.constraint(equalTo: spinner.bottomAnchor, constant: 12),
                label.leadingAnchor.constraint(equalTo: overlay.leadingAnchor, constant: 80),
                label.trailingAnchor.constraint(equalTo: overlay.trailingAnchor, constant: -80),

                cancelButton.topAnchor.constraint(equalTo: overlay.safeAreaLayoutGuide.topAnchor, constant: 20),
                cancelButton.leadingAnchor.constraint(equalTo: overlay.leadingAnchor, constant: 30)
            ])

            fullscreenLoadingView = overlay
            fullscreenSpinner = spinner
            fullscreenLabel = label
            fullscreenCancelButton = cancelButton
        }

        fullscreenLabel?.text = message
        fullscreenSpinner?.startAnimating()
        fullscreenLoadingView?.isHidden = false
        if let overlay = fullscreenLoadingView {
            view.bringSubviewToFront(overlay)
        }
    }

    private func hideFullscreenLoading() {
        fullscreenSpinner?.stopAnimating()
        fullscreenLoadingView?.isHidden = true
    }

    @objc private func cancelPlaybackPreparation() {
        playTask?.cancel()
        playTask = nil
        currentSelectionId = nil
        streamingCoordinator?.stop()
        streamingCoordinator = nil
        hideFullscreenLoading()
    }

    private func playVideo(_ item: HomeVideoItem) {
        cancelPlaybackPreparation()

        let selectionId = UUID().uuidString
        currentSelectionId = selectionId
        showFullscreenLoading(message: NSLocalizedString("player.preparing", comment: ""))

        playTask = Task { @MainActor [weak self] in
            guard let self else { return }
            Task.detached { [client = self.viewModel.client, fileId = item.videoFileId] in
                _ = try? await client.downloadFile(
                    fileId: fileId,
                    limit: 0,
                    offset: 0,
                    priority: 32,
                    synchronous: false
                )
            }

            let deadline = Date().timeIntervalSince1970 + 60
            while !Task.isCancelled, selectionId == self.currentSelectionId {
                if Date().timeIntervalSince1970 > deadline { break }
                do {
                    let file = try await self.viewModel.client.getFile(fileId: item.videoFileId)
                    let local = file.local
                    let path = local.path
                    if !path.isEmpty, FileManager.default.fileExists(atPath: path) || local.canBeDownloaded {
                        let contiguousSize = max(Int64(local.downloadedPrefixSize), 0)
                        let expectedSize = max(Int64(file.size), max(Int64(local.downloadedSize), contiguousSize))
                        let info = TG.MessageMedia.VideoInfo(
                            path: path,
                            fileId: file.id,
                            expectedSize: expectedSize,
                            downloadedSize: contiguousSize,
                            isDownloadingCompleted: local.isDownloadingCompleted,
                            mimeType: item.videoMimeType
                        )
                        await self.startPlayback(with: info, selectionId: selectionId)
                        return
                    }
                } catch { }
                try? await Task.sleep(nanoseconds: 400_000_000)
            }

            guard selectionId == self.currentSelectionId else { return }
            self.hideFullscreenLoading()
            self.showAlert(
                title: NSLocalizedString("player.error.unableStartTitle", comment: ""),
                message: NSLocalizedString("player.error.prefixTimeout", comment: "")
            )
        }
    }

    @MainActor
    private func startPlayback(with info: TG.MessageMedia.VideoInfo, selectionId: String) async {
        guard selectionId == currentSelectionId else { return }

        guard !info.path.isEmpty else {
            hideFullscreenLoading()
            showAlert(title: NSLocalizedString("alert.errorTitle", comment: ""), message: NSLocalizedString("player.error.noLocalPath", comment: ""))
            return
        }

        let coordinator = VideoStreamingCoordinator(video: info, client: viewModel.client)
        streamingCoordinator?.stop()
        streamingCoordinator = coordinator
        coordinator.startDownloadIfNeeded()

        guard let playerItem = coordinator.makePlayerItem() else {
            hideFullscreenLoading()
            showAlert(title: NSLocalizedString("alert.errorTitle", comment: ""), message: NSLocalizedString("player.error.prepareStreamFailed", comment: ""))
            return
        }

        let player = AVPlayer(playerItem: playerItem)
        player.automaticallyWaitsToMinimizeStalling = false

        let vc = AVPlayerViewController()
        vc.player = player
        vc.modalPresentationStyle = .fullScreen
        vc.delegate = self

        hideFullscreenLoading()
        present(vc, animated: true) {
            player.play()
        }
    }

    private func showAlert(title: String, message: String) {
        guard presentedViewController == nil else { return }
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: NSLocalizedString("button.ok", comment: ""), style: .default))
        present(alert, animated: true)
    }

    // MARK: AVPlayerViewControllerDelegate
    func playerViewControllerWillEndFullScreenPresentation(_ playerViewController: AVPlayerViewController) {
        streamingCoordinator?.stop()
        streamingCoordinator = nil
        currentSelectionId = nil
    }
}

extension SearchViewController: UICollectionViewDelegate {
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        guard let item = dataSource.itemIdentifier(for: indexPath), item.videoFileId != 0 else { return }
        // Запускаем проигрыватель с главной страницы (переиспользуем стабильную логику HomeViewController).
        (UIApplication.shared.delegate as? AppDelegate)?.playVideoFromHome(item)
    }
}

