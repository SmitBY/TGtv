import UIKit
import TDLibKit
import AVKit
import AVFoundation
import AudioToolbox

final class HomeViewController: UIViewController, AVPlayerViewControllerDelegate {
    private let viewModel: HomeViewModel
    private let selectedChatsStore: SelectedChatsStore
    private let openSelection: () -> Void
    private let openSettingsAction: () -> Void
    private var streamingCoordinator: VideoStreamingCoordinator?
    private var fileUpdateObserver: NSObjectProtocol?
    private var currentPlaybackFileId: Int?
    private var currentPlaybackMimeType: String?
    private var isRecoveringPlayback = false
    private var isStreamFailed = false
    
    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Int64, HomeVideoItem>!
    private let emptyLabel = UILabel()
    private var backgroundImageView: UIImageView!
    private var playerObservers: [NSKeyValueObservation] = []
    private var playbackStallObserver: NSObjectProtocol?
    private let playbackProgressLabel = UILabel()
    private var playbackProgressWorkItem: DispatchWorkItem?
    private var topMenu: TopMenuView?
    private let headerContainer = UIView()
    private var headerTopConstraint: NSLayoutConstraint?
    private var focusGuideCollectionToHeader: UIFocusGuide?
    
    // Полноэкранный оверлей загрузки
    private var fullscreenLoadingView: UIView?
    private var fullscreenSpinner: UIActivityIndicatorView?
    private var fullscreenProgressLabel: UILabel?
    private var fullscreenCancelButton: UIButton?
    private var progressWatchTask: Task<Void, Never>?
    private var currentSelectionId: String?
    private var storedLeftBarButtonItem: UIBarButtonItem?
    private var storedRightBarButtonItem: UIBarButtonItem?
    private var foregroundObserver: NSObjectProtocol?
    private var backgroundDownloadTask: Task<Void, Never>?
    private var currentLoadingFileId: Int?
    private var loadingOverlayMessage: String?
    private var suppressLoadingOverlay = false
    private var lastDownloadLog: [String: (downloaded: Int64, expected: Int64)] = [:]
    private var isFullscreenLoadingVisible: Bool {
        fullscreenLoadingView?.isHidden == false
    }
    
