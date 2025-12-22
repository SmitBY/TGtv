import UIKit

final class SettingsViewController: UIViewController {
    private var topMenu: TopMenuView?
    private let headerContainer = UIView()
    private var focusGuideToMenu: UIFocusGuide?
    
    private let logoutButton = UIButton(type: .system)
    private let clearCacheButton = UIButton(type: .system)
    private let cacheLabel = UILabel()
    
    private let normalBackground = UIColor.systemGray.withAlphaComponent(0.2)
    private let logoutNormalBackground = UIColor.systemRed.withAlphaComponent(0.85)
    private let focusedBackground = UIColor.white
    
    private var updateTimer: Timer?
    
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
        setupContent()
        startUpdatingStats()
        
        // КРИТИЧЕСКИ ВАЖНО: хедер должен быть над контентом
        view.bringSubviewToFront(headerContainer)
    }
    
    private func setupHeaderContainer() {
        headerContainer.translatesAutoresizingMaskIntoConstraints = false
        headerContainer.backgroundColor = .clear
        view.addSubview(headerContainer)
        view.bringSubviewToFront(headerContainer)
        
        NSLayoutConstraint.activate([
            headerContainer.topAnchor.constraint(equalTo: view.topAnchor),
            headerContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            headerContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            headerContainer.heightAnchor.constraint(equalToConstant: 250)
        ])
    }
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setNavigationBarHidden(true, animated: false)
        topMenu?.setCurrentIndex(2) // Синхронизируем вкладку
        updateStats()
    }
    
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        navigationController?.setNavigationBarHidden(false, animated: false)
        updateTimer?.invalidate()
        topMenu?.cancelPendingTransitions()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        if let gradient = view.layer.sublayers?.first as? CAGradientLayer {
            gradient.frame = view.bounds
        }
    }
    
    private func startUpdatingStats() {
        updateTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            self?.updateStats()
        }
    }
    
    private func updateStats() {
        cacheLabel.text = "Кэш и загруженные файлы: \(getCacheSize())"
    }
    
    private func getCacheSize() -> String {
        let fm = FileManager.default
        var total: Int64 = 0
        
        let cachesURL = fm.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let tempURL = URL(fileURLWithPath: NSTemporaryDirectory())
        
        let paths = [
            cachesURL,
            tempURL
        ]
        
        for url in paths {
            if let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey], options: [.skipsHiddenFiles], errorHandler: nil) {
                for case let fileURL as URL in enumerator {
                    // Пропускаем саму папку 'tdlib' и всё что внутри неё
                    let path = fileURL.path
                    if path.contains("/tdlib/") || path.hasSuffix("/tdlib") {
                        continue
                    }
                    
                    if let resourceValues = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey]),
                       let isDirectory = resourceValues.isDirectory, !isDirectory,
                       let size = resourceValues.fileSize {
                        total += Int64(size)
                    }
                }
            }
        }
        return ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
    }
    
    private func setupBackground() {
        let gradient = CAGradientLayer()
        gradient.colors = [
            UIColor(red: 0.08, green: 0.08, blue: 0.12, alpha: 1).cgColor,
            UIColor(red: 0.04, green: 0.04, blue: 0.08, alpha: 1).cgColor
        ]
        gradient.locations = [0, 1]
        gradient.frame = view.bounds
        view.layer.insertSublayer(gradient, at: 0)
    }
    
    private func setupTopMenuBar() {
        let menu = TopMenuView(items: ["Главная", "Каналы", "Настройки"], selectedIndex: 2)
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
        case 0:
            appDelegate?.showHome()
        case 1:
            appDelegate?.showChannels()
        default:
            break
        }
    }
    
    private func setupContent() {
        let stackView = UIStackView()
        stackView.translatesAutoresizingMaskIntoConstraints = false
        stackView.axis = .vertical
        stackView.spacing = 30
        stackView.alignment = .center
        view.addSubview(stackView)
        
        NSLayoutConstraint.activate([
            stackView.topAnchor.constraint(equalTo: headerContainer.bottomAnchor, constant: 60),
            stackView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            stackView.widthAnchor.constraint(equalToConstant: 800)
        ])
        
        // Cache Info
        cacheLabel.font = .systemFont(ofSize: 32, weight: .medium)
        cacheLabel.textColor = .white
        stackView.addArrangedSubview(cacheLabel)
        
        // Clear Cache Button
        setupButton(clearCacheButton, title: "Очистить все файлы", color: normalBackground)
        clearCacheButton.addTarget(self, action: #selector(clearCacheTapped), for: .primaryActionTriggered)
        stackView.addArrangedSubview(clearCacheButton)
        
        // Spacing
        let spacer = UIView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.heightAnchor.constraint(equalToConstant: 20).isActive = true
        stackView.addArrangedSubview(spacer)
        
        // Logout Button
        setupButton(logoutButton, title: "Выйти из аккаунта", color: logoutNormalBackground)
        logoutButton.addTarget(self, action: #selector(logoutTapped), for: .primaryActionTriggered)
        stackView.addArrangedSubview(logoutButton)
        
        NSLayoutConstraint.activate([
            clearCacheButton.widthAnchor.constraint(equalToConstant: 500),
            clearCacheButton.heightAnchor.constraint(equalToConstant: 80),
            logoutButton.widthAnchor.constraint(equalToConstant: 500),
            logoutButton.heightAnchor.constraint(equalToConstant: 80)
        ])
        
        setupFocusGuides()
    }
    
    private func setupFocusGuides() {
        guard let topMenu else { return }
        
        // Удаляем старые гайды
        view.layoutGuides.filter { $0 is UIFocusGuide && $0.identifier == "SettingsToMenuGuide" }.forEach { view.removeLayoutGuide($0) }
        
        let guide = UIFocusGuide()
        guide.identifier = "SettingsToMenuGuide"
        guide.preferredFocusEnvironments = [topMenu.currentFocusTarget()].compactMap { $0 }
        view.addLayoutGuide(guide)
        NSLayoutConstraint.activate([
            guide.topAnchor.constraint(equalTo: headerContainer.bottomAnchor, constant: -100),
            guide.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            guide.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            guide.heightAnchor.constraint(equalToConstant: 200)
        ])
        focusGuideToMenu = guide
    }
    
    private func setupButton(_ button: UIButton, title: String, color: UIColor) {
        button.translatesAutoresizingMaskIntoConstraints = false
        button.setTitle(title, for: .normal)
        button.titleLabel?.font = .systemFont(ofSize: 32, weight: .semibold)
        button.setTitleColor(.white, for: .normal)
        button.setTitleColor(.black, for: .focused)
        button.backgroundColor = color
        button.layer.cornerRadius = 15
        button.clipsToBounds = true
    }
    
    @objc private func clearCacheTapped() {
        let fm = FileManager.default
        let cachesURL = fm.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let tempURL = URL(fileURLWithPath: NSTemporaryDirectory())

        let paths = [
            cachesURL,
            tempURL
        ]
        
        for url in paths {
            if let contents = try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil, options: []) {
                for file in contents {
                    // КРИТИЧЕСКИ ВАЖНО: Не удаляем папку 'tdlib', так как там хранится база данных и сессия пользователя.
                    // Если её удалить, произойдет разлогин.
                    if file.lastPathComponent == "tdlib" {
                        continue
                    }
                    try? fm.removeItem(at: file)
                }
            }
        }
        updateStats()
    }
    
    @objc private func logoutTapped() {
        (UIApplication.shared.delegate as? AppDelegate)?.logoutFromMenu()
    }

    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        
        let next = context.nextFocusedView
        
        if let next = next, next.isDescendant(of: headerContainer) {
            focusGuideToMenu?.preferredFocusEnvironments = [] // Когда мы в хедере, гайд не нужен
        } else {
            focusGuideToMenu?.preferredFocusEnvironments = [topMenu?.currentFocusTarget()].compactMap { $0 }
        }
        
        coordinator.addCoordinatedAnimations { [weak self] in
            guard let self else { return }
            
            self.clearCacheButton.backgroundColor = (context.nextFocusedView === self.clearCacheButton) ? 
                self.focusedBackground : self.normalBackground
                
            self.logoutButton.backgroundColor = (context.nextFocusedView === self.logoutButton) ? 
                self.focusedBackground : self.logoutNormalBackground
        }
    }
    
    override func shouldUpdateFocus(in context: UIFocusUpdateContext) -> Bool {
        let heading = context.focusHeading
        let nextView = context.nextFocusedView

        // Если фокус в хедере
        if let prev = context.previouslyFocusedView, prev.isDescendant(of: headerContainer) {
            // Блокируем выход вбок или вверх
            if heading == .left || heading == .right || heading == .up {
                if let next = nextView, !next.isDescendant(of: headerContainer) {
                    return false
                }
            }
        }
        
        return true
    }
}
