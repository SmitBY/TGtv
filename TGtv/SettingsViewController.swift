import UIKit

final class SettingsViewController: UIViewController {
    private var topMenuControl: UISegmentedControl?
    private let logoutButton = UIButton(type: .system)
    private let logoutNormalBackground = UIColor.systemRed.withAlphaComponent(0.85)
    private let logoutFocusedBackground = UIColor.white
    
    override func viewDidLoad() {
        super.viewDidLoad()
        setupBackground()
        setupTopMenuBar()
        setupContent()
    }
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setNavigationBarHidden(true, animated: false)
        topMenuControl?.selectedSegmentIndex = 2
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        navigationController?.setNavigationBarHidden(false, animated: false)
    }
    
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        if let gradient = view.layer.sublayers?.first as? CAGradientLayer {
            gradient.frame = view.bounds
        }
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
        let control = UISegmentedControl(items: ["Главная", "Список", "Настройки"])
        control.translatesAutoresizingMaskIntoConstraints = false
        control.selectedSegmentIndex = 2
        control.backgroundColor = UIColor(white: 0, alpha: 0.55)
        control.selectedSegmentTintColor = UIColor.white
        control.addTarget(self, action: #selector(topMenuChanged(_:)), for: .valueChanged)
        control.setTitleTextAttributes([
            .foregroundColor: UIColor.black,
            .font: UIFont.systemFont(ofSize: 30, weight: .regular)
        ], for: .normal)
        control.setTitleTextAttributes([
            .foregroundColor: UIColor.black,
            .font: UIFont.systemFont(ofSize: 32, weight: .semibold)
        ], for: .selected)
        view.addSubview(control)
        NSLayoutConstraint.activate([
            control.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 10),
            control.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 80),
            control.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -80),
            control.heightAnchor.constraint(equalToConstant: 80)
        ])
        topMenuControl = control
    }
    
    private func setupContent() {
        logoutButton.translatesAutoresizingMaskIntoConstraints = false
        logoutButton.setTitle("Выйти из аккаунта", for: .normal)
        logoutButton.titleLabel?.font = .systemFont(ofSize: 28, weight: .semibold)
        logoutButton.setTitleColor(.white, for: .normal)
        logoutButton.setTitleColor(.black, for: .focused)
        logoutButton.backgroundColor = logoutNormalBackground
        logoutButton.layer.cornerRadius = 14
        logoutButton.clipsToBounds = true
        logoutButton.addTarget(self, action: #selector(logoutTapped), for: .primaryActionTriggered)
        view.addSubview(logoutButton)
        
        NSLayoutConstraint.activate([
            logoutButton.topAnchor.constraint(equalTo: topMenuControl?.bottomAnchor ?? view.safeAreaLayoutGuide.topAnchor, constant: 40),
            logoutButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            logoutButton.widthAnchor.constraint(equalToConstant: 360),
            logoutButton.heightAnchor.constraint(equalToConstant: 70)
        ])
    }
    
    @objc private func topMenuChanged(_ sender: UISegmentedControl) {
        switch sender.selectedSegmentIndex {
        case 0:
            navigationController?.popToRootViewController(animated: true)
        case 1:
            (UIApplication.shared.delegate as? AppDelegate)?.openChatSelectionFromMenu()
        default:
            break
        }
        sender.selectedSegmentIndex = 2
    }
    
    @objc private func logoutTapped() {
        (UIApplication.shared.delegate as? AppDelegate)?.logoutFromMenu()
    }

    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        let isFocused = (context.nextFocusedView === logoutButton)
        coordinator.addCoordinatedAnimations { [weak self] in
            guard let self else { return }
            self.logoutButton.backgroundColor = isFocused ? self.logoutFocusedBackground : self.logoutNormalBackground
        }
    }
}

