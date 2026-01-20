import UIKit

final class SubscriptionOfferCard: UIButton {
    private let blurEffect = UIBlurEffect(style: .dark)
    private let blurView = UIVisualEffectView()
    
    let cardTitleLabel = UILabel()
    let cardPriceLabel = UILabel()
    let cardSubPriceLabel = UILabel()
    let cardExtraLabel = UILabel()
    
    var isPopular: Bool = false {
        didSet {
            updateStyle()
        }
    }
    
    init() {
        super.init(frame: .zero)
        setupUI()
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    private func setupUI() {
        translatesAutoresizingMaskIntoConstraints = false
        
        blurView.effect = blurEffect
        blurView.isUserInteractionEnabled = false
        blurView.layer.cornerRadius = 16
        blurView.clipsToBounds = true
        blurView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(blurView)
        
        blurView.layer.borderWidth = 1
        blurView.layer.borderColor = UIColor(white: 1, alpha: 0.1).cgColor
        
        [cardTitleLabel, cardPriceLabel, cardSubPriceLabel, cardExtraLabel].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            $0.textColor = .white
            $0.font = .systemFont(ofSize: 32, weight: .medium)
            addSubview($0)
        }
        
        cardSubPriceLabel.font = .systemFont(ofSize: 24, weight: .regular)
        cardSubPriceLabel.textAlignment = .right
        cardPriceLabel.textAlignment = .right
        cardExtraLabel.font = .systemFont(ofSize: 24, weight: .regular)
        
        NSLayoutConstraint.activate([
            blurView.topAnchor.constraint(equalTo: topAnchor),
            blurView.bottomAnchor.constraint(equalTo: bottomAnchor),
            blurView.leadingAnchor.constraint(equalTo: leadingAnchor),
            blurView.trailingAnchor.constraint(equalTo: trailingAnchor),
            
            cardTitleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 38.88),
            cardTitleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 68.86), // 227.86 - 159
            
            cardPriceLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -52.54),
            cardPriceLabel.topAnchor.constraint(equalTo: topAnchor, constant: 51.55),
            
            cardSubPriceLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -71.98),
            cardSubPriceLabel.topAnchor.constraint(equalTo: cardPriceLabel.bottomAnchor, constant: 4),
            
            cardExtraLabel.leadingAnchor.constraint(equalTo: cardTitleLabel.leadingAnchor),
            cardExtraLabel.topAnchor.constraint(equalTo: cardTitleLabel.bottomAnchor, constant: 4)
        ])
    }
    
    private func updateStyle() {
        if isPopular {
            blurView.contentView.backgroundColor = UIColor(red: 183/255, green: 0, blue: 1, alpha: 0.3)
        } else {
            blurView.contentView.backgroundColor = UIColor(white: 1, alpha: 0.02)
        }
    }
    
    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        coordinator.addCoordinatedAnimations {
            if self.isFocused {
                self.transform = CGAffineTransform(scaleX: 1.04, y: 1.04)
                self.blurView.layer.borderColor = UIColor.white.cgColor
                self.blurView.layer.borderWidth = 3
            } else {
                self.transform = .identity
                self.blurView.layer.borderColor = UIColor(white: 1, alpha: 0.1).cgColor
                self.blurView.layer.borderWidth = 1
            }
        }
    }
}

final class SubscriptionViewController: UIViewController {
    private var topMenu: TopMenuView?
    private let headerContainer = UIView()
    private var pendingMenuFocus = false
    
    private let weekCard = SubscriptionOfferCard()
    private let yearPopularCard = SubscriptionOfferCard()
    private let welcomeCard = SubscriptionOfferCard()
    private let freeCard = SubscriptionOfferCard()
    
    private let rightTitleLabel = UILabel()
    private let rightSubtitleLabel = UILabel()
    private let rightDescriptionLabel = UILabel()
    
    private let popularBadge = UIView()
    private let discountBadge = UIView()
    private let popularLabel = UILabel()
    private let discountLabel = UILabel()

