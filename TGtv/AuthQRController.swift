import UIKit
import TDLibKit
import Combine

final class AuthQRController: UIViewController {
    private let authService: AuthService
    private var qrContainerView: UIView!
    private var qrImageView: UIImageView!
    private var titleLabel: UILabel!
    private var statusLabel: UILabel!
    private var loadingIndicator: UIActivityIndicatorView!
    private var passwordTextField: UITextField!
    private var loginButton: UIButton!
    private var passwordView: UIView!
    private var backgroundImageView: UIImageView!
    private var cancellables = Set<AnyCancellable>()
    
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
        gradientView.backgroundColor = UIColor(white: 0, alpha: 0.45)
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
        titleLabel.text = "Telegram"
        titleLabel.textColor = .white
        titleLabel.font = .systemFont(ofSize: 52, weight: .bold)
        titleLabel.textAlignment = .center
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
        qrContainerView.backgroundColor = UIColor(white: 0, alpha: 0.6)
        qrContainerView.layer.cornerRadius = 24
        qrContainerView.layer.shadowColor = UIColor.black.cgColor
        qrContainerView.layer.shadowOpacity = 0.25
        qrContainerView.layer.shadowOffset = .zero
        qrContainerView.layer.shadowRadius = 30
        qrContainerView.isHidden = true
        view.addSubview(qrContainerView)
        
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
        
        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: qrContainerView.leadingAnchor, constant: 20),
            titleLabel.trailingAnchor.constraint(equalTo: qrContainerView.trailingAnchor, constant: -20),
            titleLabel.topAnchor.constraint(equalTo: view.topAnchor, constant: tvSafeInsets.top + 40),
            
            loadingIndicator.centerXAnchor.constraint(equalTo: qrContainerView.centerXAnchor),
            loadingIndicator.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            
            qrContainerView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: tvSafeInsets.left),
            qrContainerView.centerYAnchor.constraint(equalTo: view.centerYAnchor, constant: -20),
            qrContainerView.widthAnchor.constraint(equalToConstant: 420),
            qrContainerView.heightAnchor.constraint(equalToConstant: 360),
            
            qrImageView.topAnchor.constraint(equalTo: qrContainerView.topAnchor, constant: 20),
            qrImageView.leadingAnchor.constraint(equalTo: qrContainerView.leadingAnchor, constant: 20),
            qrImageView.trailingAnchor.constraint(equalTo: qrContainerView.trailingAnchor, constant: -20),
            qrImageView.bottomAnchor.constraint(equalTo: qrContainerView.bottomAnchor, constant: -20),
            
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
    }
    
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
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
                self.statusLabel.text = "Отсканируйте QR-код\nв приложении Telegram"
                
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
    }
    
    @objc private func loginButtonTapped() {
        guard let password = passwordTextField.text, !password.isEmpty else {
            statusLabel.text = "Введите пароль"
            statusLabel.textColor = UIColor(red: 1, green: 0.4, blue: 0.4, alpha: 1)
            return
        }
        sendPassword(password)
    }
    
    private func sendPassword(_ password: String) {
        loginButton.isEnabled = false
        loginButton.setTitle("Вход...", for: .disabled)
        loginButton.alpha = 0.6
        passwordTextField.isEnabled = false
        loadingIndicator.isHidden = false
        loadingIndicator.startAnimating()
        
        Task { @MainActor in
            let success = await authService.checkPassword(password)
            
            if !success {
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
