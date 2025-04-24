import UIKit
import TDLibKit
import Combine

class AuthQRController: UIViewController {
    private let authService: AuthService
    private var qrImageView: UIImageView!
    private var statusLabel: UILabel!
    private var loadingIndicator: UIActivityIndicatorView!
    private var passwordTextField: UITextField!
    private var loginButton: UIButton!
    private var passwordView: UIView!
    private var cancellables = Set<AnyCancellable>()
    
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
        view.backgroundColor = .black
        
        loadingIndicator = UIActivityIndicatorView(style: .large)
        loadingIndicator.translatesAutoresizingMaskIntoConstraints = false
        loadingIndicator.color = .white
        loadingIndicator.startAnimating()
        view.addSubview(loadingIndicator)
        
        qrImageView = UIImageView()
        qrImageView.translatesAutoresizingMaskIntoConstraints = false
        qrImageView.contentMode = .scaleAspectFit
        qrImageView.backgroundColor = .white
        qrImageView.isHidden = true
        qrImageView.layer.cornerRadius = 10
        qrImageView.clipsToBounds = true
        view.addSubview(qrImageView)
        
        statusLabel = UILabel()
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.textColor = .white
        statusLabel.textAlignment = .center
        statusLabel.text = "Подготовка к авторизации..."
        statusLabel.numberOfLines = 0
        statusLabel.font = .systemFont(ofSize: 24)
        view.addSubview(statusLabel)
        
        passwordView = UIView()
        passwordView.translatesAutoresizingMaskIntoConstraints = false
        passwordView.backgroundColor = UIColor(white: 0.1, alpha: 1.0)
        passwordView.layer.cornerRadius = 10
        passwordView.isHidden = true
        view.addSubview(passwordView)
        
        passwordTextField = UITextField()
        passwordTextField.translatesAutoresizingMaskIntoConstraints = false
        passwordTextField.backgroundColor = UIColor(white: 0.2, alpha: 1.0)
        passwordTextField.textColor = .white
        passwordTextField.layer.cornerRadius = 8
        passwordTextField.isSecureTextEntry = true
        passwordTextField.placeholder = "Введите пароль"
        passwordTextField.leftView = UIView(frame: CGRect(x: 0, y: 0, width: 10, height: 50))
        passwordTextField.leftViewMode = .always
        passwordTextField.rightView = UIView(frame: CGRect(x: 0, y: 0, width: 10, height: 50))
        passwordTextField.rightViewMode = .always
        passwordTextField.clearButtonMode = .whileEditing
        passwordTextField.returnKeyType = .done
        passwordTextField.delegate = self
        passwordTextField.isUserInteractionEnabled = true
        passwordView.addSubview(passwordTextField)
        
