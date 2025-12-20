import UIKit
import TDLibKit
import Combine

final class AuthQRController: UIViewController {
    private let authService: AuthService
    private var qrContainerView: UIView!
    private var platterBlurView: UIVisualEffectView!
    private var platterTintView: UIView!
    private var qrImageView: UIImageView!
    private var tvPlusLogoImageView: UIImageView!
    private var tvChannelsLogoImageView: UIImageView!
    private var titleLabel: UILabel!
    private var statusLabel: UILabel!
    private var qrHeaderLabel: UILabel!
    private var qrStepsLabel: UILabel!
    private var loadingIndicator: UIActivityIndicatorView!
    private var passwordTextField: UITextField!
    private var loginButton: UIButton!
    private var passwordView: UIView!
    private var backgroundImageView: UIImageView!
    private var debugLogView: UITextView!
    private var debugLogContainer: UIView!
    private var cancellables = Set<AnyCancellable>()

    // MARK: - Scaled layout (base: 1920x1080)
    private struct LayoutBase {
        static let screenW: CGFloat = 1920
        static let screenH: CGFloat = 1080

        // Left panel
        static let panelW: CGFloat = 548
        static let panelH: CGFloat = 756
        static let panelLeading: CGFloat = 80
        static let panelTop: CGFloat = 174 // 1080 * 0.1611

        // Internal paddings
        static let labelSideInset: CGFloat = 60
        static let panelCornerRadius: CGFloat = 12
        static let channelsLogoBorderWidth: CGFloat = 1

        // Logos
        static let tvPlusTop: CGFloat = 49
        static let tvPlusW: CGFloat = 170
        static let tvPlusH: CGFloat = 64

        static let tvChannelsTop: CGFloat = 128
        static let tvChannelsW: CGFloat = 132
        static let tvChannelsH: CGFloat = 18

        // Title/steps positions (relative to panel centerY)
        static let headerCenterYOffset: CGFloat = -166.29
        static let headerH: CGFloat = 38

        static let stepsCenterYOffset: CGFloat = -56.29
        static let stepsH: CGFloat = 128

        // QR
        static let qrTop: CGFloat = 410
        static let qrSize: CGFloat = 297
    }

    private var panelWidthConstraint: NSLayoutConstraint?
    private var panelHeightConstraint: NSLayoutConstraint?
    private var panelLeadingConstraint: NSLayoutConstraint?
    private var panelTopConstraint: NSLayoutConstraint?

    private var tvPlusTopConstraint: NSLayoutConstraint?
    private var tvPlusWConstraint: NSLayoutConstraint?
    private var tvPlusHConstraint: NSLayoutConstraint?

    private var tvChannelsTopConstraint: NSLayoutConstraint?
    private var tvChannelsWConstraint: NSLayoutConstraint?
    private var tvChannelsHConstraint: NSLayoutConstraint?

    private var headerLeadingConstraint: NSLayoutConstraint?
    private var headerTrailingConstraint: NSLayoutConstraint?
    private var headerHeightConstraint: NSLayoutConstraint?
    private var headerCenterYConstraint: NSLayoutConstraint?

    private var stepsLeadingConstraint: NSLayoutConstraint?
    private var stepsTrailingConstraint: NSLayoutConstraint?
    private var stepsHeightConstraint: NSLayoutConstraint?
    private var stepsCenterYConstraint: NSLayoutConstraint?

    private var qrTopConstraint: NSLayoutConstraint?
    private var qrWConstraint: NSLayoutConstraint?
    private var qrHConstraint: NSLayoutConstraint?
    
    private var debugLogTopConstraint: NSLayoutConstraint?
    private var debugLogBottomConstraint: NSLayoutConstraint?
    private var debugLogTrailingConstraint: NSLayoutConstraint?
    private var debugLogWidthConstraint: NSLayoutConstraint?
    
    // tvOS safe area (Apple HIG)
    private let tvSafeInsets = UIEdgeInsets(top: 60, left: 80, bottom: 60, right: 80)
    