    init(client: TDLibClient, selectedChatsStore: SelectedChatsStore, openSelection: @escaping () -> Void, openSettings: @escaping () -> Void) {
        self.viewModel = HomeViewModel(client: client, store: selectedChatsStore)
        self.selectedChatsStore = selectedChatsStore
        self.openSelection = openSelection
        self.openSettingsAction = openSettings
        super.init(nibName: nil, bundle: nil)
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    override var preferredFocusEnvironments: [UIFocusEnvironment] {
        if let menu = topMenu, let target = menu.currentFocusTarget() {
            return [target]
        }
        return super.preferredFocusEnvironments
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        restoresFocusAfterTransition = false
        setupBackground()
        setupHeaderContainer()
        setupTopMenuBar()
        setupNavigation()
        setupCollectionView()
        setupEmptyLabel()
        setupLoading()
        observeFileUpdates()
        foregroundObserver = NotificationCenter.default.addObserver(
            forName: UIScene.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleReturnFromBackground()
        }
        applySnapshot(sections: [])
        
        // КРИТИЧЕСКИ ВАЖНО: хедер должен быть над коллекцией
        view.bringSubviewToFront(headerContainer)
    }
    
    private func setupHeaderContainer() {
        headerContainer.translatesAutoresizingMaskIntoConstraints = false
        headerContainer.backgroundColor = .clear
        view.addSubview(headerContainer)
        view.bringSubviewToFront(headerContainer)
        
        headerTopConstraint = headerContainer.topAnchor.constraint(equalTo: view.topAnchor)
        
        NSLayoutConstraint.activate([
            headerTopConstraint!,
            headerContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            headerContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            headerContainer.heightAnchor.constraint(equalToConstant: 250)
        ])

        // Logo as per CSS
        let logoImageView = UIImageView()
        logoImageView.translatesAutoresizingMaskIntoConstraints = false
        logoImageView.contentMode = .scaleAspectFit
        if let logo = UIImage(named: "Logo") {
            logoImageView.image = logo
        }
        headerContainer.addSubview(logoImageView)

        NSLayoutConstraint.activate([
            logoImageView.leadingAnchor.constraint(equalTo: headerContainer.leadingAnchor, constant: 64),
            logoImageView.topAnchor.constraint(equalTo: headerContainer.topAnchor, constant: 59),
            logoImageView.widthAnchor.constraint(equalToConstant: 175),
            logoImageView.heightAnchor.constraint(equalToConstant: 66)
        ])
    }
    
    private func setupHomeFocusGuides() {
        guard let topMenu else { return }
        
        // Удаляем старые гайды если они были, чтобы не плодить их
        view.layoutGuides.filter { $0 is UIFocusGuide && $0.identifier == "HomeToMenuGuide" }.forEach { view.removeLayoutGuide($0) }
        
        // Гайд от коллекции вверх к меню
        let guide = UIFocusGuide()
        guide.identifier = "HomeToMenuGuide"
        guide.preferredFocusEnvironments = [topMenu.currentFocusTarget()].compactMap { $0 }
        view.addLayoutGuide(guide)
        
        NSLayoutConstraint.activate([
            // КРИТИЧНО: гайд должен быть СТРОГО ВЫШЕ контента (не перекрывать карточки),
            // иначе на крайних элементах tvOS может не считать его кандидатом по направлению "вверх".
            // Делаем узкую полосу перед началом контента.
            guide.topAnchor.constraint(equalTo: headerContainer.bottomAnchor, constant: -60),
            guide.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            guide.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            guide.heightAnchor.constraint(equalToConstant: 60)
        ])
        focusGuideCollectionToHeader = guide
    }
    
    deinit {
        streamingCoordinator?.stop()
        if let observer = fileUpdateObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let stall = playbackStallObserver {
            NotificationCenter.default.removeObserver(stall)
        }
        if let fg = foregroundObserver {
            NotificationCenter.default.removeObserver(fg)
        }
        progressWatchTask?.cancel()
    }
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setNavigationBarHidden(true, animated: false)
        topMenu?.setCurrentIndex(0) // Синхронизируем вкладку
        Task { @MainActor in
            await reloadData()
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        navigationController?.setNavigationBarHidden(false, animated: false)
        topMenu?.cancelPendingTransitions()
    }
    
    private func setupBackground() {
        backgroundImageView = UIImageView()
        backgroundImageView.translatesAutoresizingMaskIntoConstraints = false
        backgroundImageView.contentMode = .scaleAspectFill
        if let img = UIImage(named: "Background Image") {
            backgroundImageView.image = img
        } else if let path = Bundle.main.path(forResource: "Background Image", ofType: "png"),
                  let img = UIImage(contentsOfFile: path) {
            backgroundImageView.image = img
        } else {
            backgroundImageView.backgroundColor = UIColor(red: 0.06, green: 0.07, blue: 0.12, alpha: 1)
        }
        view.addSubview(backgroundImageView)
        NSLayoutConstraint.activate([
            backgroundImageView.topAnchor.constraint(equalTo: view.topAnchor),
            backgroundImageView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            backgroundImageView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            backgroundImageView.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])
        
        let overlay = UIView()
        overlay.translatesAutoresizingMaskIntoConstraints = false
        overlay.backgroundColor = .clear
        overlay.isUserInteractionEnabled = false
        view.addSubview(overlay)
        NSLayoutConstraint.activate([
            overlay.topAnchor.constraint(equalTo: view.topAnchor),
            overlay.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            overlay.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])
    }
    
    private func setupNavigation() {
        title = ""
        navigationItem.leftBarButtonItem = nil
        navigationItem.rightBarButtonItem = nil
    }

    private func setupTopMenuBar() {
        let menu = TopMenuView(items: ["Главная", "Каналы", "Настройки"], selectedIndex: 0)
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
        setupHomeFocusGuides() // Обновляем гайды после создания меню
    }
    
    private func handleTabSelection(_ index: Int) {
        let appDelegate = UIApplication.shared.delegate as? AppDelegate
        
        switch index {
        case 1:
            appDelegate?.showChannels()
        case 2:
            appDelegate?.showSettings()
        default:
            break
        }
    }
    
    private func setupCollectionView() {
        let layout = createLayout()
        collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        collectionView.backgroundColor = .clear
        // ВАЖНО: иначе tvOS добавляет safe-area в inset, и headerTopConstraint смещает хедер вниз
        // (из-за чего меню на Home оказывается ниже, чем на других экранах).
        collectionView.contentInsetAdjustmentBehavior = .never
        collectionView.insetsLayoutMarginsFromSafeArea = false
        collectionView.remembersLastFocusedIndexPath = true
        collectionView.delegate = self
        view.addSubview(collectionView)
        
        NSLayoutConstraint.activate([
            collectionView.topAnchor.constraint(equalTo: view.topAnchor), // Занимаем весь экран, чтобы прокрутка была видна под меню
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 40),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -40),
            collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -40)
        ])
        
        // Добавляем отступ сверху коллекции, чтобы контент не перекрывался меню изначально
        collectionView.contentInset = UIEdgeInsets(top: 250, left: 0, bottom: 0, right: 0)
        
        collectionView.register(VideoCell.self, forCellWithReuseIdentifier: "VideoCell")
        collectionView.register(ChatHeaderView.self, forSupplementaryViewOfKind: UICollectionView.elementKindSectionHeader, withReuseIdentifier: "Header")
        
        dataSource = UICollectionViewDiffableDataSource<Int64, HomeVideoItem>(collectionView: collectionView) { collectionView, indexPath, item in
            let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "VideoCell", for: indexPath) as! VideoCell
            cell.configure(
                title: item.title,
                thumbnailPath: item.thumbnailPath,
                minithumbnailData: item.minithumbnailData
            )
            return cell
        }
        
        dataSource.supplementaryViewProvider = { [weak self] collectionView, kind, indexPath in
            guard let self, kind == UICollectionView.elementKindSectionHeader else { return nil }
            let view = collectionView.dequeueReusableSupplementaryView(ofKind: kind, withReuseIdentifier: "Header", for: indexPath) as! ChatHeaderView
            if let section = self.section(at: indexPath.section) {
                view.configure(title: section.title)
            }
            return view
        }
    }
    
    private func setupEmptyLabel() {
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyLabel.textColor = .white
        emptyLabel.font = .systemFont(ofSize: 32, weight: .semibold)
        emptyLabel.textAlignment = .center
        emptyLabel.numberOfLines = 0
        emptyLabel.text = "Выберите чаты на экране списка чатов"
        view.addSubview(emptyLabel)
        
        NSLayoutConstraint.activate([
            emptyLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            emptyLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 40),
            emptyLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -40)
        ])
    }
    
    private func setupLoading() {
        playbackProgressLabel.translatesAutoresizingMaskIntoConstraints = false
        playbackProgressLabel.textColor = UIColor(white: 0.9, alpha: 1)
        playbackProgressLabel.font = .systemFont(ofSize: 22, weight: .medium)
        playbackProgressLabel.textAlignment = .center
        playbackProgressLabel.alpha = 0
        playbackProgressLabel.numberOfLines = 1
        headerContainer.addSubview(playbackProgressLabel)
        NSLayoutConstraint.activate([
            playbackProgressLabel.centerXAnchor.constraint(equalTo: headerContainer.centerXAnchor),
            playbackProgressLabel.topAnchor.constraint(equalTo: topMenu?.bottomAnchor ?? headerContainer.topAnchor, constant: 20)
        ])
    }
    
    private func createLayout() -> UICollectionViewLayout {
        // Updated sizes to match CSS: 320x173 thumbnail + text area
        let itemSize = NSCollectionLayoutSize(widthDimension: .absolute(320), heightDimension: .absolute(280))
        let item = NSCollectionLayoutItem(layoutSize: itemSize)
        item.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 10, bottom: 0, trailing: 10)
        
        let groupSize = NSCollectionLayoutSize(widthDimension: .estimated(1600), heightDimension: .absolute(280))
        let group = NSCollectionLayoutGroup.horizontal(layoutSize: groupSize, subitems: [item])
        
        let section = NSCollectionLayoutSection(group: group)
        section.orthogonalScrollingBehavior = .continuous
        section.interGroupSpacing = 20
        section.contentInsets = NSDirectionalEdgeInsets(top: 20, leading: 0, bottom: 40, trailing: 0)
        
        let headerSize = NSCollectionLayoutSize(widthDimension: .fractionalWidth(1.0), heightDimension: .absolute(60))
        let header = NSCollectionLayoutBoundarySupplementaryItem(layoutSize: headerSize, elementKind: UICollectionView.elementKindSectionHeader, alignment: .top)
        section.boundarySupplementaryItems = [header]
        
        return UICollectionViewCompositionalLayout(section: section)
    }
    
    private func applySnapshot(sections: [HomeSection]) {
        var snapshot = NSDiffableDataSourceSnapshot<Int64, HomeVideoItem>()
        for section in sections {
            snapshot.appendSections([section.chatId])
            if section.videos.isEmpty {
                snapshot.appendItems(
                    [HomeVideoItem(
                        id: section.chatId,
                        title: "Нет видео",
                        chatId: section.chatId,
                        thumbnailPath: nil,
                        minithumbnailData: nil,
                        videoFileId: 0,
                        videoLocalPath: "",
                        videoMimeType: "",
                        isVideoReady: false,
                        expectedSize: 0,
                        downloadedSize: 0,
                        isDownloadingCompleted: false
                    )],
                    toSection: section.chatId
                )
            } else {
                snapshot.appendItems(section.videos, toSection: section.chatId)
            }
        }
        dataSource.apply(snapshot, animatingDifferences: true)
    }
    
    private func section(at index: Int) -> HomeSection? {
        guard index < viewModel.sections.count else { return nil }
        return viewModel.sections[index]
    }
    
    private func updateEmptyState() {
        let hasSelection = !selectedChatsStore.load().isEmpty
        let hasContent = !viewModel.sections.isEmpty
        emptyLabel.isHidden = hasSelection && hasContent
    }

    private func setupAudioSessionIfNeeded() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .moviePlayback, options: [.allowAirPlay])
            try session.setActive(true, options: [.notifyOthersOnDeactivation])
        } catch {
        }
    }
    
    private func setLoading(_ loading: Bool) { }
    
    override func shouldUpdateFocus(in context: UIFocusUpdateContext) -> Bool {
        let heading = context.focusHeading
        let nextView = context.nextFocusedView
        
        // Если фокус в хедере
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
        
        // Управление гайдом: если фокус в хедере - гайд помогает выйти вниз,
        // если фокус в коллекции - гайд помогает зайти вверх.
        if let next = next, next.isDescendant(of: headerContainer) {
            focusGuideCollectionToHeader?.preferredFocusEnvironments = [collectionView]
        } else {
            focusGuideCollectionToHeader?.preferredFocusEnvironments = [topMenu?.currentFocusTarget()].compactMap { $0 }
        }
    }
    
    @objc private func cancelLoadingOverlay() {
        progressWatchTask?.cancel()
        progressWatchTask = nil
        streamingCoordinator?.stop()
        streamingCoordinator = nil
        currentSelectionId = nil
        suppressLoadingOverlay = true
        setLoading(false)
        hideFullscreenLoading(restoreNavigation: true)
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        // На экране загрузки перехватываем Esc/Menu, чтобы закрыть оверлей и остаться на главном экране
        if isFullscreenLoadingVisible, presses.contains(where: { $0.type == .menu || $0.key?.keyCode == .keyboardEscape }) {
            cancelLoadingOverlay()
            return
        }
        super.pressesBegan(presses, with: event)
    }

    private func observeFileUpdates() {
        fileUpdateObserver = NotificationCenter.default.addObserver(forName: .tgFileUpdated, object: nil, queue: .main) { [weak self] note in
            guard let self, let file = note.object as? TDLibKit.File else { return }
            streamingCoordinator?.handleFileUpdate(file)

            let isCurrent = file.id == (currentLoadingFileId ?? currentPlaybackFileId ?? -1)
            guard isCurrent else { return }

            let local = file.local
            // ВАЖНО: для стриминга и корректного UI ориентируемся на непрерывный префикс.
            // local.downloadedSize может отражать "дырявую" загрузку/предвыделение и давать 100% при isDownloadingCompleted=false.
            let prefix = max(Int64(local.downloadedPrefixSize), 0)
            let downloadedForUI: Int64 = local.isDownloadingCompleted
                ? max(prefix, Int64(local.downloadedSize))
                : prefix
            let expectedRaw = Int64(file.size)
            let expectedForUI = expectedRaw > 0 ? expectedRaw : max(downloadedForUI, 0)
            let progress = expectedForUI > 0 ? Double(downloadedForUI) / Double(expectedForUI) : nil

            logDownloadProgress(
                fileId: file.id,
                downloaded: downloadedForUI,
                expected: expectedForUI,
                label: "file-update"
            )

            if isFullscreenLoadingVisible {
                showFullscreenLoading(progress: progress, message: loadingOverlayMessage)
            }
        }
    }
    
    private func reloadData() async {
        setLoading(true)
        await viewModel.refresh()
        setLoading(false)
        applySnapshot(sections: viewModel.sections)
        updateEmptyState()
    }
    
    @objc private func openChatSelection() {
        openSelection()
    }
    
    @objc private func openSettings() {
        openSettingsAction()
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        let offset = scrollView.contentOffset.y
        headerTopConstraint?.constant = -(offset + scrollView.contentInset.top)
        
        // Показываем/скрываем хедер если нужно, но здесь он просто уходит вверх
    }
}