        loginButton = UIButton(type: .system)
        loginButton.translatesAutoresizingMaskIntoConstraints = false
        loginButton.setTitle("Войти", for: .normal)
        loginButton.backgroundColor = .systemBlue
        loginButton.setTitleColor(.white, for: .normal)
        loginButton.layer.cornerRadius = 8
        loginButton.isUserInteractionEnabled = true
        loginButton.addTarget(self, action: #selector(loginButtonTapped), for: .primaryActionTriggered)
        passwordView.addSubview(loginButton)
        
        NSLayoutConstraint.activate([
            loadingIndicator.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            loadingIndicator.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            
            qrImageView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            qrImageView.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            qrImageView.widthAnchor.constraint(equalToConstant: 300),
            qrImageView.heightAnchor.constraint(equalToConstant: 300),
            
            statusLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            statusLabel.topAnchor.constraint(equalTo: qrImageView.bottomAnchor, constant: 20),
            statusLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            statusLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            
            passwordView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            passwordView.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            passwordView.widthAnchor.constraint(equalToConstant: 400),
            passwordView.heightAnchor.constraint(equalToConstant: 150),
            
            passwordTextField.topAnchor.constraint(equalTo: passwordView.topAnchor, constant: 20),
            passwordTextField.leadingAnchor.constraint(equalTo: passwordView.leadingAnchor, constant: 20),
            passwordTextField.trailingAnchor.constraint(equalTo: passwordView.trailingAnchor, constant: -20),
            passwordTextField.heightAnchor.constraint(equalToConstant: 50),
            
            loginButton.topAnchor.constraint(equalTo: passwordTextField.bottomAnchor, constant: 20),
            loginButton.leadingAnchor.constraint(equalTo: passwordView.leadingAnchor, constant: 20),
            loginButton.trailingAnchor.constraint(equalTo: passwordView.trailingAnchor, constant: -20),
            loginButton.heightAnchor.constraint(equalToConstant: 50)
        ])
        
        let tapGesture = UITapGestureRecognizer(target: self, action: #selector(dismissKeyboard))
        view.addGestureRecognizer(tapGesture)
    }
    
    private func setupBindings() {
        authService.$qrCodeUrl
            .receive(on: DispatchQueue.main)
            .sink { [weak self] url in
                guard let self = self else { return }
                if let url = url {
                    self.loadingIndicator.stopAnimating()
                    self.loadingIndicator.isHidden = true
                    self.qrImageView.isHidden = false
                    self.passwordView.isHidden = true
                    self.statusLabel.text = "Отсканируйте QR-код в Telegram"
                    
                    if let qrImage = self.generateQRCode(from: url) {
                        self.qrImageView.image = qrImage
                    }
                }
            }
            .store(in: &cancellables)
        
        authService.$needPassword
            .receive(on: DispatchQueue.main)
            .sink { [weak self] needPassword in
                guard let self = self else { return }
                if needPassword {
                    print("Требуется ввод пароля в AuthQRController")
                    self.loadingIndicator.stopAnimating()
                    self.loadingIndicator.isHidden = true
                    self.qrImageView.isHidden = true
                    self.passwordView.isHidden = false
                    
                    let hint = self.authService.passwordHint.isEmpty ? 
                        "Введите пароль от аккаунта" : 
                        "Введите пароль от аккаунта (подсказка: \(self.authService.passwordHint))"
                    self.statusLabel.text = hint
                    self.passwordTextField.placeholder = "Пароль"
                    
                    // Установить фокус на поле ввода пароля
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        self.passwordTextField.becomeFirstResponder()
                    }
                }
            }
            .store(in: &cancellables)
            
        authService.$isAuthorized
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isAuthorized in
                guard let self = self else { return }
                if isAuthorized {
                    print("AuthQRController: Авторизация успешна")
                    self.loadingIndicator.stopAnimating()
                    self.loadingIndicator.isHidden = true
                    self.qrImageView.isHidden = true
                    self.passwordView.isHidden = true
                    self.statusLabel.text = "Авторизация успешна"
                    
                    // Показываем индикатор загрузки на короткое время
                    self.loadingIndicator.isHidden = false
                    self.loadingIndicator.startAnimating()
                    
                    // Через 2 секунды скрываем индикатор
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        self.loadingIndicator.stopAnimating()
                        self.loadingIndicator.isHidden = true
                    }
                }
            }
            .store(in: &cancellables)
    }
    
    @objc private func loginButtonTapped() {
        guard let password = passwordTextField.text, !password.isEmpty else {
            statusLabel.text = "Пожалуйста, введите пароль"
            return
        }
        
        sendPassword(password)
    }
    
    private func sendPassword(_ password: String) {
        print("Отправка пароля")
        
        loginButton.isEnabled = false
        loginButton.setTitle("Входим...", for: .disabled)
        passwordTextField.isEnabled = false
        loadingIndicator.isHidden = false
        loadingIndicator.startAnimating()
        
        Task { @MainActor in
            let success = await authService.checkPassword(password)
            
            if !success {
                statusLabel.text = "Неверный пароль. Попробуйте снова."
                loginButton.isEnabled = true
                loginButton.setTitle("Войти", for: .normal)
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
        if passwordView.isHidden {
            return [qrImageView]
        } else {
            return [passwordTextField, loginButton]
        }
    }
    
    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        
        if let nextView = context.nextFocusedView {
            coordinator.addCoordinatedAnimations {
                if nextView === self.loginButton {
                    self.loginButton.transform = CGAffineTransform(scaleX: 1.1, y: 1.1)
                } else if nextView === self.passwordTextField {
                    self.passwordTextField.transform = CGAffineTransform(scaleX: 1.1, y: 1.1)
                }
            }
        }
        
        if let prevView = context.previouslyFocusedView {
            coordinator.addCoordinatedAnimations {
                if prevView === self.loginButton {
                    self.loginButton.transform = .identity
                } else if prevView === self.passwordTextField {
                    self.passwordTextField.transform = .identity
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