    init(authService: AuthService) {
        self.authService = authService
        super.init(nibName: nil, bundle: nil)
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
        setupBindings()
    }
    
    private func setupUI() {
        // Background image + gradient overlay
        backgroundImageView = UIImageView()
        backgroundImageView.translatesAutoresizingMaskIntoConstraints = false
        backgroundImageView.contentMode = .scaleAspectFill
        // Пытаемся загрузить фон из ресурсов; если не найден — ставим запасной тёмный цвет
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

        let gradientView = UIView()
        gradientView.translatesAutoresizingMaskIntoConstraints = false
        // Убираем затемнение фоновой картинки
        gradientView.backgroundColor = .clear
        gradientView.isUserInteractionEnabled = false
        view.addSubview(gradientView)
        NSLayoutConstraint.activate([
            gradientView.topAnchor.constraint(equalTo: view.topAnchor),
            gradientView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            gradientView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            gradientView.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])
        
        // Title
        titleLabel = UILabel()
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        // Требование: убрать надпись Telegram сверху
        titleLabel.text = nil
        titleLabel.textColor = .white
        titleLabel.font = .systemFont(ofSize: 52, weight: .bold)
        titleLabel.textAlignment = .center
        titleLabel.isHidden = true
        view.addSubview(titleLabel)
        
        // Loading indicator
        loadingIndicator = UIActivityIndicatorView(style: .large)
        loadingIndicator.translatesAutoresizingMaskIntoConstraints = false
        loadingIndicator.color = .white
        loadingIndicator.startAnimating()
        view.addSubview(loadingIndicator)
        
        // QR Container with shadow
        qrContainerView = UIView()
        qrContainerView.translatesAutoresizingMaskIntoConstraints = false
        // "Platter": blur + tint (как в Figma: rgba(30,30,30,0.5) + backdrop blur)
        qrContainerView.backgroundColor = .clear
        qrContainerView.clipsToBounds = true
        qrContainerView.layer.cornerRadius = LayoutBase.panelCornerRadius
        // Тень блока (как в макете)
        qrContainerView.layer.shadowColor = UIColor(red: 0, green: 0, blue: 0, alpha: 0.25).cgColor
        qrContainerView.layer.shadowOpacity = 1
        qrContainerView.layer.shadowRadius = 4
        qrContainerView.layer.shadowOffset = CGSize(width: 0, height: 4)
        qrContainerView.isHidden = true
        view.addSubview(qrContainerView)

        // В Figma это backdrop-filter blur без дополнительного затемнения от blur-style,
        // поэтому используем более нейтральный .regular (а "цвет" даёт platterTintView).
        platterBlurView = UIVisualEffectView(effect: UIBlurEffect(style: .regular))
        platterBlurView.translatesAutoresizingMaskIntoConstraints = false
        platterBlurView.isUserInteractionEnabled = false
        qrContainerView.addSubview(platterBlurView)

        platterTintView = UIView()
        platterTintView.translatesAutoresizingMaskIntoConstraints = false
        platterTintView.isUserInteractionEnabled = false
        // Чуть более "матовый" (можно подкрутить alpha при желании)
        platterTintView.backgroundColor = UIColor(red: 30/255, green: 30/255, blue: 30/255, alpha: 0.5)
        qrContainerView.addSubview(platterTintView)

        NSLayoutConstraint.activate([
            platterBlurView.topAnchor.constraint(equalTo: qrContainerView.topAnchor),
            platterBlurView.bottomAnchor.constraint(equalTo: qrContainerView.bottomAnchor),
            platterBlurView.leadingAnchor.constraint(equalTo: qrContainerView.leadingAnchor),
            platterBlurView.trailingAnchor.constraint(equalTo: qrContainerView.trailingAnchor),

            platterTintView.topAnchor.constraint(equalTo: qrContainerView.topAnchor),
            platterTintView.bottomAnchor.constraint(equalTo: qrContainerView.bottomAnchor),
            platterTintView.leadingAnchor.constraint(equalTo: qrContainerView.leadingAnchor),
            platterTintView.trailingAnchor.constraint(equalTo: qrContainerView.trailingAnchor)
        ])

        // Логотипы (есть в ассетах)
        tvPlusLogoImageView = UIImageView()
        tvPlusLogoImageView.translatesAutoresizingMaskIntoConstraints = false
        tvPlusLogoImageView.contentMode = .scaleAspectFit
        tvPlusLogoImageView.image = UIImage(named: "TVPlusLogo")
        qrContainerView.addSubview(tvPlusLogoImageView)

        tvChannelsLogoImageView = UIImageView()
        tvChannelsLogoImageView.translatesAutoresizingMaskIntoConstraints = false
        tvChannelsLogoImageView.contentMode = .scaleAspectFit
        tvChannelsLogoImageView.image = UIImage(named: "TVChannelsLogo")
        // В макете у Channels Logo есть обводка 1px
        tvChannelsLogoImageView.layer.borderColor = UIColor.black.cgColor
        qrContainerView.addSubview(tvChannelsLogoImageView)

        // Заголовок
        qrHeaderLabel = UILabel()
        qrHeaderLabel.translatesAutoresizingMaskIntoConstraints = false
        qrHeaderLabel.textColor = UIColor(red: 1, green: 1, blue: 1, alpha: 1)
        qrHeaderLabel.font = .systemFont(ofSize: 31, weight: .bold)
        qrHeaderLabel.textAlignment = .center
        qrHeaderLabel.numberOfLines = 1
        qrHeaderLabel.text = "Scan from Mobile Telegram"
        qrContainerView.addSubview(qrHeaderLabel)

        // Шаги (как в присланном макете)
        qrStepsLabel = UILabel()
        qrStepsLabel.translatesAutoresizingMaskIntoConstraints = false
        qrStepsLabel.textColor = UIColor(red: 1, green: 1, blue: 1, alpha: 0.5)
        qrStepsLabel.font = .systemFont(ofSize: 25, weight: .bold)
        qrStepsLabel.textAlignment = .center
        qrStepsLabel.numberOfLines = 0
        qrStepsLabel.lineBreakMode = .byWordWrapping
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineHeightMultiple = 1.07
        // Важно: для attributedText выравнивание задаём здесь, иначе может выглядеть как "справа"
        paragraphStyle.alignment = .center
        paragraphStyle.baseWritingDirection = .leftToRight
        qrStepsLabel.attributedText = NSMutableAttributedString(
            string: "1. Open Telegram on your phone\n2. Go to Settings > Devices > Link Device\n3. Scan this image to Log in",
            attributes: [.paragraphStyle: paragraphStyle]
        )
        qrContainerView.addSubview(qrStepsLabel)

        qrImageView = UIImageView()
        qrImageView.translatesAutoresizingMaskIntoConstraints = false
        qrImageView.contentMode = .scaleAspectFit
        qrImageView.backgroundColor = .white
        qrContainerView.addSubview(qrImageView)
        
        // Status label
        statusLabel = UILabel()
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.textColor = UIColor(white: 0.7, alpha: 1)
        statusLabel.textAlignment = .center
        statusLabel.text = "Подготовка..."
        statusLabel.numberOfLines = 0
        statusLabel.font = .systemFont(ofSize: 32, weight: .medium)
        view.addSubview(statusLabel)
        
        // Password view
        passwordView = UIView()
        passwordView.translatesAutoresizingMaskIntoConstraints = false
        passwordView.backgroundColor = UIColor(red: 0.12, green: 0.12, blue: 0.16, alpha: 1)
        passwordView.layer.cornerRadius = 24
        passwordView.isHidden = true
        view.addSubview(passwordView)
        
        passwordTextField = UITextField()
        passwordTextField.translatesAutoresizingMaskIntoConstraints = false
        passwordTextField.backgroundColor = UIColor(white: 0.2, alpha: 1)
        passwordTextField.textColor = .white
        passwordTextField.font = .systemFont(ofSize: 28, weight: .regular)
        passwordTextField.layer.cornerRadius = 14
        passwordTextField.isSecureTextEntry = true
        passwordTextField.placeholder = "Введите пароль"
        passwordTextField.leftView = UIView(frame: CGRect(x: 0, y: 0, width: 20, height: 60))
        passwordTextField.leftViewMode = .always
        passwordTextField.rightView = UIView(frame: CGRect(x: 0, y: 0, width: 20, height: 60))
        passwordTextField.rightViewMode = .always
        passwordTextField.clearButtonMode = .whileEditing
        passwordTextField.returnKeyType = .done
        passwordTextField.delegate = self
        passwordView.addSubview(passwordTextField)
        
        loginButton = UIButton(type: .system)
        loginButton.translatesAutoresizingMaskIntoConstraints = false
        loginButton.setTitle("Войти", for: .normal)
        loginButton.titleLabel?.font = .systemFont(ofSize: 28, weight: .semibold)
        loginButton.backgroundColor = UIColor(red: 0.2, green: 0.5, blue: 0.95, alpha: 1)
        loginButton.setTitleColor(.white, for: .normal)
        loginButton.layer.cornerRadius = 14
        loginButton.addTarget(self, action: #selector(loginButtonTapped), for: .primaryActionTriggered)
        passwordView.addSubview(loginButton)
        
        // Panel placement (left block)
        panelLeadingConstraint = qrContainerView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: LayoutBase.panelLeading)
        panelTopConstraint = qrContainerView.topAnchor.constraint(equalTo: view.topAnchor, constant: LayoutBase.panelTop)
        panelWidthConstraint = qrContainerView.widthAnchor.constraint(equalToConstant: LayoutBase.panelW)
        panelHeightConstraint = qrContainerView.heightAnchor.constraint(equalToConstant: LayoutBase.panelH)

        // Logos
        tvPlusTopConstraint = tvPlusLogoImageView.topAnchor.constraint(equalTo: qrContainerView.topAnchor, constant: LayoutBase.tvPlusTop)
        tvPlusWConstraint = tvPlusLogoImageView.widthAnchor.constraint(equalToConstant: LayoutBase.tvPlusW)
        tvPlusHConstraint = tvPlusLogoImageView.heightAnchor.constraint(equalToConstant: LayoutBase.tvPlusH)

        tvChannelsTopConstraint = tvChannelsLogoImageView.topAnchor.constraint(equalTo: qrContainerView.topAnchor, constant: LayoutBase.tvChannelsTop)
        tvChannelsWConstraint = tvChannelsLogoImageView.widthAnchor.constraint(equalToConstant: LayoutBase.tvChannelsW)
        tvChannelsHConstraint = tvChannelsLogoImageView.heightAnchor.constraint(equalToConstant: LayoutBase.tvChannelsH)

        // Header
        headerLeadingConstraint = qrHeaderLabel.leadingAnchor.constraint(equalTo: qrContainerView.leadingAnchor, constant: LayoutBase.labelSideInset)
        headerTrailingConstraint = qrHeaderLabel.trailingAnchor.constraint(equalTo: qrContainerView.trailingAnchor, constant: -LayoutBase.labelSideInset)
        headerHeightConstraint = qrHeaderLabel.heightAnchor.constraint(equalToConstant: LayoutBase.headerH)
        headerCenterYConstraint = qrHeaderLabel.centerYAnchor.constraint(equalTo: qrContainerView.centerYAnchor, constant: LayoutBase.headerCenterYOffset)

        // Steps
        stepsLeadingConstraint = qrStepsLabel.leadingAnchor.constraint(equalTo: qrContainerView.leadingAnchor, constant: LayoutBase.labelSideInset)
        stepsTrailingConstraint = qrStepsLabel.trailingAnchor.constraint(equalTo: qrContainerView.trailingAnchor, constant: -LayoutBase.labelSideInset)
        stepsHeightConstraint = qrStepsLabel.heightAnchor.constraint(equalToConstant: LayoutBase.stepsH)
        stepsCenterYConstraint = qrStepsLabel.centerYAnchor.constraint(equalTo: qrContainerView.centerYAnchor, constant: LayoutBase.stepsCenterYOffset)

        // QR
        qrTopConstraint = qrImageView.topAnchor.constraint(equalTo: qrContainerView.topAnchor, constant: LayoutBase.qrTop)
        qrWConstraint = qrImageView.widthAnchor.constraint(equalToConstant: LayoutBase.qrSize)
        qrHConstraint = qrImageView.heightAnchor.constraint(equalToConstant: LayoutBase.qrSize)

        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: qrContainerView.leadingAnchor, constant: 20),
            titleLabel.trailingAnchor.constraint(equalTo: qrContainerView.trailingAnchor, constant: -20),
            titleLabel.topAnchor.constraint(equalTo: view.topAnchor, constant: tvSafeInsets.top + 40),
            