    override var preferredFocusEnvironments: [UIFocusEnvironment] {
        if pendingMenuFocus, let menu = topMenu, let target = menu.currentFocusTarget() {
            pendingMenuFocus = false
            return [target]
        }
        return [yearPopularCard]
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        setupBackground()
        setupHeaderContainer()
        setupTopMenuBar()
        setupOfferCards()
        setupRightSideContent()
        view.bringSubviewToFront(headerContainer)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setNavigationBarHidden(true, animated: false)
        topMenu?.setCurrentIndex(4)
    }

    private func setupBackground() {
        let bg = UIImageView(image: UIImage(named: "Background Image"))
        bg.translatesAutoresizingMaskIntoConstraints = false
        bg.contentMode = .scaleAspectFill
        bg.transform = CGAffineTransform(scaleX: -1, y: 1)
        view.addSubview(bg)
        
        NSLayoutConstraint.activate([
            bg.topAnchor.constraint(equalTo: view.topAnchor),
            bg.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            bg.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            bg.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])
    }

    private func setupHeaderContainer() {
        headerContainer.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(headerContainer)
        NSLayoutConstraint.activate([
            headerContainer.topAnchor.constraint(equalTo: view.topAnchor),
            headerContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            headerContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            headerContainer.heightAnchor.constraint(equalToConstant: 150)
        ])

        let logo = UIImageView(image: UIImage(named: "Logo"))
        logo.translatesAutoresizingMaskIntoConstraints = false
        logo.contentMode = .scaleAspectFit
        headerContainer.addSubview(logo)
        NSLayoutConstraint.activate([
            logo.leadingAnchor.constraint(equalTo: headerContainer.leadingAnchor, constant: 64),
            logo.topAnchor.constraint(equalTo: headerContainer.topAnchor, constant: 59),
            logo.widthAnchor.constraint(equalToConstant: 175),
            logo.heightAnchor.constraint(equalToConstant: 66)
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
        let menu = TopMenuView(items: items, selectedIndex: 4)
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
        case 0: appDelegate?.showSearch()
        case 1: appDelegate?.showHome()
        case 2: appDelegate?.showChannels()
        case 3: appDelegate?.showHelp()
        case 4: appDelegate?.showSettings()
        default: break
        }
    }

    private func setupOfferCards() {
        // One week
        weekCard.cardTitleLabel.text = "One week"
        weekCard.cardPriceLabel.text = "$4.99"
        weekCard.cardSubPriceLabel.text = "$5/Month"
        view.addSubview(weekCard)
        
        // One Year (Popular)
        yearPopularCard.cardTitleLabel.text = "One Year"
        yearPopularCard.cardPriceLabel.text = "$89.99/Year"
        yearPopularCard.cardSubPriceLabel.text = "$2.92/Month"
        yearPopularCard.cardExtraLabel.text = "3 Days for free"
        yearPopularCard.isPopular = true
        view.addSubview(yearPopularCard)
        
        // Badges for Popular
        [popularBadge, discountBadge].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            $0.backgroundColor = UIColor(red: 1, green: 187/255, blue: 0, alpha: 1)
            $0.layer.cornerRadius = 3
            view.addSubview($0)
        }
        
        popularLabel.text = "MOST POPULAR"
        discountLabel.text = "-42%"
        [popularLabel, discountLabel].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            $0.textColor = .black
            $0.font = .systemFont(ofSize: 24, weight: .bold)
            $0.textAlignment = .center
            view.addSubview($0)
        }

        // Welcome offer
        welcomeCard.cardTitleLabel.text = "Welcome offer"
        welcomeCard.cardPriceLabel.text = "$24.99/Year"
        welcomeCard.cardSubPriceLabel.text = "$2.92/Month"
        welcomeCard.cardExtraLabel.text = "One year"
        view.addSubview(welcomeCard)
        
        // Free Access
        freeCard.cardTitleLabel.text = "Free Access"
        freeCard.cardExtraLabel.text = "Try out the app and watch 3 videos for free!"
        view.addSubview(freeCard)

        NSLayoutConstraint.activate([
            weekCard.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 90),
            weekCard.topAnchor.constraint(equalTo: view.topAnchor, constant: 159),
            weekCard.widthAnchor.constraint(equalToConstant: 717.03),
            weekCard.heightAnchor.constraint(equalToConstant: 177.81),
            
            yearPopularCard.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 90),
            yearPopularCard.topAnchor.constraint(equalTo: view.topAnchor, constant: 354.59),
            yearPopularCard.widthAnchor.constraint(equalToConstant: 717.03),
            yearPopularCard.heightAnchor.constraint(equalToConstant: 177.81),
            