// MARK: - Cells & Headers

final class VideoCell: UICollectionViewCell {
    private let titleLabel = UILabel()
    private let backgroundCard = UIView()
    private let thumbnailView = UIImageView()
    private let placeholderLabel = UILabel()
    private let innerStrokeView = UIView() // Added for inner stroke
    
    override init(frame: CGRect) {
        super.init(frame: frame)
        setupUI()
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        coordinator.addCoordinatedAnimations {
            if self.isFocused {
                self.backgroundCard.transform = CGAffineTransform(scaleX: 1.1, y: 1.1)
                self.innerStrokeView.layer.borderColor = UIColor.white.withAlphaComponent(0.5).cgColor
                self.innerStrokeView.layer.borderWidth = 2
            } else {
                self.backgroundCard.transform = .identity
                self.innerStrokeView.layer.borderColor = UIColor.white.withAlphaComponent(0.16).cgColor
                self.innerStrokeView.layer.borderWidth = 0.5
            }
        }
    }
    
    func configure(title: String, thumbnailPath: String?, minithumbnailData: Data?) {
        titleLabel.text = title
        thumbnailView.image = nil
        placeholderLabel.isHidden = true
        
        if let path = thumbnailPath, !path.isEmpty, FileManager.default.fileExists(atPath: path), let image = UIImage(contentsOfFile: path) {
            thumbnailView.image = image
            return
        }
        
        if let data = minithumbnailData, let image = UIImage(data: data) {
            thumbnailView.image = image
            return
        }
        
        placeholderLabel.isHidden = false
    }
    
    override func prepareForReuse() {
        super.prepareForReuse()
        thumbnailView.image = nil
        placeholderLabel.isHidden = true
    }
    
    private func setupUI() {
        backgroundCard.translatesAutoresizingMaskIntoConstraints = false
        backgroundCard.layer.cornerRadius = 12
        backgroundCard.backgroundColor = UIColor(red: 42/255, green: 42/255, blue: 42/255, alpha: 1.0) // #2A2A2A
        
        // Shadow as per CSS
        backgroundCard.layer.shadowColor = UIColor.black.cgColor
        backgroundCard.layer.shadowOpacity = 0.4
        backgroundCard.layer.shadowOffset = CGSize(width: 0, height: 4)
        backgroundCard.layer.shadowRadius = 12
        
        contentView.addSubview(backgroundCard)
        
        thumbnailView.translatesAutoresizingMaskIntoConstraints = false
        thumbnailView.contentMode = .scaleAspectFill
        thumbnailView.clipsToBounds = true
        thumbnailView.layer.cornerRadius = 12
        backgroundCard.addSubview(thumbnailView)
        
        innerStrokeView.translatesAutoresizingMaskIntoConstraints = false
        innerStrokeView.layer.cornerRadius = 12
        innerStrokeView.layer.borderWidth = 0.5
        innerStrokeView.layer.borderColor = UIColor.white.withAlphaComponent(0.16).cgColor
        innerStrokeView.isUserInteractionEnabled = false
        backgroundCard.addSubview(innerStrokeView)
        
        placeholderLabel.translatesAutoresizingMaskIntoConstraints = false
        placeholderLabel.text = "Нет превью"
        placeholderLabel.textColor = UIColor(white: 1, alpha: 0.6)
        placeholderLabel.font = .systemFont(ofSize: 16, weight: .medium)
        placeholderLabel.textAlignment = .center
        placeholderLabel.isHidden = true
        backgroundCard.addSubview(placeholderLabel)
        
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.textColor = .white
        titleLabel.font = .systemFont(ofSize: 25, weight: .semibold) // SF Pro 25px
        titleLabel.numberOfLines = 2
        contentView.addSubview(titleLabel)
        
        NSLayoutConstraint.activate([
            backgroundCard.topAnchor.constraint(equalTo: contentView.topAnchor),
            backgroundCard.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            backgroundCard.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            backgroundCard.heightAnchor.constraint(equalToConstant: 173), // 173px height as per CSS
            
            thumbnailView.topAnchor.constraint(equalTo: backgroundCard.topAnchor),
            thumbnailView.leadingAnchor.constraint(equalTo: backgroundCard.leadingAnchor),
            thumbnailView.trailingAnchor.constraint(equalTo: backgroundCard.trailingAnchor),
            thumbnailView.bottomAnchor.constraint(equalTo: backgroundCard.bottomAnchor),

            innerStrokeView.topAnchor.constraint(equalTo: backgroundCard.topAnchor),
            innerStrokeView.leadingAnchor.constraint(equalTo: backgroundCard.leadingAnchor),
            innerStrokeView.trailingAnchor.constraint(equalTo: backgroundCard.trailingAnchor),
            innerStrokeView.bottomAnchor.constraint(equalTo: backgroundCard.bottomAnchor),
            
            placeholderLabel.centerXAnchor.constraint(equalTo: thumbnailView.centerXAnchor),
            placeholderLabel.centerYAnchor.constraint(equalTo: thumbnailView.centerYAnchor),
            
            titleLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 4),
            titleLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -4),
            titleLabel.topAnchor.constraint(equalTo: backgroundCard.bottomAnchor, constant: 12)
        ])
    }
}

// MARK: - Collection Delegate

