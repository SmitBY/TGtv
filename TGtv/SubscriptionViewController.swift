import UIKit
import Security

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
            $0.adjustsFontSizeToFitWidth = true
            $0.minimumScaleFactor = 0.5
            addSubview($0)
        }
        
        cardSubPriceLabel.font = .systemFont(ofSize: 24, weight: .regular)
        cardSubPriceLabel.textAlignment = .right
        cardPriceLabel.textAlignment = .right
        cardExtraLabel.font = .systemFont(ofSize: 24, weight: .regular)
        cardExtraLabel.numberOfLines = 1
        
        NSLayoutConstraint.activate([
            blurView.topAnchor.constraint(equalTo: topAnchor),
            blurView.bottomAnchor.constraint(equalTo: bottomAnchor),
            blurView.leadingAnchor.constraint(equalTo: leadingAnchor),
            blurView.trailingAnchor.constraint(equalTo: trailingAnchor),
            
            cardTitleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 38.88),
            cardTitleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 68.86),
            cardTitleLabel.trailingAnchor.constraint(lessThanOrEqualTo: cardPriceLabel.leadingAnchor, constant: -20),
            
            cardPriceLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -52.54),
            cardPriceLabel.topAnchor.constraint(equalTo: topAnchor, constant: 51.55),
            
            cardSubPriceLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -71.98),
            cardSubPriceLabel.topAnchor.constraint(equalTo: cardPriceLabel.bottomAnchor, constant: 4),
            
            cardExtraLabel.leadingAnchor.constraint(equalTo: cardTitleLabel.leadingAnchor),
            cardExtraLabel.topAnchor.constraint(equalTo: cardTitleLabel.bottomAnchor, constant: 4),
            cardExtraLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -38.88)
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
    private let isMandatory: Bool
    private var didBlockMenuOnce = false

    init(isMandatory: Bool = false) {
        self.isMandatory = isMandatory
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

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
        return [yearPopularCard]
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        setupBackground()
        setupLogo()
        setupOfferCards()
        setupRightSideContent()
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if isMandatory,
           !SubscriptionStore.hasChosenPlan,
           presses.contains(where: { $0.type == .menu }) {
            // Блокируем обход обязательного экрана подписки кнопкой Menu.
            // Минимально: просто игнорируем. Один раз можем показать подсказку.
            if !didBlockMenuOnce, presentedViewController == nil {
                didBlockMenuOnce = true
                let alert = UIAlertController(
                    title: NSLocalizedString("subscription.title", comment: ""),
                    message: NSLocalizedString("subscription.subtitle", comment: ""),
                    preferredStyle: .alert
                )
                alert.addAction(UIAlertAction(title: NSLocalizedString("button.ok", comment: ""), style: .default))
                present(alert, animated: true)
            }
            return
        }
        super.pressesBegan(presses, with: event)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setNavigationBarHidden(true, animated: false)
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

    private func setupLogo() {
        let logo = UIImageView(image: UIImage(named: "Logo"))
        logo.translatesAutoresizingMaskIntoConstraints = false
        logo.contentMode = .scaleAspectFit
        view.addSubview(logo)
        NSLayoutConstraint.activate([
            logo.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 64),
            logo.topAnchor.constraint(equalTo: view.topAnchor, constant: 59),
            logo.widthAnchor.constraint(equalToConstant: 175),
            logo.heightAnchor.constraint(equalToConstant: 66)
        ])
    }

    private func setupOfferCards() {
        // One week
        weekCard.cardTitleLabel.text = NSLocalizedString("subscription.offer.week", comment: "")
        weekCard.cardPriceLabel.text = "$4.99"
        weekCard.cardSubPriceLabel.text = "$5" + NSLocalizedString("subscription.offer.monthPrice", comment: "")
        view.addSubview(weekCard)
        
        // One Year (Popular)
        yearPopularCard.cardTitleLabel.text = NSLocalizedString("subscription.offer.year", comment: "")
        yearPopularCard.cardPriceLabel.text = "$89.99" + NSLocalizedString("subscription.offer.yearPrice", comment: "")
        yearPopularCard.cardSubPriceLabel.text = "$2.92" + NSLocalizedString("subscription.offer.monthPrice", comment: "")
        yearPopularCard.cardExtraLabel.text = NSLocalizedString("subscription.offer.freeTrial", comment: "")
        yearPopularCard.isPopular = true
        view.addSubview(yearPopularCard)
        
        // Badges for Popular
        [popularBadge, discountBadge].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            $0.backgroundColor = UIColor(red: 1, green: 187/255, blue: 0, alpha: 1)
            $0.layer.cornerRadius = 3
            view.addSubview($0)
        }
        
        popularLabel.text = NSLocalizedString("subscription.offer.mostPopular", comment: "")
        discountLabel.text = "-42%"
        [popularLabel, discountLabel].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            $0.textColor = .black
            $0.font = .systemFont(ofSize: 24, weight: .bold)
            $0.textAlignment = .center
            view.addSubview($0)
        }

        // Welcome offer
        welcomeCard.cardTitleLabel.text = NSLocalizedString("subscription.offer.welcome", comment: "")
        welcomeCard.cardPriceLabel.text = "$24.99" + NSLocalizedString("subscription.offer.yearPrice", comment: "")
        welcomeCard.cardSubPriceLabel.text = "$2.92" + NSLocalizedString("subscription.offer.monthPrice", comment: "")
        welcomeCard.cardExtraLabel.text = NSLocalizedString("subscription.offer.year", comment: "")
        view.addSubview(welcomeCard)
        
        // Free Access
        freeCard.cardTitleLabel.text = NSLocalizedString("subscription.freeAccess.title", comment: "")
        updateFreeCardLabel()
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
            popularBadge.widthAnchor.constraint(equalToConstant: 250), // Increased for Russian
            popularBadge.heightAnchor.constraint(equalToConstant: 39.51),
            
            popularLabel.centerXAnchor.constraint(equalTo: popularBadge.centerXAnchor),
            popularLabel.centerYAnchor.constraint(equalTo: popularBadge.centerYAnchor),
            
            discountBadge.leadingAnchor.constraint(equalTo: popularBadge.trailingAnchor, constant: 20),
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

    private func updateFreeCardLabel() {
        if SubscriptionStore.isFreeAccessActive {
            freeCard.cardExtraLabel.text = String(format: NSLocalizedString("subscription.freeAccess.remaining", comment: ""), SubscriptionStore.freeVideosRemaining)
        } else {
            freeCard.cardExtraLabel.text = NSLocalizedString("subscription.freeAccess.description", comment: "")
        }
    }

    private func setupRightSideContent() {
        rightTitleLabel.text = NSLocalizedString("subscription.right.title", comment: "")
        rightTitleLabel.font = .systemFont(ofSize: 36, weight: .bold)
        rightTitleLabel.numberOfLines = 0
        
        rightDescriptionLabel.text = NSLocalizedString("subscription.freeAccess.rightDescription", comment: "")
        rightDescriptionLabel.font = .systemFont(ofSize: 25, weight: .bold)
        rightDescriptionLabel.textColor = UIColor(white: 1, alpha: 0.5)
        rightDescriptionLabel.numberOfLines = 0
        
        rightSubtitleLabel.text = NSLocalizedString("subscription.right.subtitle", comment: "")
        rightSubtitleLabel.font = .systemFont(ofSize: 25, weight: .bold)
        rightSubtitleLabel.numberOfLines = 0
        
        [rightTitleLabel, rightSubtitleLabel, rightDescriptionLabel].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            $0.textColor = .white
            view.addSubview($0)
        }
        
        NSLayoutConstraint.activate([
            rightTitleLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 880),
            rightTitleLabel.topAnchor.constraint(equalTo: view.topAnchor, constant: 159),
            rightTitleLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -90),
            
            rightDescriptionLabel.leadingAnchor.constraint(equalTo: rightTitleLabel.leadingAnchor),
            rightDescriptionLabel.topAnchor.constraint(equalTo: rightTitleLabel.bottomAnchor, constant: 24),
            rightDescriptionLabel.trailingAnchor.constraint(equalTo: rightTitleLabel.trailingAnchor),
            
            rightSubtitleLabel.leadingAnchor.constraint(equalTo: rightTitleLabel.leadingAnchor),
            rightSubtitleLabel.topAnchor.constraint(equalTo: rightDescriptionLabel.bottomAnchor, constant: 32),
            rightSubtitleLabel.trailingAnchor.constraint(equalTo: rightTitleLabel.trailingAnchor)
        ])
    }

    @objc private func offerTapped(_ sender: SubscriptionOfferCard) {
        if sender == freeCard {
            // Free Access: включаем триал и переходим на главный экран.
            // (Если ранее подписка могла быть выставлена "по клику", сбрасываем её.)
            SubscriptionStore.isSubscribed = false
            SubscriptionStore.isFreeAccessActive = true
            finishSubscriptionFlow()
            return
        }

        // Платные опции: показываем окно оплаты и только после подтверждения включаем подписку.
        presentPaymentAlert(for: sender)
    }

    private func presentPaymentAlert(for offer: SubscriptionOfferCard) {
        guard presentedViewController == nil else { return }

        let offerTitle = offer.cardTitleLabel.text?.trimmingCharacters(in: .whitespacesAndNewlines)
        let offerPrice = offer.cardPriceLabel.text?.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = NSLocalizedString("subscription.title", comment: "")

        var messageParts: [String] = []
        if let offerTitle, !offerTitle.isEmpty { messageParts.append(offerTitle) }
        if let offerPrice, !offerPrice.isEmpty { messageParts.append(offerPrice) }
        let message = messageParts.isEmpty ? nil : messageParts.joined(separator: "\n")

        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: NSLocalizedString("button.back", comment: ""), style: .cancel))
        alert.addAction(UIAlertAction(title: NSLocalizedString("subscription.button.subscribe", comment: ""), style: .default) { [weak self] _ in
            SubscriptionStore.isFreeAccessActive = false
            SubscriptionStore.isSubscribed = true
            self?.finishSubscriptionFlow()
        })
        present(alert, animated: true)
    }

    private func finishSubscriptionFlow() {
        if presentingViewController != nil {
            dismiss(animated: true)
            return
        }
        if let nav = navigationController {
            nav.popViewController(animated: true)
            return
        }
        // Фолбэк (на случай экзотических сценариев без nav/present).
        (UIApplication.shared.delegate as? AppDelegate)?.showHome()
    }
}

