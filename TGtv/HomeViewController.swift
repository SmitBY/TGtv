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
    private var dataSource: UICollectionViewDiffableDataSource<Int, HomeVideoItem>!
    private let emptyLabel = UILabel()
    private var backgroundImageView: UIImageView!
    private var playerObservers: [NSKeyValueObservation] = []
    private var playbackStallObserver: NSObjectProtocol?
    private let playbackProgressLabel = UILabel()
    private var playbackProgressWorkItem: DispatchWorkItem?
    
    // Полноэкранный оверлей загрузки
    private var fullscreenLoadingView: UIView?
    private var fullscreenSpinner: UIActivityIndicatorView?
    private var fullscreenProgressLabel: UILabel?
    private var progressWatchTask: Task<Void, Never>?
    
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
    
    override func viewDidLoad() {
        super.viewDidLoad()
        setupBackground()
        setupNavigation()
        setupCollectionView()
        setupEmptyLabel()
        setupLoading()
        observeFileUpdates()
        applySnapshot(sections: [])
    }
    
    deinit {
        streamingCoordinator?.stop()
        if let observer = fileUpdateObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let stall = playbackStallObserver {
            NotificationCenter.default.removeObserver(stall)
        }
        progressWatchTask?.cancel()
    }
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        Task { @MainActor in
            await reloadData()
        }
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
        overlay.backgroundColor = UIColor(white: 0, alpha: 0.5)
        view.addSubview(overlay)
        NSLayoutConstraint.activate([
            overlay.topAnchor.constraint(equalTo: view.topAnchor),
            overlay.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            overlay.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])
    }
    
    private func setupNavigation() {
        title = "Главная"
        navigationItem.leftBarButtonItem = UIBarButtonItem(title: "Список чатов", style: .plain, target: self, action: #selector(openChatSelection))
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: "Настройки", style: .plain, target: self, action: #selector(openSettings))
    }
    
    private func setupCollectionView() {
        let layout = createLayout()
        collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        collectionView.backgroundColor = .clear
        collectionView.remembersLastFocusedIndexPath = true
        collectionView.delegate = self
        view.addSubview(collectionView)
        
        NSLayoutConstraint.activate([
            collectionView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 10),
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 40),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -40),
            collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -40)
        ])
        
        collectionView.register(VideoCell.self, forCellWithReuseIdentifier: "VideoCell")
        collectionView.register(ChatHeaderView.self, forSupplementaryViewOfKind: UICollectionView.elementKindSectionHeader, withReuseIdentifier: "Header")
        
        dataSource = UICollectionViewDiffableDataSource<Int, HomeVideoItem>(collectionView: collectionView) { collectionView, indexPath, item in
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
        view.addSubview(playbackProgressLabel)
        NSLayoutConstraint.activate([
            playbackProgressLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            playbackProgressLabel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 20)
        ])
    }
    
    private func createLayout() -> UICollectionViewLayout {
        let itemSize = NSCollectionLayoutSize(widthDimension: .absolute(280), heightDimension: .absolute(240))
        let item = NSCollectionLayoutItem(layoutSize: itemSize)
        item.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 8, bottom: 0, trailing: 8)
        
        let groupSize = NSCollectionLayoutSize(widthDimension: .estimated(1120), heightDimension: .absolute(240))
        let group = NSCollectionLayoutGroup.horizontal(layoutSize: groupSize, subitems: [item])
        
        let section = NSCollectionLayoutSection(group: group)
        section.orthogonalScrollingBehavior = .continuous
        section.interGroupSpacing = 12
        section.contentInsets = NSDirectionalEdgeInsets(top: 12, leading: 0, bottom: 36, trailing: 0)
        
        let headerSize = NSCollectionLayoutSize(widthDimension: .fractionalWidth(1.0), heightDimension: .absolute(40))
        let header = NSCollectionLayoutBoundarySupplementaryItem(layoutSize: headerSize, elementKind: UICollectionView.elementKindSectionHeader, alignment: .top)
        section.boundarySupplementaryItems = [header]
        
        return UICollectionViewCompositionalLayout(section: section)
    }
    
    private func applySnapshot(sections: [HomeSection]) {
        var snapshot = NSDiffableDataSourceSnapshot<Int, HomeVideoItem>()
        for (idx, section) in sections.enumerated() {
            snapshot.appendSections([idx])
            if section.videos.isEmpty {
                snapshot.appendItems(
                    [HomeVideoItem(
                        id: Int64(idx),
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
                    toSection: idx
                )
            } else {
                snapshot.appendItems(section.videos, toSection: idx)
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
    
    private func observeFileUpdates() {
        fileUpdateObserver = NotificationCenter.default.addObserver(forName: .tgFileUpdated, object: nil, queue: .main) { [weak self] note in
            guard let file = note.object as? TDLibKit.File else { return }
            self?.streamingCoordinator?.handleFileUpdate(file)
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
}

// MARK: - Cells & Headers

final class VideoCell: UICollectionViewCell {
    private let titleLabel = UILabel()
    private let backgroundCard = UIView()
    private let thumbnailView = UIImageView()
    private let placeholderLabel = UILabel()
    
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
                self.backgroundCard.layer.borderWidth = 2
                self.backgroundCard.layer.borderColor = UIColor.systemBlue.cgColor
                self.backgroundCard.transform = CGAffineTransform(scaleX: 1.05, y: 1.05)
            } else {
                self.backgroundCard.layer.borderWidth = 0
                self.backgroundCard.transform = .identity
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
        backgroundCard.layer.cornerRadius = 14
        backgroundCard.backgroundColor = UIColor(white: 1, alpha: 0.08)
        contentView.addSubview(backgroundCard)
        
        thumbnailView.translatesAutoresizingMaskIntoConstraints = false
        thumbnailView.contentMode = .scaleAspectFill
        thumbnailView.clipsToBounds = true
        thumbnailView.layer.cornerRadius = 12
        backgroundCard.addSubview(thumbnailView)
        
        placeholderLabel.translatesAutoresizingMaskIntoConstraints = false
        placeholderLabel.text = "Нет превью"
        placeholderLabel.textColor = UIColor(white: 1, alpha: 0.6)
        placeholderLabel.font = .systemFont(ofSize: 16, weight: .medium)
        placeholderLabel.textAlignment = .center
        placeholderLabel.isHidden = true
        backgroundCard.addSubview(placeholderLabel)
        
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.textColor = .white
        titleLabel.font = .systemFont(ofSize: 20, weight: .semibold)
        titleLabel.numberOfLines = 2
        backgroundCard.addSubview(titleLabel)
        
        NSLayoutConstraint.activate([
            backgroundCard.topAnchor.constraint(equalTo: contentView.topAnchor),
            backgroundCard.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            backgroundCard.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            backgroundCard.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            
            thumbnailView.topAnchor.constraint(equalTo: backgroundCard.topAnchor, constant: 8),
            thumbnailView.leadingAnchor.constraint(equalTo: backgroundCard.leadingAnchor, constant: 8),
            thumbnailView.trailingAnchor.constraint(equalTo: backgroundCard.trailingAnchor, constant: -8),
            thumbnailView.heightAnchor.constraint(equalTo: backgroundCard.heightAnchor, multiplier: 0.7),
            
            placeholderLabel.centerXAnchor.constraint(equalTo: thumbnailView.centerXAnchor),
            placeholderLabel.centerYAnchor.constraint(equalTo: thumbnailView.centerYAnchor),
            
            titleLabel.leadingAnchor.constraint(equalTo: backgroundCard.leadingAnchor, constant: 12),
            titleLabel.trailingAnchor.constraint(equalTo: backgroundCard.trailingAnchor, constant: -12),
            titleLabel.topAnchor.constraint(equalTo: thumbnailView.bottomAnchor, constant: 8),
            titleLabel.bottomAnchor.constraint(equalTo: backgroundCard.bottomAnchor, constant: -12)
        ])
    }
}

// MARK: - Collection Delegate

extension HomeViewController: UICollectionViewDelegate {
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        guard let item = dataSource.itemIdentifier(for: indexPath), item.videoFileId != 0 else { return }
        playVideo(item)
    }
    
    private func playVideo(_ item: HomeVideoItem) {
        setLoading(true)
        showFullscreenLoading(progress: nil)
        progressWatchTask?.cancel()
        
        progressWatchTask = Task { @MainActor [weak self] in
            guard let self else { return }
            
            guard var info = await viewModel.fetchLatestVideoInfo(for: item) else {
                self.setLoading(false)
                self.hideFullscreenLoading()
                self.showAlert(title: "Ошибка", message: "Не удалось получить данные видео.")
                return
            }
            
            // Подтягиваем хвост (moov atom) при неполной загрузке, не блокируя старт
            if !info.isDownloadingCompleted, info.expectedSize > 0 {
                let progress = Double(info.downloadedSize) / Double(info.expectedSize)
                self.showFullscreenLoading(progress: progress)
                
                let tailOffset = max(info.expectedSize - 4_000_000, 0)
                _ = try? await self.viewModel.client.downloadFile(
                    fileId: info.fileId,
                    limit: 4_000_000,
                    offset: tailOffset,
                    priority: 32,
                    synchronous: true
                )
                if let refreshed = await self.viewModel.fetchLatestVideoInfo(for: item) {
                    info = refreshed
                }
            }
            
            // Если префикс не скачан — запускаем докачку от нулевого offset и ждём появления префикса
            if info.downloadedSize == 0 && !info.isDownloadingCompleted {
                self.showFullscreenLoading(progress: 0)
                Task.detached { [client = self.viewModel.client] in
                    _ = try? await client.downloadFile(
                        fileId: info.fileId,
                        limit: 0,
                        offset: 0,
                        priority: 32,
                        synchronous: false
                    )
                }
                await self.pollPrefixAndPlay(item: item)
                return
            }
            
            await self.startPlayback(with: info, fallbackItem: item)
        }
    }

    private func pollPrefixAndPlay(item: HomeVideoItem) async {
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
                
                // Периодически дёргаем хвост, чтобы быстрее получить moov для потокового старта
                if info.expectedSize > 0 && info.downloadedSize == 0 && attempts.isMultiple(of: 5) {
                    let tailOffset = max(info.expectedSize - 4_000_000, 0)
                    _ = try? await viewModel.client.downloadFile(
                        fileId: info.fileId,
                        limit: 4_000_000,
                        offset: tailOffset,
                        priority: 32,
                        synchronous: true
                    )
                }
                
                if info.downloadedSize > 0 || info.isDownloadingCompleted {
                    await MainActor.run {
                        _ = Task { [weak self] in
                            await self?.startPlayback(with: info, fallbackItem: item)
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
        }
    }

    @MainActor
    private func startPlayback(with info: TG.MessageMedia.VideoInfo, fallbackItem: HomeVideoItem) async {
        var info = info
        setupAudioSessionIfNeeded()
        
        _ = try? FileManager.default.attributesOfItem(atPath: info.path)

        // Если файл уже загружен полностью — обычное воспроизведение
        if info.isDownloadingCompleted && FileManager.default.fileExists(atPath: info.path) {
            self.setLoading(false)
            self.hideFullscreenLoading()
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
            self.presentOrReusePlayer(player: player, item: playerItem)
            return
        }
        
        // Потоковое воспроизведение
        guard !info.path.isEmpty else {
            self.setLoading(false)
            self.hideFullscreenLoading()
            self.showAlert(title: "Ошибка", message: "Нет локального пути к файлу видео.")
            return
        }
        if !FileManager.default.fileExists(atPath: info.path) {
            _ = FileManager.default.createFile(atPath: info.path, contents: nil)
        }
        guard FileManager.default.fileExists(atPath: info.path) else {
            self.setLoading(false)
            self.hideFullscreenLoading()
            self.showAlert(title: "Ошибка", message: "Локальный файл недоступен.")
            return
        }
        
        // Если префикс слишком мал (moov в конце) — потоковое воспроизведение недоступно, сразу уходим в полную загрузку
        let minPrefixForStreaming: Int64 = 2_000_000
        if info.expectedSize > 0, info.downloadedSize < minPrefixForStreaming, !info.isDownloadingCompleted {
            self.setLoading(false)
            self.hideFullscreenLoading()
            self.showAlert(title: "Идёт полная загрузка", message: "Этот файл не поддерживает потоковое воспроизведение (moov в конце). Воспроизведение начнётся после полной загрузки.")
            Task {
                _ = await downloadFullFileIfNeeded(fileId: info.fileId)
            }
            return
        }
        
        // Пробуем сразу подтянуть moov из хвоста, чтобы стрим стартанул быстрее
        if info.expectedSize > 0 && info.downloadedSize < info.expectedSize {
            let tailOffset = max(info.expectedSize - 4_000_000, 0)
            _ = try? await viewModel.client.downloadFile(
                fileId: info.fileId,
                limit: 4_000_000,
                offset: tailOffset,
                priority: 32,
                synchronous: true
            )
            if let refreshed = await viewModel.fetchLatestVideoInfo(for: fallbackItem) {
                info = refreshed
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
        self.presentOrReusePlayer(player: player, item: playerItem)
        self.setLoading(false)
        self.hideFullscreenLoading()
        
        // Фон: догружаем полностью, проверяем аудио и подменяем item при необходимости
        Task { [weak self, weak player] in
            guard let self else { return }
            guard let full = await downloadFullFileIfNeeded(fileId: info.fileId) else { return }
            let updatedInfo = TG.MessageMedia.VideoInfo(
                path: full.local.path,
                fileId: full.id,
                expectedSize: Int64(full.size),
                downloadedSize: max(Int64(full.local.downloadedSize), Int64(full.local.downloadedPrefixSize)),
                isDownloadingCompleted: full.local.isDownloadingCompleted,
                mimeType: info.mimeType
            )
            logDownloadProgress(
                fileId: updatedInfo.fileId,
                downloaded: updatedInfo.downloadedSize,
                expected: updatedInfo.expectedSize,
                label: "bg-full-download"
            )
            guard let playable = await ensurePlayableLocalURL(for: updatedInfo) else { return }
            await MainActor.run {
                let asset = AVURLAsset(url: playable, options: self.assetOptions(for: info.mimeType))
                let newItem = AVPlayerItem(asset: asset)
                self.streamingCoordinator?.stop()
                self.streamingCoordinator = nil
                player?.replaceCurrentItem(with: newItem)
                player?.play()
                if let currentVC = self.presentedViewController as? AVPlayerViewController {
                    currentVC.player = player
                }
            }
        }
    }

    private func presentOrReusePlayer(player: AVPlayer, item: AVPlayerItem) {
        if let currentVC = presentedViewController as? AVPlayerViewController {
            currentVC.player = player
            attachPlaybackObservers(player: player, item: item, controller: currentVC)
            player.play()
            return
        }
        let vc = AVPlayerViewController()
        vc.player = player
        vc.modalPresentationStyle = .overFullScreen
        vc.delegate = self
        present(vc, animated: true) { [weak self, weak vc] in
            guard let self, let vc else { return }
            self.attachPlaybackObservers(player: player, item: item, controller: vc)
        }
    }
    
    // MARK: AVPlayerViewControllerDelegate
    func playerViewControllerWillEndFullScreenPresentation(_ playerViewController: AVPlayerViewController) {
        streamingCoordinator?.stop()
        streamingCoordinator = nil
        currentPlaybackFileId = nil
        currentPlaybackMimeType = nil
        isRecoveringPlayback = false
    }
    
    private func showAlert(title: String, message: String) {
        // Если уже что-то показано (алерт/плеер) — не показываем, чтобы избежать гонок
        guard presentedViewController == nil else { return }
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }
    
    private func showFullscreenLoading(progress: Double?) {
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
            
            overlay.addSubview(spinner)
            overlay.addSubview(label)
            view.addSubview(overlay)
            
            NSLayoutConstraint.activate([
                overlay.topAnchor.constraint(equalTo: view.topAnchor),
                overlay.bottomAnchor.constraint(equalTo: view.bottomAnchor),
                overlay.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                overlay.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                
                spinner.centerXAnchor.constraint(equalTo: overlay.centerXAnchor),
                spinner.centerYAnchor.constraint(equalTo: overlay.centerYAnchor, constant: -12),
                
                label.centerXAnchor.constraint(equalTo: overlay.centerXAnchor),
                label.topAnchor.constraint(equalTo: spinner.bottomAnchor, constant: 12)
            ])
            
            fullscreenLoadingView = overlay
            fullscreenSpinner = spinner
            fullscreenProgressLabel = label
        }
        
        if let overlay = fullscreenLoadingView {
            view.bringSubviewToFront(overlay)
            overlay.isHidden = false
            fullscreenSpinner?.startAnimating()
        }
        
        if let progress, let label = fullscreenProgressLabel {
            let p = max(0, min(1, progress))
            label.text = String(format: "Загружено %.0f%%", p * 100)
        } else {
            fullscreenProgressLabel?.text = "Загрузка..."
        }
    }
    
    private func hideFullscreenLoading() {
        fullscreenSpinner?.stopAnimating()
        fullscreenLoadingView?.isHidden = true
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

    private func downloadFullFileIfNeeded(fileId: Int) async -> TDLibKit.File? {
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
                logDownloadProgress(
                    fileId: fileId,
                    downloaded: max(Int64(file.local.downloadedSize), Int64(file.local.downloadedPrefixSize)),
                    expected: Int64(file.size),
                    label: "full-download"
                )
                try await Task.sleep(nanoseconds: 1_000_000_000) // 1 c
                file = try await viewModel.client.getFile(fileId: fileId)
                attempts += 1
            }
            logDownloadProgress(
                fileId: fileId,
                downloaded: max(Int64(file.local.downloadedSize), Int64(file.local.downloadedPrefixSize)),
                expected: Int64(file.size),
                label: file.local.isDownloadingCompleted ? "full-download-complete" : "full-download-timeout"
            )
            return file.local.isDownloadingCompleted ? file : nil
        } catch {
            return nil
        }
    }

    private func logDownloadProgress(fileId: Int, downloaded: Int64, expected: Int64, label: String) {
        guard expected > 0 else {
            print("[download][\(label)] fileId=\(fileId) downloaded=\(downloaded) expected=0 (unknown size)")
            return
        }
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