            popularBadge.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 128.88),
            popularBadge.topAnchor.constraint(equalTo: view.topAnchor, constant: 340.76),
            popularBadge.widthAnchor.constraint(equalToConstant: 218.13),
            popularBadge.heightAnchor.constraint(equalToConstant: 39.51),
            
            popularLabel.centerXAnchor.constraint(equalTo: popularBadge.centerXAnchor),
            popularLabel.centerYAnchor.constraint(equalTo: popularBadge.centerYAnchor),
            
            discountBadge.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 368.6),
            discountBadge.topAnchor.constraint(equalTo: view.topAnchor, constant: 340.76),
            discountBadge.widthAnchor.constraint(equalToConstant: 97.19),
            discountBadge.heightAnchor.constraint(equalToConstant: 39.51),
            
            discountLabel.centerXAnchor.constraint(equalTo: discountBadge.centerXAnchor),
            discountLabel.centerYAnchor.constraint(equalTo: discountBadge.centerYAnchor),

            welcomeCard.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 90),
            welcomeCard.topAnchor.constraint(equalTo: view.topAnchor, constant: 550.19),
            welcomeCard.widthAnchor.constraint(equalToConstant: 717.03),
            welcomeCard.heightAnchor.constraint(equalToConstant: 177.81),
            
            freeCard.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 90),
            freeCard.topAnchor.constraint(equalTo: view.topAnchor, constant: 746),
            freeCard.widthAnchor.constraint(equalToConstant: 717.03),
            freeCard.heightAnchor.constraint(equalToConstant: 177.81)
        ])
        
        [weekCard, yearPopularCard, welcomeCard, freeCard].forEach {
            $0.addTarget(self, action: #selector(offerTapped(_:)), for: .primaryActionTriggered)
        }
    }

    private func setupRightSideContent() {
        rightTitleLabel.text = "Unlock the full big‑screen experience"
        rightTitleLabel.font = .systemFont(ofSize: 36, weight: .bold)
        
        rightDescriptionLabel.text = "Start your free trial and make sure it’s for you. Watch up to 3 videos free, then continue with unlimited playback and easy access to your Telegram chat videos on Apple TV."
        rightDescriptionLabel.font = .systemFont(ofSize: 25, weight: .bold)
        rightDescriptionLabel.textColor = UIColor(white: 1, alpha: 0.5)
        rightDescriptionLabel.numberOfLines = 0
        
        rightSubtitleLabel.text = "Try it now—your best moments deserve the big screen."
        rightSubtitleLabel.font = .systemFont(ofSize: 25, weight: .bold)
        
        [rightTitleLabel, rightSubtitleLabel, rightDescriptionLabel].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            $0.textColor = .white
            view.addSubview($0)
        }
        
        NSLayoutConstraint.activate([
            rightTitleLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 903),
            rightTitleLabel.topAnchor.constraint(equalTo: view.topAnchor, constant: 159),
            rightTitleLabel.widthAnchor.constraint(equalToConstant: 751),
            
            rightDescriptionLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 903),
            rightDescriptionLabel.topAnchor.constraint(equalTo: view.topAnchor, constant: 232),
            rightDescriptionLabel.widthAnchor.constraint(equalToConstant: 916),
            
            rightSubtitleLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 903),
            rightSubtitleLabel.topAnchor.constraint(equalTo: view.topAnchor, constant: 341),
            rightSubtitleLabel.widthAnchor.constraint(equalToConstant: 640)
        ])
    }

    @objc private func offerTapped(_ sender: SubscriptionOfferCard) {
        SubscriptionStore.isSubscribed = true
        if presentingViewController != nil {
            dismiss(animated: true)
        } else {
            navigationController?.popViewController(animated: true)
        }
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

enum SubscriptionStore {
    private static let key = "tgtv.subscription.active"

    static var isSubscribed: Bool {
        get { UserDefaults.standard.bool(forKey: key) }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }
}