            loadingIndicator.centerXAnchor.constraint(equalTo: qrContainerView.centerXAnchor),
            loadingIndicator.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            
            panelLeadingConstraint!,
            panelTopConstraint!,
            panelWidthConstraint!,
            panelHeightConstraint!,

            tvPlusLogoImageView.centerXAnchor.constraint(equalTo: qrContainerView.centerXAnchor),
            tvPlusTopConstraint!,
            tvPlusWConstraint!,
            tvPlusHConstraint!,

            tvChannelsLogoImageView.centerXAnchor.constraint(equalTo: qrContainerView.centerXAnchor),
            tvChannelsTopConstraint!,
            tvChannelsWConstraint!,
            tvChannelsHConstraint!,

            headerLeadingConstraint!,
            headerTrailingConstraint!,
            headerHeightConstraint!,
            headerCenterYConstraint!,

            stepsLeadingConstraint!,
            stepsTrailingConstraint!,
            stepsHeightConstraint!,
            stepsCenterYConstraint!,

            qrImageView.centerXAnchor.constraint(equalTo: qrContainerView.centerXAnchor),
            qrTopConstraint!,
            qrWConstraint!,
            qrHConstraint!,
            
            statusLabel.centerXAnchor.constraint(equalTo: qrContainerView.centerXAnchor),
            statusLabel.topAnchor.constraint(equalTo: qrContainerView.bottomAnchor, constant: 40),
            statusLabel.leadingAnchor.constraint(equalTo: qrContainerView.leadingAnchor, constant: 8),
            statusLabel.trailingAnchor.constraint(equalTo: qrContainerView.trailingAnchor, constant: -8),
            
