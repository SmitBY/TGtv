import UIKit

class TopMenuView: UIView {
    var onTabSelected: ((Int) -> Void)?
    
    private let container: UIView = {
        let view = UIView()
        view.backgroundColor = UIColor(red: 47/255, green: 47/255, blue: 47/255, alpha: 1)
        view.layer.cornerRadius = 37 // Половина высоты 74
        view.translatesAutoresizingMaskIntoConstraints = false
        return view
    }()
    
    private let stackView: UIStackView = {
        let stack = UIStackView()
        stack.axis = .horizontal
        stack.spacing = 0 
        stack.alignment = .fill
        // Важно для локализации: ширина табов должна зависеть от текста.
        stack.distribution = .fillProportionally
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }()
    
    private var buttons: [MenuButton] = []
    private let items: [String]
    private var selectedIndex: Int
    
    private var pendingSelectionTask: DispatchWorkItem?
    private var isLocked = false
    private var lastSwitchTime: TimeInterval = 0

    init(items: [String], selectedIndex: Int) {
        self.items = items
        self.selectedIndex = selectedIndex
        super.init(frame: .zero)
        setupUI()
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    private func setupUI() {
        clipsToBounds = false
        container.clipsToBounds = false
        addSubview(container)
        container.addSubview(stackView)
        
        NSLayoutConstraint.activate([
            container.centerYAnchor.constraint(equalTo: centerYAnchor),
            container.centerXAnchor.constraint(equalTo: centerXAnchor),
            container.heightAnchor.constraint(equalToConstant: 74),
            // tvOS safe-area: не даём меню «упереться» в края на широких/узких локализациях.
            container.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 80),
            container.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -80),
            
            stackView.topAnchor.constraint(equalTo: container.topAnchor),
            stackView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            stackView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 9),
            stackView.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -9)
        ])
        
        for (index, title) in items.enumerated() {
            let isSelected = index == selectedIndex
            let button = MenuButton(title: title, isSelected: isSelected)
            button.tag = index
            button.addTarget(self, action: #selector(buttonTapped(_:)), for: .primaryActionTriggered)
            // Даём авто-лейауту возможность «сжимать» кнопки при очень длинных строках.
            button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            button.setContentHuggingPriority(.defaultHigh, for: .horizontal)
            stackView.addArrangedSubview(button)
            buttons.append(button)
        }
        
        setupInternalFocusGuides()
    }
    
    private func setupInternalFocusGuides() {
        guard buttons.count > 0 else { return }
        
        // Горизонтальные ловушки (чтобы фокус не "проваливался" вниз при движении влево/вправо)
        let leftGuide = UIFocusGuide()
        addLayoutGuide(leftGuide)
        leftGuide.preferredFocusEnvironments = [buttons[0]]
        NSLayoutConstraint.activate([
            leftGuide.topAnchor.constraint(equalTo: topAnchor, constant: -500),
            leftGuide.bottomAnchor.constraint(equalTo: bottomAnchor, constant: 500),
            leftGuide.leadingAnchor.constraint(equalTo: leadingAnchor),
            leftGuide.trailingAnchor.constraint(equalTo: container.leadingAnchor)
        ])
        
        let rightGuide = UIFocusGuide()
        addLayoutGuide(rightGuide)
        rightGuide.preferredFocusEnvironments = [buttons[buttons.count-1]]
        NSLayoutConstraint.activate([
            rightGuide.topAnchor.constraint(equalTo: topAnchor, constant: -500),
            rightGuide.bottomAnchor.constraint(equalTo: bottomAnchor, constant: 500),
            rightGuide.leadingAnchor.constraint(equalTo: container.trailingAnchor),
            rightGuide.trailingAnchor.constraint(equalTo: trailingAnchor)
        ])
    }
    
    @objc private func buttonTapped(_ sender: MenuButton) {
        cancelPendingTransitions()
        if selectedIndex != sender.tag {
            updateSelection(to: sender.tag)
            self.onTabSelected?(sender.tag)
        }
    }
    
    func cancelPendingTransitions() {
        pendingSelectionTask?.cancel()
        pendingSelectionTask = nil
    }

    func buttonFocused(at index: Int, isInternalChange: Bool) {
        if isLocked { return }
        
        if !isInternalChange {
            pendingSelectionTask?.cancel()
            updateSelection(to: index)
            return
        }

        let now = CACurrentMediaTime()
        if now - lastSwitchTime < 0.5 { return }

        pendingSelectionTask?.cancel()
        
        if selectedIndex != index {
            updateSelection(to: index)
            
            let task = DispatchWorkItem { [weak self] in
                guard let self = self else { return }
                if self.isLocked { return }
                
                self.isLocked = true
                self.lastSwitchTime = CACurrentMediaTime()
                self.onTabSelected?(index)
                
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                    self?.isLocked = false
                }
            }
            pendingSelectionTask = task
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: task)
        }
    }
    
    func setCurrentIndex(_ index: Int) {
        cancelPendingTransitions()
        if index < buttons.count {
            updateSelection(to: index)
        }
        
        isLocked = true
        lastSwitchTime = CACurrentMediaTime()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.isLocked = false
        }
    }
    
    private func updateSelection(to index: Int) {
        selectedIndex = index
        for (idx, btn) in buttons.enumerated() {
            btn.updateSelectedState(idx == index)
        }
    }

    func currentFocusTarget() -> UIFocusEnvironment? {
        guard selectedIndex >= 0, selectedIndex < buttons.count else { return nil }
        return buttons[selectedIndex]
    }
    
    override var preferredFocusEnvironments: [UIFocusEnvironment] {
        if selectedIndex < buttons.count {
            return [buttons[selectedIndex]]
        }
        return super.preferredFocusEnvironments
    }
    
    override func shouldUpdateFocus(in context: UIFocusUpdateContext) -> Bool {
        let heading = context.focusHeading
        let nextView = context.nextFocusedView
        
        if let nv = nextView, !nv.isDescendant(of: self) {
            if heading.contains(.down) {
                return true
            } else {
                return false
            }
        }
        
        return true
    }
}