private enum KeychainKV {
    private static let service = Bundle.main.bundleIdentifier ?? "TGtv"

    static func string(forKey key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true
        ]

        // На tvOS `LAContext` недоступен, а наши ключи не создаются с AccessControl,
        // поэтому запрос не должен требовать UI-аутентификации.

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func setString(_ value: String, forKey key: String) {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]

        let attributes: [String: Any] = [
            kSecValueData as String: data
        ]

        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var addQuery = query
            addQuery[kSecValueData as String] = data
            _ = SecItemAdd(addQuery as CFDictionary, nil)
        }
    }
}

enum SubscriptionStore {
    private static let subKey = "tgtv.subscription.active"
    private static let freeAccessKey = "tgtv.free_access.active"
    private static let freeViewsKey = "tgtv.free_views.remaining"

    /// “Выбрана подписка” = либо оплачено, либо выбран бесплатный доступ (даже если лимит просмотров уже исчерпан).
    static var hasChosenPlan: Bool {
        isSubscribed || isFreeAccessActive
    }

    static var isSubscribed: Bool {
        get {
            if let value = KeychainKV.string(forKey: subKey) {
                return value == "1"
            }
            if UserDefaults.standard.object(forKey: subKey) != nil {
                let value = UserDefaults.standard.bool(forKey: subKey)
                KeychainKV.setString(value ? "1" : "0", forKey: subKey)
                return value
            }
            return false
        }
        set {
            KeychainKV.setString(newValue ? "1" : "0", forKey: subKey)
            UserDefaults.standard.set(newValue, forKey: subKey)
        }
    }

