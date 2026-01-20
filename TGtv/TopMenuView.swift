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
    private var pendingSelectionIndex: Int?
    private let selectionDebounce: TimeInterval = 0.3
    
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
        pendingSelectionIndex = nil
    }

    func buttonFocused(at index: Int, isInternalChange: Bool) {
        cancelPendingTransitions()

        let previousIndex = selectedIndex
        updateSelection(to: index) // визуально переносим выделение сразу

        // Если фокус пришел извне меню — не автопереключаем вкладку, только подсветка
        guard isInternalChange else { return }

        // Если вкладка не изменилась — ничего не планируем
        guard previousIndex != index else { return }

        // Дебаунс: даем пользователю проскочить несколько вкладок,
        // и переключаем экран только по последней выбранной.
        pendingSelectionIndex = index
        let task = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard self.pendingSelectionIndex == index else { return }
            self.pendingSelectionIndex = nil
            self.pendingSelectionTask = nil
            self.onTabSelected?(index)
        }
        pendingSelectionTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + selectionDebounce, execute: task)
    }
    
    func setCurrentIndex(_ index: Int) {
        cancelPendingTransitions()
        if index < buttons.count {
            updateSelection(to: index)
        }
    }
    
    private func updateSelection(to index: Int) {
        selectedIndex = index
        UIView.performWithoutAnimation {
            for (idx, btn) in buttons.enumerated() {
                btn.updateSelectedState(idx == index)
            }
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
        UIView.performWithoutAnimation {
            self.setupStyle()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            self.shadowLayer.shadowOpacity = selected ? 1 : 0
            CATransaction.commit()
        }
    }
    
    private func setupStyle() {
        guard var config = configuration else { return }
        
        var container = AttributeContainer()
        container.font = .systemFont(ofSize: 29, weight: .bold)
        
        if isTabSelected {
            container.foregroundColor = .black
            config.baseForegroundColor = .black
            config.background.backgroundColor = UIColor(red: 208/255, green: 209/255, blue: 211/255, alpha: 1.0)
            config.background.cornerRadius = 37
        } else {
            // Цвет текста #999999 для невыбранных кнопок
            container.foregroundColor = UIColor(red: 153/255, green: 153/255, blue: 153/255, alpha: 1.0)
            config.baseForegroundColor = UIColor(red: 153/255, green: 153/255, blue: 153/255, alpha: 1.0)
            config.background.backgroundColor = .clear
            config.background.cornerRadius = 37
        }
        
        config.attributedTitle = AttributedString(titleText, attributes: container)
        UIView.performWithoutAnimation {
            self.configuration = config
        }
        
        // Устанавливаем цвет текста в зависимости от состояния
        if isTabSelected {
            self.setTitleColor(.black, for: .normal)
        } else {
            self.setTitleColor(UIColor(red: 153/255, green: 153/255, blue: 153/255, alpha: 1.0), for: .normal)
        }
        // При фокусе всегда черный
        self.setTitleColor(.black, for: .focused)
        self.setTitleColor(.black, for: .highlighted)
        
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
        shadowLayer.cornerRadius = 37
        layer.insertSublayer(shadowLayer, at: 0)
    }
    
    override func layoutSubviews() {
        super.layoutSubviews()
        shadowLayer.frame = bounds
        shadowLayer.shadowPath = UIBezierPath(roundedRect: bounds, cornerRadius: layer.cornerRadius).cgPath
    }
    
    override func titleColor(for state: UIControl.State) -> UIColor? {
        // При фокусе всегда черный цвет
        if state.contains(.focused) {
            return .black
        }
        // Для невыбранных кнопок серый цвет #999999, для выбранных - черный
        if isTabSelected {
            return .black
        } else {
            return UIColor(red: 153/255, green: 153/255, blue: 153/255, alpha: 1.0)
        }
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
            
            // Убираем анимацию координатора, делаем всё мгновенно
            UIView.performWithoutAnimation {
                self.transform = CGAffineTransform(scaleX: 1.1, y: 1.1)
                if var config = self.configuration {
                    // Цвет фона #2F2F2F (47, 47, 47)
                    config.background.backgroundColor = UIColor(red: 47/255, green: 47/255, blue: 47/255, alpha: 1.0)
                    config.baseForegroundColor = .black
                    
                    var container = AttributeContainer()
                    container.font = .systemFont(ofSize: 29, weight: .bold)
                    container.foregroundColor = .black
                    config.attributedTitle = AttributedString(self.titleText, attributes: container)
                    self.configuration = config
                }
                self.titleLabel?.textColor = .black
                self.shadowLayer.shadowOpacity = 0.5
            }
        } else {
            // Когда фокус уходит, сбрасываем состояние мгновенно
            UIView.performWithoutAnimation {
                self.transform = .identity
                self.setupStyle()
                self.shadowLayer.shadowOpacity = self.isTabSelected ? 1 : 0
                self.titleLabel?.textColor = self.isTabSelected ? .black : UIColor(red: 153/255, green: 153/255, blue: 153/255, alpha: 1.0)
            }
        }
    }
}