class MenuButton: UIButton {
    private var isTabSelected: Bool
    private let shadowLayer = CALayer()
    private let titleText: String
    
    init(title: String, isSelected: Bool) {
        self.isTabSelected = isSelected
        self.titleText = title
        super.init(frame: .zero)
        
        // Используем UIButton.Configuration для замены устаревшего contentEdgeInsets
        var config = UIButton.Configuration.plain()
        config.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 18, bottom: 0, trailing: 18)
        self.configuration = config
        
        setupStyle()
        translatesAutoresizingMaskIntoConstraints = false
        setupShadow()
    }
    
    func updateSelectedState(_ selected: Bool) {
        self.isTabSelected = selected
        setupStyle()
    }
    
    private func setupStyle() {
        guard var config = configuration else { return }
        
        var container = AttributeContainer()
        container.font = .systemFont(ofSize: 29, weight: .bold)
        
        if isTabSelected {
            container.foregroundColor = .black
            config.background.backgroundColor = UIColor(red: 208/255, green: 209/255, blue: 211/255, alpha: 1.0)
            config.background.cornerRadius = 35
        } else {
            container.foregroundColor = UIColor(red: 153/255, green: 153/255, blue: 153/255, alpha: 1.0)
            config.background.backgroundColor = .clear
            config.background.cornerRadius = 28
        }
        
        config.attributedTitle = AttributedString(titleText, attributes: container)
        self.configuration = config
        
        // Дополнительные настройки для titleLabel, которые не покрываются Configuration
        titleLabel?.numberOfLines = 1
        titleLabel?.adjustsFontSizeToFitWidth = true
        titleLabel?.minimumScaleFactor = 0.65
        titleLabel?.baselineAdjustment = .alignCenters
        
        layer.cornerRadius = config.background.cornerRadius
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    private func setupShadow() {
        shadowLayer.shadowColor = UIColor(red: 0, green: 0, blue: 0, alpha: 0.25).cgColor
        shadowLayer.shadowOpacity = isTabSelected ? 1 : 0
        shadowLayer.shadowRadius = 4
        shadowLayer.shadowOffset = CGSize(width: 0, height: 4)
        shadowLayer.cornerRadius = 28
        layer.insertSublayer(shadowLayer, at: 0)
    }
    
    override func layoutSubviews() {
        super.layoutSubviews()
        shadowLayer.frame = bounds
        shadowLayer.shadowPath = UIBezierPath(roundedRect: bounds, cornerRadius: layer.cornerRadius).cgPath
    }
    
    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        
        if self.isFocused {
            let prev = context.previouslyFocusedView
            let isInternalChange = (prev is MenuButton) && (prev?.superview === self.superview)
            
            var parent = superview
            while parent != nil {
                if let menu = parent as? TopMenuView {
                    menu.buttonFocused(at: tag, isInternalChange: isInternalChange)
                    break
                }
                parent = parent?.superview
            }
        }

        coordinator.addCoordinatedAnimations {
            if self.isFocused {
                self.transform = CGAffineTransform(scaleX: 1.1, y: 1.1)
                if var config = self.configuration {
                    config.background.backgroundColor = .white
                    var container = AttributeContainer()
                    container.font = .systemFont(ofSize: 29, weight: .bold)
                    container.foregroundColor = .black
                    config.attributedTitle = AttributedString(self.titleText, attributes: container)
                    self.configuration = config
                }
                self.shadowLayer.shadowOpacity = 0.5
            } else {
                self.transform = .identity
                // Возвращаем стиль в зависимости от того, выбран ли таб
                self.setupStyle()
                self.shadowLayer.shadowOpacity = self.isTabSelected ? 1 : 0
            }
        }
    }
}