            passwordView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            passwordView.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            passwordView.widthAnchor.constraint(equalToConstant: 500),
            passwordView.heightAnchor.constraint(equalToConstant: 200),
            
            passwordTextField.topAnchor.constraint(equalTo: passwordView.topAnchor, constant: 30),
            passwordTextField.leadingAnchor.constraint(equalTo: passwordView.leadingAnchor, constant: 30),
            passwordTextField.trailingAnchor.constraint(equalTo: passwordView.trailingAnchor, constant: -30),
            passwordTextField.heightAnchor.constraint(equalToConstant: 60),
            
            loginButton.topAnchor.constraint(equalTo: passwordTextField.bottomAnchor, constant: 20),
            loginButton.leadingAnchor.constraint(equalTo: passwordView.leadingAnchor, constant: 30),
            loginButton.trailingAnchor.constraint(equalTo: passwordView.trailingAnchor, constant: -30),
            loginButton.heightAnchor.constraint(equalToConstant: 60)
        ])
        
        let tapGesture = UITapGestureRecognizer(target: self, action: #selector(dismissKeyboard))
        view.addGestureRecognizer(tapGesture)

        // Debug Log View
        debugLogContainer = UIView()
        debugLogContainer.translatesAutoresizingMaskIntoConstraints = false
        debugLogContainer.backgroundColor = UIColor(white: 0, alpha: 0.6)
        debugLogContainer.layer.cornerRadius = 12
        debugLogContainer.clipsToBounds = true
        view.addSubview(debugLogContainer)

        debugLogView = UITextView()
        debugLogView.translatesAutoresizingMaskIntoConstraints = false
        debugLogView.backgroundColor = .clear
        debugLogView.textColor = .green
        debugLogView.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
        debugLogContainer.addSubview(debugLogView)

        debugLogTopConstraint = debugLogContainer.topAnchor.constraint(equalTo: view.topAnchor, constant: 60)
        debugLogBottomConstraint = debugLogContainer.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -60)
        debugLogTrailingConstraint = debugLogContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -60)
        debugLogWidthConstraint = debugLogContainer.widthAnchor.constraint(equalTo: view.widthAnchor, multiplier: 0.35)

        NSLayoutConstraint.activate([
            debugLogTopConstraint!,
            debugLogBottomConstraint!,
            debugLogTrailingConstraint!,
            debugLogWidthConstraint!,

            debugLogView.topAnchor.constraint(equalTo: debugLogContainer.topAnchor, constant: 10),
            debugLogView.bottomAnchor.constraint(equalTo: debugLogContainer.bottomAnchor, constant: -10),
            debugLogView.leadingAnchor.constraint(equalTo: debugLogContainer.leadingAnchor, constant: 10),
            debugLogView.trailingAnchor.constraint(equalTo: debugLogContainer.trailingAnchor, constant: -10)
        ])

        // Первичная настройка масштабирования (после создания constraints)
        updateScaledLayout()
    }
    
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        updateScaledLayout()
    }

    private func updateScaledLayout() {
        // Единый коэффициент масштаба от эталона 1920x1080, чтобы сохранять пропорции
        let w = view.bounds.width
        let h = view.bounds.height
        guard w > 0, h > 0 else { return }
        let scale = min(w / LayoutBase.screenW, h / LayoutBase.screenH)

        panelWidthConstraint?.constant = LayoutBase.panelW * scale
        panelHeightConstraint?.constant = LayoutBase.panelH * scale
        panelLeadingConstraint?.constant = LayoutBase.panelLeading * scale
        panelTopConstraint?.constant = LayoutBase.panelTop * scale

        // Скругление и обводка тоже масштабируем
        qrContainerView.layer.cornerRadius = LayoutBase.panelCornerRadius * scale
        platterBlurView.layer.cornerRadius = qrContainerView.layer.cornerRadius
        platterBlurView.clipsToBounds = true
        platterTintView.layer.cornerRadius = qrContainerView.layer.cornerRadius
        platterTintView.clipsToBounds = true
        tvChannelsLogoImageView.layer.borderWidth = LayoutBase.channelsLogoBorderWidth * scale

        tvPlusTopConstraint?.constant = LayoutBase.tvPlusTop * scale
        tvPlusWConstraint?.constant = LayoutBase.tvPlusW * scale
        tvPlusHConstraint?.constant = LayoutBase.tvPlusH * scale

        tvChannelsTopConstraint?.constant = LayoutBase.tvChannelsTop * scale
        tvChannelsWConstraint?.constant = LayoutBase.tvChannelsW * scale
        tvChannelsHConstraint?.constant = LayoutBase.tvChannelsH * scale

        headerLeadingConstraint?.constant = LayoutBase.labelSideInset * scale
        headerTrailingConstraint?.constant = -(LayoutBase.labelSideInset * scale)
        headerHeightConstraint?.constant = LayoutBase.headerH * scale
        headerCenterYConstraint?.constant = LayoutBase.headerCenterYOffset * scale

        stepsLeadingConstraint?.constant = LayoutBase.labelSideInset * scale
        stepsTrailingConstraint?.constant = -(LayoutBase.labelSideInset * scale)
        stepsHeightConstraint?.constant = LayoutBase.stepsH * scale
        stepsCenterYConstraint?.constant = LayoutBase.stepsCenterYOffset * scale

        qrTopConstraint?.constant = LayoutBase.qrTop * scale
        qrWConstraint?.constant = LayoutBase.qrSize * scale
        qrHConstraint?.constant = LayoutBase.qrSize * scale

        debugLogTopConstraint?.constant = 60 * scale
        debugLogBottomConstraint?.constant = -60 * scale
        debugLogTrailingConstraint?.constant = -60 * scale
        debugLogView.font = .monospacedSystemFont(ofSize: 14 * scale, weight: .regular)

        // Масштабируем шрифты тоже пропорционально
        qrHeaderLabel.font = .systemFont(ofSize: 31 * scale, weight: .bold)
        qrStepsLabel.font = .systemFont(ofSize: 25 * scale, weight: .bold)

        // shadowPath должен соответствовать актуальным bounds после масштабирования
        qrContainerView.layer.shadowPath = UIBezierPath(
            roundedRect: qrContainerView.bounds,
            cornerRadius: qrContainerView.layer.cornerRadius
        ).cgPath
    }
    
    private func setupBindings() {
        authService.$qrCodeUrl
            .receive(on: DispatchQueue.main)
            .sink { [weak self] url in
                guard let self, let url else { return }
                self.loadingIndicator.stopAnimating()
                self.loadingIndicator.isHidden = true
                self.qrContainerView.isHidden = false
                self.passwordView.isHidden = true
                // Текст инструкции теперь внутри qrContainerView
                self.statusLabel.text = nil
                self.statusLabel.isHidden = true
                
                if let qrImage = self.generateQRCode(from: url) {
                    self.qrImageView.image = qrImage
                }
            }
            .store(in: &cancellables)
        
        authService.$needPassword
            .receive(on: DispatchQueue.main)
            .sink { [weak self] needPassword in
                guard let self, needPassword else { return }
                self.loadingIndicator.stopAnimating()
                self.loadingIndicator.isHidden = true
                self.qrContainerView.isHidden = true
                self.passwordView.isHidden = false
                self.statusLabel.isHidden = false
                
                let hint = self.authService.passwordHint.isEmpty
                    ? "Введите пароль от аккаунта"
                    : "Подсказка: \(self.authService.passwordHint)"
                self.statusLabel.text = hint
                
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    self.passwordTextField.becomeFirstResponder()
                }
            }
            .store(in: &cancellables)
            
        authService.$isAuthorized
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isAuthorized in
                guard let self else { return }
                
                if isAuthorized {
                    self.loadingIndicator.stopAnimating()
                    self.loadingIndicator.isHidden = true
                    self.qrContainerView.isHidden = true
                    self.passwordView.isHidden = true
                    self.statusLabel.isHidden = false
                    self.statusLabel.text = "Авторизация успешна ✓"
                    self.statusLabel.textColor = UIColor(red: 0.3, green: 0.8, blue: 0.4, alpha: 1)
                    
                    self.loadingIndicator.isHidden = false
                    self.loadingIndicator.startAnimating()
                    
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        self.loadingIndicator.stopAnimating()
                        self.loadingIndicator.isHidden = true
                    }
                } else {
                    // Сброс UI при выходе, чтобы не застревать на экране успеха
                    self.statusLabel.text = "Подготовка..."
                    self.statusLabel.textColor = UIColor(white: 0.7, alpha: 1)
                    self.statusLabel.isHidden = false
                    self.qrContainerView.isHidden = true
                    self.passwordView.isHidden = true
                    self.loadingIndicator.isHidden = false
                    self.loadingIndicator.startAnimating()
                    
                    // Запрашиваем актуальное состояние авторизации и QR
                    Task { @MainActor in
                        await self.authService.checkAuthState()
                    }
                }
            }
            .store(in: &cancellables)
            
        DebugLogger.shared.$logs
            .receive(on: DispatchQueue.main)
            .sink { [weak self] logs in
                self?.debugLogView.text = logs
                if !logs.isEmpty {
                    let range = NSMakeRange(logs.count - 1, 1)
                    self?.debugLogView.scrollRangeToVisible(range)
                }
            }
            .store(in: &cancellables)
    }
    @objc private func loginButtonTapped() {
        guard let password = passwordTextField.text, !password.isEmpty else {
            statusLabel.text = "Введите пароль"
            statusLabel.textColor = UIColor(red: 1, green: 0.4, blue: 0.4, alpha: 1)
            DebugLogger.shared.log("AuthQRController: Попытка входа с пустым паролем")
            return
        }
        sendPassword(password)
    }
    
    private func sendPassword(_ password: String) {
        DebugLogger.shared.log("AuthQRController: Отправка пароля")
        loginButton.isEnabled = false
        loginButton.setTitle("Вход...", for: .disabled)
        loginButton.alpha = 0.6
        passwordTextField.isEnabled = false
        loadingIndicator.isHidden = false
        loadingIndicator.startAnimating()
        
        Task { @MainActor in
            let success = await authService.checkPassword(password)
            
            if !success {
                DebugLogger.shared.log("AuthQRController: Неверный пароль")
                statusLabel.text = "Неверный пароль"
                statusLabel.textColor = UIColor(red: 1, green: 0.4, blue: 0.4, alpha: 1)
                loginButton.isEnabled = true
                loginButton.setTitle("Войти", for: .normal)
                loginButton.alpha = 1
                passwordTextField.isEnabled = true
                passwordTextField.text = ""
                loadingIndicator.stopAnimating()
                loadingIndicator.isHidden = true
                passwordTextField.becomeFirstResponder()
            } else {
                DebugLogger.shared.log("AuthQRController: Пароль принят")
            }
        }
    }
    
    @objc private func dismissKeyboard() {
        view.endEditing(true)
    }
    
    private func generateQRCode(from string: String) -> UIImage? {
        let data = string.data(using: .ascii)
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(data, forKey: "inputMessage")
        
        let transform = CGAffineTransform(scaleX: 10, y: 10)
        guard let output = filter.outputImage?.transformed(by: transform) else { return nil }
        
        return UIImage(ciImage: output)
    }
    
    override var preferredFocusEnvironments: [UIFocusEnvironment] {
        guard isViewLoaded else { return super.preferredFocusEnvironments }
        
        if passwordView?.isHidden == false {
            return [passwordTextField, loginButton].compactMap { $0 }
        }
        
        if let qrContainerView, !qrContainerView.isHidden {
            return [qrContainerView]
        }
        
        return super.preferredFocusEnvironments
    }
    
    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        
        coordinator.addCoordinatedAnimations {
            if let nextView = context.nextFocusedView {
                if nextView === self.loginButton {
                    self.loginButton.transform = CGAffineTransform(scaleX: 1.06, y: 1.06)
                    self.loginButton.layer.shadowColor = UIColor.white.cgColor
                    self.loginButton.layer.shadowOpacity = 0.3
                    self.loginButton.layer.shadowRadius = 10
                } else if nextView === self.passwordTextField {
                    self.passwordTextField.transform = CGAffineTransform(scaleX: 1.02, y: 1.02)
                    self.passwordTextField.layer.borderColor = UIColor.white.cgColor
                    self.passwordTextField.layer.borderWidth = 2
                }
            }
            
            if let prevView = context.previouslyFocusedView {
                if prevView === self.loginButton {
                    self.loginButton.transform = .identity
                    self.loginButton.layer.shadowOpacity = 0
                } else if prevView === self.passwordTextField {
                    self.passwordTextField.transform = .identity
                    self.passwordTextField.layer.borderWidth = 0
                }
            }
        }
    }
}

extension AuthQRController: UITextFieldDelegate {
    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        if textField == passwordTextField, let password = textField.text, !password.isEmpty {
            sendPassword(password)
        }
        return true
    }
}