extension HomeViewController: UICollectionViewDelegate {
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        guard let item = dataSource.itemIdentifier(for: indexPath), item.videoFileId != 0 else { return }
        playVideo(item)
    }
    
    private func withTimeoutVideoInfo(seconds: Double, operation: @escaping () async -> TG.MessageMedia.VideoInfo?) async -> TG.MessageMedia.VideoInfo? {
        await withTaskGroup(of: TG.MessageMedia.VideoInfo?.self) { group in
            group.addTask { await operation() }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                return nil
            }
            let result = await group.next() ?? nil
            group.cancelAll()
            return result
        }
    }

    private func waitForPrefix(
        item: HomeVideoItem,
        selectionId: String?,
        minPrefixBytes: Int64,
        timeoutSeconds: Double,
        message: String
    ) async -> TG.MessageMedia.VideoInfo? {
        let deadline = Date().timeIntervalSince1970 + timeoutSeconds
        while !Task.isCancelled {
            if let selectionId, selectionId != currentSelectionId { return nil }
            if let info = await viewModel.fetchLatestVideoInfo(for: item) {
                if info.isDownloadingCompleted || info.downloadedSize >= minPrefixBytes {
                    return info
                }
                let progress = info.expectedSize > 0 ? Double(info.downloadedSize) / Double(info.expectedSize) : 0
                await MainActor.run {
                    self.showFullscreenLoading(progress: progress, message: message)
                }
            }
            if Date().timeIntervalSince1970 > deadline { return nil }
            try? await Task.sleep(nanoseconds: 400_000_000)
        }
        return nil
    }

    private func waitForMoovOrThreshold(
        item: HomeVideoItem,
        selectionId: String?,
        maxPrefixBytes: Int64,
        timeoutSeconds: Double,
        message: String
    ) async -> (info: TG.MessageMedia.VideoInfo, streamable: Bool)? {
        let deadline = Date().timeIntervalSince1970 + timeoutSeconds
        while !Task.isCancelled {
            if let selectionId, selectionId != currentSelectionId { return nil }
            guard let info = await viewModel.fetchLatestVideoInfo(for: item) else {
                if Date().timeIntervalSince1970 > deadline { return nil }
                try? await Task.sleep(nanoseconds: 400_000_000)
                continue
            }

            if info.isDownloadingCompleted {
                return (info, true)
            }

            let progress = info.expectedSize > 0 ? Double(info.downloadedSize) / Double(info.expectedSize) : 0
            await MainActor.run {
                self.showFullscreenLoading(progress: progress, message: message)
            }

            let scanBytes = min(max(info.downloadedSize, 0), maxPrefixBytes)
            if scanBytes >= 12 {
                let ok = isMP4StreamableByPrefix(
                    filePath: info.path,
                    prefixBytes: scanBytes,
                    maxScanBytes: Int(scanBytes)
                )
                if ok {
                    return (info, true)
                }
            }

            if info.downloadedSize >= maxPrefixBytes {
                return (info, false)
            }

            if Date().timeIntervalSince1970 > deadline { return nil }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        return nil
    }
    
    private func playVideo(_ item: HomeVideoItem) {
        let selectionId = UUID().uuidString
        currentSelectionId = selectionId
        suppressLoadingOverlay = false
        backgroundDownloadTask?.cancel()
        backgroundDownloadTask = nil
        loadingOverlayMessage = nil
        setLoading(true)
        showFullscreenLoading(progress: nil, message: "Подготовка…")
        progressWatchTask?.cancel()
        
        progressWatchTask = Task { @MainActor [weak self] in
            guard let self else { return }
            // На первом запуске TDLib может не сразу отдать local.path.
            // НЕ показываем алерт/ошибку — просто ждём и держим оверлей "Подготовка…".
            var info: TG.MessageMedia.VideoInfo?
            var attempts = 0
            while !Task.isCancelled, selectionId == self.currentSelectionId {
                attempts += 1
                info = await self.viewModel.fetchLatestVideoInfo(for: item)
                if info != nil { break }
                // каждые ~5 секунд обновляем текст, чтобы было понятно что идёт ожидание
                if attempts % 10 == 0 {
                    self.showFullscreenLoading(progress: nil, message: "Подготовка…")
                }
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
            guard let info, selectionId == self.currentSelectionId else { return }

            currentLoadingFileId = info.fileId
            
            // Для потокового старта нужен небольшой непрерывный префикс, иначе moov-проверка и AVPlayer
            // могут "решить", что стрим невозможен, и мы уйдём в полный download слишком рано.
            let minPrefixForStreaming: Int64 = 2_000_000
            if !info.isDownloadingCompleted, info.downloadedSize < minPrefixForStreaming {
                let progress = info.expectedSize > 0 ? Double(info.downloadedSize) / Double(info.expectedSize) : 0
                self.showFullscreenLoading(progress: progress, message: "Подготовка потокового воспроизведения…")
                Task.detached { [client = self.viewModel.client] in
                    _ = try? await client.downloadFile(
                        fileId: info.fileId,
                        limit: 0,
                        offset: 0,
                        priority: 32,
                        synchronous: false
                    )
                }
                await self.pollPrefixAndPlay(item: item, selectionId: selectionId, minPrefixBytes: minPrefixForStreaming)
                return
            }
            
            await self.startPlayback(with: info, fallbackItem: item, selectionId: selectionId)
        }
    }

    private func pollPrefixAndPlay(item: HomeVideoItem, selectionId: String, minPrefixBytes: Int64) async {
        var attempts = 0
        while !Task.isCancelled {
            attempts += 1
            if let info = await viewModel.fetchLatestVideoInfo(for: item) {
                let progress = info.expectedSize > 0 ? Double(info.downloadedSize) / Double(info.expectedSize) : 0
                logDownloadProgress(
                    fileId: info.fileId,
                    downloaded: info.downloadedSize,
                    expected: info.expectedSize,
                    label: "pollPrefix"
                )
                await MainActor.run { self.showFullscreenLoading(progress: progress) }
                
                if info.isDownloadingCompleted || info.downloadedSize >= minPrefixBytes {
                    await MainActor.run {
                        _ = Task { [weak self] in
                            await self?.startPlayback(with: info, fallbackItem: item, selectionId: selectionId)
                        }
                    }
                    return
                }
            }
            if attempts > 120 { break } // ~60 секунд
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        await MainActor.run {
            self.setLoading(false)
            self.hideFullscreenLoading()
            print("[stream] prefix timeout for fileId=\(item.videoFileId)")
            self.showAlert(title: "Не удалось начать воспроизведение", message: "Не удалось получить данные для потокового воспроизведения (префикс не загрузился). Проверьте сеть и попробуйте ещё раз.")
        }
    }

    @MainActor
    private func startPlayback(with info: TG.MessageMedia.VideoInfo, fallbackItem: HomeVideoItem, selectionId: String?) async {
        var info = info
        setupAudioSessionIfNeeded()
        
        _ = try? FileManager.default.attributesOfItem(atPath: info.path)

        if let selectionId, selectionId != currentSelectionId {
            return
        }

        // Если файл уже загружен полностью — обычное воспроизведение
        if info.isDownloadingCompleted && FileManager.default.fileExists(atPath: info.path) {
            currentPlaybackFileId = info.fileId
            currentPlaybackMimeType = info.mimeType
            let playableURL = await ensurePlayableLocalURL(for: info) ?? URL(fileURLWithPath: info.path)
            let asset = AVURLAsset(url: playableURL, options: assetOptions(for: info.mimeType))
            await logAssetInfo(asset, fileId: info.fileId, label: "full-download")
            let playerItem = AVPlayerItem(asset: asset)
            let player = AVPlayer(playerItem: playerItem)
            player.automaticallyWaitsToMinimizeStalling = false
            player.volume = 1.0
            player.isMuted = false
            self.presentOrReusePlayer(player: player, item: playerItem, selectionId: selectionId) { [weak self] in
                self?.setLoading(false)
                self?.hideFullscreenLoading()
            }
            return
        }
        
        // Потоковое воспроизведение
        guard !info.path.isEmpty else {
            self.setLoading(false)
            self.hideFullscreenLoading()
            self.showAlert(title: "Ошибка", message: "Нет локального пути к файлу видео.")
            return
        }

        // Гарантируем существование родительской директории и самого файла.
        if let ensuredPath = ensureLocalPlayableFilePath(originalPath: info.path, fileId: info.fileId) {
            info = TG.MessageMedia.VideoInfo(
                path: ensuredPath,
                fileId: info.fileId,
                expectedSize: info.expectedSize,
                downloadedSize: info.downloadedSize,
                isDownloadingCompleted: info.isDownloadingCompleted,
                mimeType: info.mimeType
            )
        }

        guard FileManager.default.fileExists(atPath: info.path) else {
            self.setLoading(false)
            self.hideFullscreenLoading()
            print("[stream] local file unavailable fileId=\(info.fileId) path=\(info.path)")
            self.showAlert(title: "Ошибка", message: "Локальный файл недоступен.")
            return
        }
        
        // Проверка наличия moov в префиксе.
        // ВАЖНО: не уходим в full-download "слишком рано".
        // По твоим логам moov появляется только на десятках мегабайт (например ~58MB),
        // поэтому ждём его до порога (96MB) и проверяем по мере роста префикса.
        if !info.isDownloadingCompleted {
            Task.detached { [client = self.viewModel.client, fileId = info.fileId] in
                _ = try? await client.downloadFile(
                    fileId: fileId,
                    limit: 0,
                    offset: 0,
                    priority: 32,
                    synchronous: false
                )
            }

            let maxMoovWaitBytes: Int64 = 96_000_000
            if let result = await waitForMoovOrThreshold(
                item: fallbackItem,
                selectionId: selectionId,
                maxPrefixBytes: maxMoovWaitBytes,
                timeoutSeconds: 180,
                message: "Подготовка потокового воспроизведения…"
            ) {
                info = result.info
                if !result.streamable {
                    self.showFullscreenLoading(
                        progress: info.expectedSize > 0 ? Double(info.downloadedSize) / Double(info.expectedSize) : nil,
                        message: "Это видео не поддерживает потоковое воспроизведение. Идёт загрузка..."
                    )
                    backgroundDownloadTask?.cancel()
                    backgroundDownloadTask = Task { [weak self] in
                        guard let self else { return }
                        defer { backgroundDownloadTask = nil }
                        let full = await self.downloadFullFileIfNeeded(
                            fileId: info.fileId,
                            progressHandler: { progress in
                                await MainActor.run {
                                    self.showFullscreenLoading(
                                        progress: progress,
                                        message: "Это видео не поддерживает потоковое воспроизведение. Идёт загрузка..."
                                    )
                                }
                            }
                        )
                        guard let full else {
                            await MainActor.run {
                                self.setLoading(false)
                                self.hideFullscreenLoading()
                            }
                            return
                        }
                        if selectionId != self.currentSelectionId { return }
                        let updatedInfo = TG.MessageMedia.VideoInfo(
                            path: full.local.path,
                            fileId: full.id,
                            expectedSize: Int64(full.size),
                            downloadedSize: max(Int64(full.local.downloadedSize), Int64(full.local.downloadedPrefixSize)),
                            isDownloadingCompleted: full.local.isDownloadingCompleted,
                            mimeType: info.mimeType
                        )
                        await MainActor.run {
                            self.showFullscreenLoading(progress: 1, message: "Загрузка завершена. Запуск плеера...")
                        }
                        await self.startPlayback(with: updatedInfo, fallbackItem: fallbackItem, selectionId: selectionId)
                    }
                    return
                }
            }
        }
        
        let coordinator = VideoStreamingCoordinator(video: info, client: viewModel.client)
        streamingCoordinator?.stop()
        streamingCoordinator = coordinator
        coordinator.startDownloadIfNeeded()
        
        guard let playerItem = coordinator.makePlayerItem() else {
            self.setLoading(false)
            self.hideFullscreenLoading()
            self.showAlert(title: "Ошибка", message: "Не удалось подготовить потоковое воспроизведение.")
            print("[stream] makePlayerItem failed fileId=\(info.fileId) downloaded=\(info.downloadedSize) expected=\(info.expectedSize) completed=\(info.isDownloadingCompleted)")
            return
        }
        currentPlaybackFileId = info.fileId
        currentPlaybackMimeType = info.mimeType
        isStreamFailed = false
        print("[stream] start streaming fileId=\(info.fileId) downloaded=\(info.downloadedSize) expected=\(info.expectedSize) completed=\(info.isDownloadingCompleted) pathExists=\(FileManager.default.fileExists(atPath: info.path))")
        NotificationCenter.default.addObserver(forName: .AVPlayerItemFailedToPlayToEndTime, object: playerItem, queue: .main) { [weak self] note in
            if let err = (note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? NSError) {
                print("[stream] FailedToPlayToEnd fileId=\(self?.currentPlaybackFileId ?? -1) err=\(err.domain) code=\(err.code) \(err.localizedDescription)")
            } else {
                print("[stream] FailedToPlayToEnd fileId=\(self?.currentPlaybackFileId ?? -1) err=nil")
            }
        }
        
        let player = AVPlayer(playerItem: playerItem)
        player.automaticallyWaitsToMinimizeStalling = false
        player.volume = 1.0
        player.isMuted = false
        playerItem.preferredForwardBufferDuration = 0
        // Убираем оверлей ДО показа AVPlayerViewController, чтобы он не "просвечивал" при overFullScreen.
        self.hideFullscreenLoading()
        self.presentOrReusePlayer(player: player, item: playerItem, selectionId: selectionId) { [weak self] in
            self?.setLoading(false)
            self?.hideFullscreenLoading()
        }

        // Если item надолго остаётся в .unknown — это почти всегда "moov не доступен" или проблемы с диапазонами.
        // Даём короткий таймаут и уходим в фоллбэк (полная загрузка + replace item).
        Task { [weak self, weak player] in
            guard let self else { return }
            let fileId = info.fileId
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            await MainActor.run {
                guard selectionId == self.currentSelectionId else { return }
                guard self.currentPlaybackFileId == fileId else { return }
                guard playerItem.status == .unknown else { return }
                print("[stream] unknown-timeout fileId=\(fileId) -> fallback full download")
            }
            guard selectionId == self.currentSelectionId else { return }
            guard self.currentPlaybackFileId == fileId else { return }
            guard playerItem.status == .unknown else { return }
            guard let full = await self.downloadFullFileIfNeeded(fileId: fileId) else { return }
            if selectionId != self.currentSelectionId { return }
            let updatedInfo = TG.MessageMedia.VideoInfo(
                path: full.local.path,
                fileId: full.id,
                expectedSize: Int64(full.size),
                downloadedSize: max(Int64(full.local.downloadedSize), Int64(full.local.downloadedPrefixSize)),
                isDownloadingCompleted: full.local.isDownloadingCompleted,
                mimeType: info.mimeType
            )
            guard let playable = await self.ensurePlayableLocalURL(for: updatedInfo) else { return }
            await MainActor.run {
                let asset = AVURLAsset(url: playable, options: self.assetOptions(for: info.mimeType))
                let newItem = AVPlayerItem(asset: asset)
                self.streamingCoordinator?.stop()
                self.streamingCoordinator = nil
                player?.replaceCurrentItem(with: newItem)
                player?.play()
                if let currentVC = self.presentedViewController as? AVPlayerViewController {
                    currentVC.player = player
                    self.attachPlaybackObservers(player: player ?? AVPlayer(), item: newItem, controller: currentVC)
                }
            }
        }
        
        // Примечание: раньше мы всегда догружали файл полностью в фоне.
        // Это создавало ощущение "сразу пошла полная загрузка", даже когда стрим уже запущен.
        // Полную загрузку теперь делаем только по необходимости (ошибка/unknown-timeout/неподдерживаемый контейнер).
    }

    private func presentOrReusePlayer(player: AVPlayer, item: AVPlayerItem, selectionId: String?, onPresented: (() -> Void)? = nil) {
        // защита от устаревшего выбора
        if let selectionId, selectionId != currentSelectionId {
            return
        }
        
        if let currentVC = presentedViewController as? AVPlayerViewController {
            currentVC.player = player
            attachPlaybackObservers(player: player, item: item, controller: currentVC)
            player.play()
            onPresented?()
            return
        }
        let vc = AVPlayerViewController()
        vc.player = player
        vc.modalPresentationStyle = .fullScreen
        vc.delegate = self
        present(vc, animated: true) { [weak self, weak vc] in
            guard let self, let vc else { return }
            // повторная проверка выбора
            if let selectionId, selectionId != self.currentSelectionId {
                return
            }
            self.attachPlaybackObservers(player: player, item: item, controller: vc)
            onPresented?()
        }
    }
    
    // MARK: AVPlayerViewControllerDelegate
    func playerViewControllerWillEndFullScreenPresentation(_ playerViewController: AVPlayerViewController) {
        streamingCoordinator?.stop()
        streamingCoordinator = nil
        currentPlaybackFileId = nil
        currentPlaybackMimeType = nil
        isRecoveringPlayback = false
        hideFullscreenLoading()
        restoreNavigationItems()
    }
    
    private func showAlert(title: String, message: String) {
        // Если уже что-то показано (алерт/плеер) — не показываем, чтобы избежать гонок
        guard presentedViewController == nil else { return }
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }
    
    private func handleReturnFromBackground() {
        progressWatchTask?.cancel()
        progressWatchTask = nil
        streamingCoordinator?.stop()
        streamingCoordinator = nil
        currentSelectionId = nil
        suppressLoadingOverlay = true
        setLoading(false)
        hideFullscreenLoading()
    }

    private func showFullscreenLoading(progress: Double?, message: String? = nil) {
        if let message {
            loadingOverlayMessage = message
        }
        if suppressLoadingOverlay { return }
        if fullscreenLoadingView == nil {
            let overlay = UIView()
            overlay.translatesAutoresizingMaskIntoConstraints = false
            overlay.backgroundColor = UIColor(white: 0, alpha: 0.6)
            
            // Фоновая картинка (Back) под спиннером
            if let backImage = UIImage(named: "Back") ?? {
                if let path = Bundle.main.path(forResource: "back", ofType: "png") {
                    return UIImage(contentsOfFile: path)
                }
                return nil
            }() {
                let backView = UIImageView(image: backImage)
                backView.translatesAutoresizingMaskIntoConstraints = false
                backView.contentMode = .scaleAspectFill
                backView.clipsToBounds = true
                overlay.addSubview(backView)
                NSLayoutConstraint.activate([
                    backView.topAnchor.constraint(equalTo: overlay.topAnchor),
                    backView.bottomAnchor.constraint(equalTo: overlay.bottomAnchor),
                    backView.leadingAnchor.constraint(equalTo: overlay.leadingAnchor),
                    backView.trailingAnchor.constraint(equalTo: overlay.trailingAnchor)
                ])
            }
            
            let spinner = UIActivityIndicatorView(style: .large)
            spinner.translatesAutoresizingMaskIntoConstraints = false
            spinner.startAnimating()
            
            let label = UILabel()
            label.translatesAutoresizingMaskIntoConstraints = false
            label.textColor = .white
            label.font = .systemFont(ofSize: 22, weight: .medium)
            label.textAlignment = .center
            label.numberOfLines = 1

            let cancelButton = UIButton(type: .system)
            cancelButton.translatesAutoresizingMaskIntoConstraints = false
            cancelButton.setTitle("Назад", for: .normal)
            cancelButton.titleLabel?.font = .systemFont(ofSize: 22, weight: .semibold)
            cancelButton.addTarget(self, action: #selector(cancelLoadingOverlay), for: .primaryActionTriggered)
            
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

                cancelButton.topAnchor.constraint(equalTo: overlay.safeAreaLayoutGuide.topAnchor, constant: 20),
                cancelButton.leadingAnchor.constraint(equalTo: overlay.leadingAnchor, constant: 30)
            ])
            
            fullscreenLoadingView = overlay
            fullscreenSpinner = spinner
            fullscreenProgressLabel = label
            fullscreenCancelButton = cancelButton
        }
        
        if let overlay = fullscreenLoadingView {
            view.bringSubviewToFront(overlay)
            overlay.isHidden = false
            fullscreenSpinner?.startAnimating()
        }

        // скрываем кнопки навигации на время загрузки
        if storedLeftBarButtonItem == nil { storedLeftBarButtonItem = navigationItem.leftBarButtonItem }
        if storedRightBarButtonItem == nil { storedRightBarButtonItem = navigationItem.rightBarButtonItem }
        navigationItem.leftBarButtonItem = nil
        navigationItem.rightBarButtonItem = nil
        
        guard let label = fullscreenProgressLabel else { return }
        let progressText: String? = {
            guard let progress else { return nil }
            let p = max(0, min(1, progress))
            return String(format: "Загружено %.0f%%", p * 100)
        }()
        if let msg = message, let progressText {
            label.text = "\(msg)\n\(progressText)"
        } else if let msg = message {
            label.text = msg
        } else if let progressText {
            label.text = progressText
        } else {
            label.text = "Загрузка..."
        }
        label.numberOfLines = 0
    }
    
    private func hideFullscreenLoading(restoreNavigation: Bool = true) {
        fullscreenSpinner?.stopAnimating()
        fullscreenLoadingView?.isHidden = true
        loadingOverlayMessage = nil
        if restoreNavigation {
            currentLoadingFileId = nil
            restoreNavigationItems()
        }
    }

    private func restoreNavigationItems() {
        navigationItem.leftBarButtonItem = storedLeftBarButtonItem
        navigationItem.rightBarButtonItem = storedRightBarButtonItem
        storedLeftBarButtonItem = nil
        storedRightBarButtonItem = nil
    }
    
    private func showDownloadProgress(_ progress: Double) {
        let percent = max(0, min(1, progress))
        let text = String(format: "Загружено %.0f%%", percent * 100)
        playbackProgressWorkItem?.cancel()
        playbackProgressLabel.text = text
        UIView.animate(withDuration: 0.15) {
            self.playbackProgressLabel.alpha = 1
        }
        let work = DispatchWorkItem { [weak self] in
            UIView.animate(withDuration: 0.2) {
                self?.playbackProgressLabel.alpha = 0
            }
        }
        playbackProgressWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5, execute: work)
    }
    
    private func attachPlaybackObservers(player: AVPlayer, item: AVPlayerItem, controller: AVPlayerViewController) {
        // Сбрасываем старые наблюдатели
        playerObservers.forEach { $0.invalidate() }
        playerObservers.removeAll()
        if let stall = playbackStallObserver {
            NotificationCenter.default.removeObserver(stall)
            playbackStallObserver = nil
        }
        
        // Стартуем немедленно, а далее следим за готовностью
        player.play()
        
        let statusObs = item.observe(\.status, options: [.initial, .new]) { [weak self, weak player, weak controller] item, change in
            guard let self else { return }
            DispatchQueue.main.async {
                switch item.status {
                case .readyToPlay:
                    print("[stream] playerItem ready fileId=\(self.currentPlaybackFileId ?? -1)")
                    player?.play()
                case .failed:
                    let message = item.error?.localizedDescription ?? "Неизвестная ошибка воспроизведения"
                    let err = item.error as NSError?
                print("[stream] playerItem failed fileId=\(self.currentPlaybackFileId ?? -1) err=\(err?.domain ?? "nil") code=\(err?.code ?? 0) \(message)")
                    if self.isRecoveringPlayback || self.isStreamFailed { return }
                    self.isStreamFailed = true
                    self.isRecoveringPlayback = true
                    Task { [weak self, weak player, weak controller] in
                        guard let self else { return }
                        defer { self.isRecoveringPlayback = false }
                        guard let fileId = self.currentPlaybackFileId else {
                            await MainActor.run {
                                print("[stream] playerItem failed without fileId: \(message)")
                            }
                            return
                        }
                        // Ждём полной загрузки, если файл не докачан
                        if let file = try? await self.viewModel.client.getFile(fileId: fileId) {
                            print("[stream] recovery check fileId=\(fileId) downloadedPrefix=\(max(file.local.downloadedPrefixSize, 0)) expected=\(file.size) completed=\(file.local.isDownloadingCompleted)")
                        }
                        guard let full = await self.downloadFullFileIfNeeded(fileId: fileId) else { return }
                        print("[stream] recovery full fileId=\(fileId) downloaded=\(full.local.downloadedSize) expected=\(full.size) completed=\(full.local.isDownloadingCompleted)")
                        let updatedInfo = TG.MessageMedia.VideoInfo(
                            path: full.local.path,
                            fileId: full.id,
                            expectedSize: Int64(full.size),
                            downloadedSize: max(Int64(full.local.downloadedSize), Int64(full.local.downloadedPrefixSize)),
                            isDownloadingCompleted: full.local.isDownloadingCompleted,
                            mimeType: self.currentPlaybackMimeType ?? ""
                        )
                        guard let playable = await self.ensurePlayableLocalURL(for: updatedInfo) else { return }
                        await MainActor.run {
                            let asset = AVURLAsset(url: playable, options: self.assetOptions(for: updatedInfo.mimeType))
                            let newItem = AVPlayerItem(asset: asset)
                            self.streamingCoordinator?.stop()
                            self.streamingCoordinator = nil
                            print("[stream] playerItem recovered fileId=\(fileId)")
                            if let player {
                                player.replaceCurrentItem(with: newItem)
                                player.play()
                                if let controller {
                                    controller.player = player
                                    self.attachPlaybackObservers(player: player, item: newItem, controller: controller)
                                }
                            }
                        }
                    }
                default:
                    if change.kind == .setting {
                        print("[stream] playerItem status=\(item.status.rawValue) fileId=\(self.currentPlaybackFileId ?? -1)")
                    }
                    break
                }
            }
        }
        
        let keepUpObs = item.observe(\.isPlaybackLikelyToKeepUp, options: [.new]) { [weak player] item, _ in
            if item.isPlaybackLikelyToKeepUp {
                player?.play()
            }
        }
        
        let bufferFullObs = item.observe(\.isPlaybackBufferFull, options: [.new]) { [weak player] item, _ in
            if item.isPlaybackBufferFull {
                player?.play()
            }
        }
        
        playerObservers.append(contentsOf: [statusObs, keepUpObs, bufferFullObs])
        
        playbackStallObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemPlaybackStalled,
            object: item,
            queue: .main
        ) { [weak player] _ in
            player?.play()
        }
        
        NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] note in
            if let err = (note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? NSError) {
                print("[stream] FailedToPlayToEnd fileId=\(self?.currentPlaybackFileId ?? -1) err=\(err.domain) code=\(err.code) \(err.localizedDescription)")
            } else {
                print("[stream] FailedToPlayToEnd fileId=\(self?.currentPlaybackFileId ?? -1) err=nil")
            }
        }
        
        NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            self?.streamingCoordinator?.stop()
            self?.streamingCoordinator = nil
        }
    }

    // MARK: - Local file ensure
    private func ensureLocalPlayableFilePath(originalPath: String, fileId: Int) -> String? {
        let fm = FileManager.default

        func ensure(atPath path: String) -> Bool {
            let dir = URL(fileURLWithPath: path).deletingLastPathComponent()
            do {
                try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            } catch {
                return false
            }
            if fm.fileExists(atPath: path) { return true }
            return fm.createFile(atPath: path, contents: nil)
        }

        // 1) Пробуем оригинальный путь (tdlib_files/...)
        if ensure(atPath: originalPath) { return originalPath }

        // 2) Фоллбэк в caches (всегда должен быть доступен)
        if let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask).first {
            let dir = caches.appendingPathComponent("tgtv_stream_tmp", isDirectory: true)
            let fallback = dir.appendingPathComponent("\(fileId).mp4").path
            if ensure(atPath: fallback) {
                print("[stream] fallback local path fileId=\(fileId) path=\(fallback)")
                return fallback
            }
        }
        return nil
    }

    // MARK: - MP4 moov check (быстрая эвристика)
    private func isMP4StreamableByPrefix(filePath: String, prefixBytes: Int64, maxScanBytes: Int) -> Bool {
        guard prefixBytes > 0 else { return false }
        guard FileManager.default.fileExists(atPath: filePath) else { return false }
        let toRead = max(0, min(Int(prefixBytes), maxScanBytes))
        guard toRead >= 12 else { return false }

        let url = URL(fileURLWithPath: filePath)
        let data: Data
        do {
            let h = try FileHandle(forReadingFrom: url)
            defer { try? h.close() }
            data = try h.read(upToCount: toRead) ?? Data()
        } catch {
            return false
        }
        guard data.count >= 12 else { return false }

        // Парсим MP4 боксы по заголовкам: size(4) + type(4), size=1 => extended size(8)
        // Считаем "streamable", если встретили moov до mdat и целиком в пределах префикса.
        var i = 0
        while i + 8 <= data.count {
            let size32 = readBEUInt32(data, offset: i)
            let type = readFourCC(data, offset: i + 4)
            var boxSize = Int(size32)
            var headerSize = 8
            if boxSize == 1 {
                // extended size
                if i + 16 > data.count { return false }
                let size64 = readBEUInt64(data, offset: i + 8)
                if size64 > UInt64(Int.max) { return false }
                boxSize = Int(size64)
                headerSize = 16
            } else if boxSize == 0 {
                // до конца файла — для префикса непредсказуемо
                return false
            }
            if boxSize < headerSize { return false }
            if type == "moov" { return true }
            if type == "mdat" { return false }

            let next = i + boxSize
            if next <= i { return false }
            if next > data.count { return false }
            i = next
        }
        return false
    }

    private func readBEUInt32(_ data: Data, offset: Int) -> UInt32 {
        let b0 = UInt32(data[offset])
        let b1 = UInt32(data[offset + 1])
        let b2 = UInt32(data[offset + 2])
        let b3 = UInt32(data[offset + 3])
        return (b0 << 24) | (b1 << 16) | (b2 << 8) | b3
    }

    private func readBEUInt64(_ data: Data, offset: Int) -> UInt64 {
        var v: UInt64 = 0
        for j in 0..<8 {
            v = (v << 8) | UInt64(data[offset + j])
        }
        return v
    }

    private func readFourCC(_ data: Data, offset: Int) -> String {
        guard offset + 4 <= data.count else { return "" }
        let slice = data[offset..<(offset + 4)]
        return String(bytes: slice, encoding: .ascii) ?? ""
    }
    
    // MARK: Проверка аудио и перекодирование
    
    private func ensurePlayableLocalURL(for info: TG.MessageMedia.VideoInfo) async -> URL? {
        var path = info.path
        if (!info.isDownloadingCompleted || !FileManager.default.fileExists(atPath: path)) {
            if let full = await downloadFullFileIfNeeded(fileId: info.fileId) {
                path = full.local.path
            }
        }
        guard !path.isEmpty else { return nil }

        let url = URL(fileURLWithPath: path)
        let asset = AVURLAsset(url: url)
        await logAssetInfo(asset, fileId: info.fileId, label: "pre-check")
        print("[audio-check][pre] fileId=\(info.fileId) url=\(url.lastPathComponent)")
        let check = await isAudioTrackSupported(in: asset)
        print("[audio-check][pre] supported=\(check.supported) formats=\(check.description)")
        if check.supported {
            return url
        }

        // Если нет аудиодорожек — играем как есть (без тяжелых операций)
        if check.description == "none" {
            return url
        }

        // Ограничиваем дорогостоящие операции для больших файлов (>300 МБ)
        let sizeLimitForRewrite: Int64 = 300 * 1024 * 1024
        if info.expectedSize > sizeLimitForRewrite || info.expectedSize == 0 {
            return url
        }

        // Если дорожка не видна — попробуем пересобрать контейнер (passthrough) и перечитать.
        if let repaired = await rewriteContainerPassthrough(asset: asset, fileId: info.fileId) {
            let repairedAsset = AVURLAsset(url: repaired)
            await logAssetInfo(repairedAsset, fileId: info.fileId, label: "passthrough")
            let repairedCheck = await isAudioTrackSupported(in: repairedAsset)
            print("[audio-check][rewrap] supported=\(repairedCheck.supported) formats=\(repairedCheck.description)")
            if repairedCheck.supported {
                return repaired
            }
        }

        do {
            if let converted = try await transcodeToAACIfNeeded(asset: asset, sourceURL: url, fileId: info.fileId) {
                print("[audio-check][transcode] success fileId=\(info.fileId) url=\(converted.lastPathComponent)")
                return converted
            }
        } catch {
            print("[audio-check][transcode][error] \(error.localizedDescription)")
        }

        return nil
    }

    private func downloadFullFileIfNeeded(
        fileId: Int,
        progressHandler: ((Double) async -> Void)? = nil
    ) async -> TDLibKit.File? {
        do {
            var file = try await viewModel.client.downloadFile(
                fileId: fileId,
                limit: 0,
                offset: 0,
                priority: 32,
                synchronous: false
            )
            // Для больших файлов даём больше времени на полную загрузку и повторно
            // проверяем прогресс, чтобы потом можно было перекодировать звук.
            var attempts = 0
            while !file.local.isDownloadingCompleted && !Task.isCancelled && attempts < 120 {
                // До completion показываем прогресс только по непрерывному префиксу.
                // Иначе можно увидеть 100% при incomplete (sparse/holes) и "зависание" на 100.
                let prefix = max(Int64(file.local.downloadedPrefixSize), 0)
                let downloaded = prefix
                logDownloadProgress(
                    fileId: fileId,
                    downloaded: downloaded,
                    expected: Int64(file.size),
                    label: "full-download"
                )
                if let progressHandler {
                    let percent = file.size > 0 ? min(1.0, Double(downloaded) / Double(file.size)) : 0
                    await progressHandler(percent)
                }
                try await Task.sleep(nanoseconds: 1_000_000_000) // 1 c
                file = try await viewModel.client.getFile(fileId: fileId)
                attempts += 1
            }
            logDownloadProgress(
                fileId: fileId,
                downloaded: max(Int64(file.local.downloadedPrefixSize), 0),
                expected: Int64(file.size),
                label: file.local.isDownloadingCompleted ? "full-download-complete" : "full-download-timeout"
            )
            if file.local.isDownloadingCompleted, let progressHandler { await progressHandler(1) }
            if file.local.isDownloadingCompleted {
                return file
            } else {
                return nil
            }
        } catch is CancellationError {
            // Отмена — нормальный кейс при переключении видео. Не показываем ошибку.
            return nil
        } catch {
            return nil
        }
    }

    private func logDownloadProgress(fileId: Int, downloaded: Int64, expected: Int64, label: String) {
        guard expected > 0 else {
            print("[download][\(label)] fileId=\(fileId) downloaded=\(downloaded) expected=0 (unknown size)")
            return
        }
        let key = "\(label)#\(fileId)"
        if let last = lastDownloadLog[key], last.downloaded == downloaded, last.expected == expected {
            return
        }
        lastDownloadLog[key] = (downloaded, expected)
        let percent = Double(downloaded) / Double(expected) * 100
        print("[download][\(label)] fileId=\(fileId) \(downloaded)/\(expected) (\(String(format: "%.1f", percent))%)")
    }

    private func isAudioTrackSupported(in asset: AVAsset) async -> (supported: Bool, description: String) {
        let formats = (try? await asset.loadTracks(withMediaType: .audio)) ?? []
        var descriptions: [String] = []
        var supported = false

        for track in formats {
            let descs = (try? await track.load(.formatDescriptions)) ?? []
            for desc in descs {
                guard let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(desc)?.pointee else { continue }
                let formatId = asbd.mFormatID
                let name = audioFormatName(formatId)
                descriptions.append(name)
                supported = supported || isSupportedAudioFormat(formatId)
            }
        }

        if descriptions.isEmpty { descriptions.append("none") }
        return (supported, descriptions.joined(separator: ", "))
    }

    private func isSupportedAudioFormat(_ formatId: AudioFormatID) -> Bool {
        [
            kAudioFormatMPEG4AAC,
            kAudioFormatMPEGLayer3,
            kAudioFormatAppleLossless,
            kAudioFormatLinearPCM,
            kAudioFormatAC3,
            kAudioFormat60958AC3
        ].contains(formatId)
    }

    private func audioFormatName(_ id: AudioFormatID) -> String {
        switch id {
        case kAudioFormatMPEG4AAC: return "AAC"
        case kAudioFormatOpus: return "Opus"
        case kAudioFormatMPEGLayer3: return "MP3"
        case kAudioFormatAppleLossless: return "ALAC"
        case kAudioFormatLinearPCM: return "PCM"
        case kAudioFormatAC3: return "AC3"
        case kAudioFormat60958AC3: return "AC3 60958"
        default: return "0x\(String(id, radix: 16))"
        }
    }

    private func logAssetInfo(_ asset: AVAsset, fileId: Int, label: String) async {
        let duration = (try? await asset.load(.duration)) ?? .zero
        var audioTracks: [AVAssetTrack] = []
        var videoTracks: [AVAssetTrack] = []
        audioTracks = (try? await asset.loadTracks(withMediaType: .audio)) ?? []
        videoTracks = (try? await asset.loadTracks(withMediaType: .video)) ?? []
        var audioDescs: [String] = []
        for track in audioTracks {
            let descs = (try? await track.load(.formatDescriptions)) ?? []
            for desc in descs {
                if let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(desc)?.pointee {
                    audioDescs.append(audioFormatName(asbd.mFormatID))
                } else {
                    audioDescs.append("unknown")
                }
            }
        }
        let videoDesc = videoTracks.isEmpty ? "none" : "\(videoTracks.count)x video"
        let audioDesc = audioDescs.isEmpty ? "none" : audioDescs.joined(separator: ", ")
        print("[asset-info][\(label)] fileId=\(fileId) duration=\(duration.seconds)s audio=\(audioDesc) video=\(videoDesc)")
    }

    private func rewriteContainerPassthrough(asset: AVAsset, fileId: Int) async -> URL? {
        let targetDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("tgtv_rewrap", isDirectory: true)
        try? FileManager.default.createDirectory(at: targetDir, withIntermediateDirectories: true)
        let targetURL = targetDir.appendingPathComponent("\(fileId)_rewrap.mp4")
        if FileManager.default.fileExists(atPath: targetURL.path) {
            try? FileManager.default.removeItem(at: targetURL)
        }
        guard let exportSession = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
            return nil
        }
        print("[audio-check][rewrap] start fileId=\(fileId) -> \(targetURL.lastPathComponent)")
        exportSession.outputURL = targetURL
        exportSession.outputFileType = .mp4
        exportSession.shouldOptimizeForNetworkUse = true
        let (result, errorMessage) = await export(session: exportSession, targetURL: targetURL)
        if result == nil, let errorMessage {
            print("[audio-check][rewrap][error] fileId=\(fileId) \(errorMessage)")
        }
        return result
    }

    private func export(session: AVAssetExportSession, targetURL: URL) async -> (URL?, String?) {
        if #available(tvOS 18, *) {
            let fileType = session.outputFileType ?? .mp4
            do {
                try await session.export(to: targetURL, as: fileType)
                return (targetURL, nil)
            } catch {
                return (nil, error.localizedDescription)
            }
        } else {
            return await exportLegacy(session: session, targetURL: targetURL)
        }
    }

    @available(tvOS, introduced: 9.0, deprecated: 18.0, message: "Legacy экспорт для совместимости")
    private func exportLegacy(session: AVAssetExportSession, targetURL: URL) async -> (URL?, String?) {
        let boxed = UncheckedSendableBox(value: session)
        return await withCheckedContinuation { continuation in
            boxed.value.exportAsynchronously {
                switch boxed.value.status {
                case .completed:
                    continuation.resume(returning: (targetURL, nil))
                case .failed:
                    let err = boxed.value.error?.localizedDescription
                    continuation.resume(returning: (nil, err))
                case .cancelled:
                    let err = boxed.value.error?.localizedDescription
                    continuation.resume(returning: (nil, err))
                default:
                    let err = boxed.value.error?.localizedDescription
                    continuation.resume(returning: (nil, err))
                }
            }
        }
    }

    private struct UncheckedSendableBox<T>: @unchecked Sendable {
        let value: T
    }

    private func transcodeToAACIfNeeded(asset: AVAsset, sourceURL: URL, fileId: Int) async throws -> URL? {
        let tracks = try await asset.load(.tracks)
        let hasVideo = !tracks.filter { $0.mediaType == .video }.isEmpty
        let hasAudio = !tracks.filter { $0.mediaType == .audio }.isEmpty

        guard hasAudio else {
            print("[audio-check][transcode] no-audio-tracks fileId=\(fileId)")
            return nil
        }

        let targetDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("tgtv_transcoded", isDirectory: true)
        try? FileManager.default.createDirectory(at: targetDir, withIntermediateDirectories: true)
        let targetURL = targetDir.appendingPathComponent("\(fileId)_aac.mp4")

        if FileManager.default.fileExists(atPath: targetURL.path) {
            try? FileManager.default.removeItem(at: targetURL)
        }

        let preset = hasVideo ? AVAssetExportPreset1280x720 : AVAssetExportPresetAppleM4A
        guard let exportSession = AVAssetExportSession(asset: asset, presetName: preset) else {
            return nil
        }
        print("[audio-check][transcode] start fileId=\(fileId) preset=\(preset) hasVideo=\(hasVideo) -> \(targetURL.lastPathComponent)")
        exportSession.outputURL = targetURL
        exportSession.outputFileType = hasVideo ? .mp4 : .m4a
        exportSession.shouldOptimizeForNetworkUse = true

        let (exported, errorMessage) = await export(session: exportSession, targetURL: targetURL)
        if exported == nil, let errorMessage {
            print("[audio-check][transcode][error] fileId=\(fileId) \(errorMessage)")
        }
        return exported
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
}


final class ChatHeaderView: UICollectionReusableView {
    private let titleLabel = UILabel()
    private var boundChatId: Int64?
    
    override init(frame: CGRect) {
        super.init(frame: frame)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.textColor = .white
        titleLabel.font = .systemFont(ofSize: 30, weight: .bold)
        addSubview(titleLabel)
        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor),
            titleLabel.bottomAnchor.constraint(equalTo: bottomAnchor),
            titleLabel.topAnchor.constraint(equalTo: topAnchor)
        ])
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    func configure(title: String) {
        titleLabel.text = title
    }
}
