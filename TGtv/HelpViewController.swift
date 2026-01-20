import UIKit

final class HelpViewController: UIViewController {
    private var topMenu: TopMenuView?
    private let headerContainer = UIView()
    private var pendingMenuFocus = false

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

    override func viewDidLoad() {
        super.viewDidLoad()
        restoresFocusAfterTransition = false
        setupBackground()
        setupHeaderContainer()
        setupTopMenuBar()
        setupContent()
        view.bringSubviewToFront(headerContainer)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setNavigationBarHidden(true, animated: false)
        topMenu?.setCurrentIndex(3)
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        navigationController?.setNavigationBarHidden(false, animated: false)
        topMenu?.cancelPendingTransitions()
    }

    private func setupBackground() {
        // tmedia-bgr 1
        let tmediaBgr = UIImageView(image: UIImage(named: "tmedia-bgr 1"))
        tmediaBgr.translatesAutoresizingMaskIntoConstraints = false
        tmediaBgr.contentMode = .scaleAspectFill
        view.addSubview(tmediaBgr)

        NSLayoutConstraint.activate([
            tmediaBgr.topAnchor.constraint(equalTo: view.topAnchor),
            tmediaBgr.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tmediaBgr.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tmediaBgr.bottomAnchor.constraint(equalTo: view.bottomAnchor)
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
            headerContainer.heightAnchor.constraint(equalToConstant: 220) // Уменьшено с 250
        ])

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
        let menu = TopMenuView(items: items, selectedIndex: 3)
        menu.translatesAutoresizingMaskIntoConstraints = false
        menu.onTabSelected = { [weak self] index in
            self?.handleTabSelection(index)
        }
        headerContainer.addSubview(menu)
        NSLayoutConstraint.activate([
            menu.topAnchor.constraint(equalTo: headerContainer.topAnchor, constant: 59), // Calculated from calc(50% - 74px/2 - 444px)
            menu.centerXAnchor.constraint(equalTo: headerContainer.centerXAnchor),
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
        case 2:
            appDelegate?.showChannels()
        case 4:
            appDelegate?.showSettings()
        default:
            break
        }
    }

    private func setupContent() {
        let contentStack = UIStackView()
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        contentStack.axis = .vertical
        contentStack.spacing = 15 // Уменьшено с 30
        contentStack.alignment = .fill
        contentStack.distribution = .fill
        view.addSubview(contentStack)

        NSLayoutConstraint.activate([
            contentStack.topAnchor.constraint(equalTo: headerContainer.bottomAnchor, constant: -10), // Поднято выше
            contentStack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 80),
            contentStack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -80),
            contentStack.bottomAnchor.constraint(lessThanOrEqualTo: view.bottomAnchor, constant: -20)
        ])

        // 1. Title & Intro
        let headerStack = makeVerticalStack(spacing: 8) // Уменьшено с 12
        let titleLabel = makeLabel(text: NSLocalizedString("help.title", comment: ""), fontSize: 38, color: .white, weight: .bold, adjustsFontSize: true) // 48 -> 38
        let introLabel = makeLabel(text: NSLocalizedString("help.intro", comment: ""), fontSize: 22, color: .white, alpha: 0.7, weight: .medium) // 28 -> 22
        headerStack.addArrangedSubview(titleLabel)
        headerStack.addArrangedSubview(introLabel)
        contentStack.addArrangedSubview(headerStack)

        // 2. Columns
        let columnsStack = UIStackView()
        columnsStack.axis = .horizontal
        columnsStack.spacing = 40 // 60 -> 40
        columnsStack.alignment = .top
        columnsStack.distribution = .fillEqually
        contentStack.addArrangedSubview(columnsStack)

        let leftColumn = makeVerticalStack(spacing: 12) // 24 -> 12
        let rightColumn = makeVerticalStack(spacing: 12) // 24 -> 12
        columnsStack.addArrangedSubview(leftColumn)
        columnsStack.addArrangedSubview(rightColumn)

        // Left Column Items
        leftColumn.addArrangedSubview(makeSection(
            title: NSLocalizedString("help.fileSizeTitle", comment: ""),
            body: NSLocalizedString("help.fileSizeBody", comment: "")
        ))
        leftColumn.addArrangedSubview(makeSection(
            title: NSLocalizedString("help.bestSettingsTitle", comment: ""),
            body: NSLocalizedString("help.bestSettingsBody", comment: "")
        ))
        leftColumn.addArrangedSubview(makeSection(
            title: NSLocalizedString("help.telegramTitle", comment: ""),
            body: NSLocalizedString("help.telegramBody", comment: "")
        ))

        // Right Column Items
        rightColumn.addArrangedSubview(makeSection(
            title: NSLocalizedString("help.instantTitle", comment: ""),
            body: NSLocalizedString("help.instantBody", comment: "")
        ))
        rightColumn.addArrangedSubview(makeSection(
            title: NSLocalizedString("help.noSettingsTitle", comment: ""),
            body: NSLocalizedString("help.noSettingsBody", comment: "")
        ))
    }

    private func makeVerticalStack(spacing: CGFloat) -> UIStackView {
        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = spacing
        stack.alignment = .fill
        return stack
    }

    private func makeSection(title: String, body: String) -> UIView {
        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 6 // 8 -> 6
        stack.alignment = .fill
        stack.isLayoutMarginsRelativeArrangement = true
        stack.layoutMargins = UIEdgeInsets(top: 10, left: 12, bottom: 10, right: 12) // Уменьшены отступы
        stack.backgroundColor = UIColor.white.withAlphaComponent(0.05)
        stack.layer.cornerRadius = 12
        stack.clipsToBounds = true
        
        let titleLabel = makeLabel(text: title, fontSize: 26, color: .white, weight: .bold, adjustsFontSize: true) // 30 -> 26
        let bodyLabel = makeLabel(text: body, fontSize: 19, color: .white, alpha: 0.6, weight: .regular) // 22 -> 19
        
        stack.addArrangedSubview(titleLabel)
        stack.addArrangedSubview(bodyLabel)
        
        return stack
    }

    private func makeLabel(text: String, fontSize: CGFloat, color: UIColor, alpha: CGFloat = 1.0, weight: UIFont.Weight, adjustsFontSize: Bool = false) -> UILabel {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.text = text
        label.textColor = color.withAlphaComponent(alpha)
        label.font = .systemFont(ofSize: fontSize, weight: weight)
        label.numberOfLines = 0
        label.lineBreakMode = .byWordWrapping
        
        if adjustsFontSize {
            label.adjustsFontSizeToFitWidth = true
            label.minimumScaleFactor = 0.5 // Более агрессивное уменьшение
            if !text.contains("\n") {
                label.numberOfLines = 1
            }
        }
        return label
    }

    private func currentFocusedView() -> UIView? {
        if let scene = view.window?.windowScene {
            return scene.focusSystem?.focusedItem as? UIView
        }
        return UIFocusSystem.focusSystem(for: view)?.focusedItem as? UIView
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let isMenuPress = presses.contains(where: { $0.type == .menu || $0.key?.keyCode == .keyboardEscape })
        if isMenuPress, let topMenu, let focused = currentFocusedView(), !focused.isDescendant(of: topMenu) {
            pendingMenuFocus = true
            setNeedsFocusUpdate()
            updateFocusIfNeeded()
            return
        }
        super.pressesBegan(presses, with: event)
    }
}