    static var isFreeAccessActive: Bool {
        get {
            if let value = KeychainKV.string(forKey: freeAccessKey) {
                return value == "1"
            }
            if UserDefaults.standard.object(forKey: freeAccessKey) != nil {
                let value = UserDefaults.standard.bool(forKey: freeAccessKey)
                KeychainKV.setString(value ? "1" : "0", forKey: freeAccessKey)
                return value
            }
            return false
        }
        set {
            KeychainKV.setString(newValue ? "1" : "0", forKey: freeAccessKey)
            UserDefaults.standard.set(newValue, forKey: freeAccessKey)
        }
    }

    static var freeVideosRemaining: Int {
        get {
            if let value = KeychainKV.string(forKey: freeViewsKey), let intValue = Int(value) {
                return intValue
            }
            if UserDefaults.standard.object(forKey: freeViewsKey) != nil {
                let value = UserDefaults.standard.integer(forKey: freeViewsKey)
                KeychainKV.setString("\(value)", forKey: freeViewsKey)
                return value
            }
            return 3
        }
        set {
            KeychainKV.setString("\(newValue)", forKey: freeViewsKey)
            UserDefaults.standard.set(newValue, forKey: freeViewsKey)
        }
    }

    static var canWatchVideo: Bool {
        if isSubscribed { return true }
        if isFreeAccessActive && freeVideosRemaining > 0 { return true }
        return false
    }

    static func didWatchVideo() {
        guard !isSubscribed && isFreeAccessActive else { return }
        freeVideosRemaining = max(0, freeVideosRemaining - 1)
    }
}
