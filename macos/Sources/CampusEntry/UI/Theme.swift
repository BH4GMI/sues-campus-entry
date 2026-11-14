import AppKit

/// Design tokens and reusable desktop AppKit controls for 教务直达, aligned with `DESIGN.md` and `App.xaml`.
enum Theme {
    enum Colors {
        // Brand & primary driver color (adaptive light/dark)
        static let primary = NSColor.adaptive(light: 0x2F6FB5, dark: 0x5B9BD5)
        static let primaryDeep = NSColor.adaptive(light: 0x24548A, dark: 0x437CB3)

        // Neutrals & typography
        static let ink = NSColor.adaptive(light: 0x1A1C1E, dark: 0xEAEDF0)
        static let secondary = NSColor.adaptive(light: 0x6C7278, dark: 0x9BA1A8)
        static let neutral = NSColor.adaptive(light: 0xF5F7FA, dark: 0x1F2226)
        static let surface = NSColor.adaptive(light: 0xFFFFFF, dark: 0x16181B)
        static let line = NSColor.adaptive(light: 0xE3E3E3, dark: 0x2E3238)

        // Semantic status colors
        static let success = NSColor.adaptive(light: 0x2E7D5B, dark: 0x4BA87D)
        static let warning = NSColor.adaptive(light: 0x8F5500, dark: 0xE59A33)
        static let error = NSColor.adaptive(light: 0xB3261E, dark: 0xEA6B64)

        // Desktop state layers & ghost button surfaces
        static let windowBorder = NSColor.adaptive(light: 0xD5DAE0, dark: 0x343940)
        static let hover = NSColor.adaptive(light: 0xEDF1F6, dark: 0x272B31)
        static let pressed = NSColor.adaptive(light: 0xE2E9F1, dark: 0x31373F)

        static let buttonGhostHover = NSColor.adaptive(light: 0xE7EDF5, dark: 0x2A3038)
        static let buttonGhostPressed = NSColor.adaptive(light: 0xDBE5F0, dark: 0x343B45)

        static let dangerGhost = NSColor.adaptive(light: 0xFDF2F1, dark: 0x362020)
        static let dangerGhostHover = NSColor.adaptive(light: 0xFBE7E5, dark: 0x442626)
        static let dangerGhostPressed = NSColor.adaptive(light: 0xF8DBD8, dark: 0x522C2C)

        /// Fixed brand blue used on the circular app mark where white stroke contrast (5.2:1) is required.
        static let iconPlate = NSColor(hex: 0x2F6FB5)
    }

    enum Typography {
        static let caption = NSFont.systemFont(ofSize: 12, weight: .regular)
        static let body = NSFont.systemFont(ofSize: 13, weight: .regular)
        static let label = NSFont.systemFont(ofSize: 13, weight: .regular)
        static let sectionTitle = NSFont.systemFont(ofSize: 13, weight: .semibold)
        static let title = NSFont.systemFont(ofSize: 15, weight: .semibold)
        static let appName = NSFont.systemFont(ofSize: 13, weight: .semibold)
    }

    enum Layout {
        static let toolbarHeight: CGFloat = 44
        static let iconButtonSize: CGFloat = 36
        static let iconButtonCornerRadius: CGFloat = 6
        static let settingsButtonHeight: CGFloat = 32
        static let dialogButtonHeight: CGFloat = 36
        static let dialogButtonCornerRadius: CGFloat = 8
        static let checkboxSize: CGFloat = 20
        static let checkboxCornerRadius: CGFloat = 4
        static let bannerHorizontalPadding: CGFloat = 14
        static let bannerVerticalPadding: CGFloat = 9
        static let noticeMaxWidth: CGFloat = 380
    }
}

extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1.0) {
        let r = CGFloat((hex >> 16) & 0xFF) / 255.0
        let g = CGFloat((hex >> 8) & 0xFF) / 255.0
        let b = CGFloat(hex & 0xFF) / 255.0
        self.init(srgbRed: r, green: g, blue: b, alpha: alpha)
    }

    static func adaptive(light: UInt32, dark: UInt32) -> NSColor {
        let lightColor = NSColor(hex: light)
        let darkColor = NSColor(hex: dark)
        return NSColor(name: nil) { appearance in
            let match = appearance.bestMatch(from: [.darkAqua, .aqua])
            return match == .darkAqua ? darkColor : lightColor
        }
    }

    func resolvedCGColor(for appearance: NSAppearance) -> CGColor {
        var resolved: CGColor = cgColor
        appearance.performAsCurrentDrawingAppearance {
            resolved = self.cgColor
        }
        return resolved
    }
}

/// Background container that re-resolves adaptive CGColors when appearance changes.
final class SurfaceView: NSView {
    var fillColor: NSColor {
        didSet { needsDisplay = true }
    }

    init(fillColor: NSColor) {
        self.fillColor = fillColor
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = fillColor.resolvedCGColor(for: effectiveAppearance)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

/// 1px horizontal or vertical hairline divider.
final class DividerView: NSView {
    enum Axis {
        case horizontal
        case vertical
    }

    private let color: NSColor

    init(axis: Axis, thickness: CGFloat = 1, length: CGFloat? = nil, color: NSColor = Theme.Colors.line) {
        self.color = color
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true

        switch axis {
        case .horizontal:
            heightAnchor.constraint(equalToConstant: thickness).isActive = true
            if let length {
                widthAnchor.constraint(equalToConstant: length).isActive = true
            }
        case .vertical:
            widthAnchor.constraint(equalToConstant: thickness).isActive = true
            if let length {
                heightAnchor.constraint(equalToConstant: length).isActive = true
            }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = color.resolvedCGColor(for: effectiveAppearance)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

/// Base interactive view with hover/pressed tracking, disabled opacity, and cursor management.
class HoverInteractiveControl: NSControl {
    fileprivate var isHovered = false {
        didSet {
            if oldValue != isHovered {
                refreshAppearanceState()
            }
        }
    }

    fileprivate var isPressed = false {
        didSet {
            if oldValue != isPressed {
                refreshAppearanceState()
            }
        }
    }

    override var isEnabled: Bool {
        didSet {
            if !isEnabled {
                isHovered = false
                isPressed = false
            }
            refreshAppearanceState()
        }
    }

    private var trackingArea: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        guard isEnabled else { return }
        isHovered = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        isPressed = true
    }

    override func mouseUp(with event: NSEvent) {
        let wasPressed = isPressed
        isPressed = false
        guard isEnabled, wasPressed else { return }
        let loc = convert(event.locationInWindow, from: nil)
        if bounds.contains(loc) {
            sendAction(action, to: target)
        }
    }

    override func resetCursorRects() {
        if isEnabled {
            addCursorRect(bounds, cursor: .pointingHand)
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshAppearanceState()
    }

    func refreshAppearanceState() {
        needsDisplay = true
        alphaValue = isEnabled ? 1.0 : 0.45
        window?.invalidateCursorRects(for: self)
    }
}

/// 36x36 (or custom size) SF Symbol icon button with rounded hover/pressed background.
final class ToolbarIconButton: HoverInteractiveControl {
    private let imageView = NSImageView()
    private let cornerRadius: CGFloat

    init(
        symbolName: String,
        pointSize: CGFloat = 15,
        size: CGFloat = Theme.Layout.iconButtonSize,
        cornerRadius: CGFloat = Theme.Layout.iconButtonCornerRadius,
        accessibilityLabel: String,
        toolTip: String? = nil
    ) {
        self.cornerRadius = cornerRadius
        super.init(frame: .zero)

        let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .regular)
        let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: accessibilityLabel)?
            .withSymbolConfiguration(config)
        imageView.image = image
        imageView.imageScaling = .scaleNone
        imageView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(imageView)

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: size),
            heightAnchor.constraint(equalToConstant: size),
            imageView.centerXAnchor.constraint(equalTo: centerXAnchor),
            imageView.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])

        setAccessibilityRole(.button)
        setAccessibilityLabel(accessibilityLabel)
        self.toolTip = toolTip
        refreshAppearanceState()
    }

    override func updateLayer() {
        layer?.cornerRadius = cornerRadius
        let bg: NSColor
        if !isEnabled {
            bg = .clear
        } else if isPressed {
            bg = Theme.Colors.pressed
        } else if isHovered {
            bg = Theme.Colors.hover
        } else {
            bg = .clear
        }
        layer?.backgroundColor = bg.resolvedCGColor(for: effectiveAppearance)
        imageView.contentTintColor = isEnabled ? Theme.Colors.ink : Theme.Colors.secondary
    }
}

/// Mutually-exclusive toolbar entry tab (44pt height, regular weight so width never shifts, 2px bottom bar when active).
final class ToolbarTabButton: HoverInteractiveControl {
    var isSelectedTab: Bool = false {
        didSet {
            setAccessibilityValue(isSelectedTab ? 1 : 0)
            refreshAppearanceState()
        }
    }

    private let titleLabel = NSTextField(labelWithString: "")
    private let indicator = NSView()

    init(title: String, accessibilityLabel: String, toolTip: String? = nil) {
        super.init(frame: .zero)

        titleLabel.stringValue = title
        titleLabel.font = Theme.Typography.body
        titleLabel.alignment = .center
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)

        indicator.wantsLayer = true
        indicator.translatesAutoresizingMaskIntoConstraints = false
        addSubview(indicator)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Theme.Layout.toolbarHeight),
            widthAnchor.constraint(greaterThanOrEqualToConstant: 76),

            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            indicator.leadingAnchor.constraint(equalTo: leadingAnchor),
            indicator.trailingAnchor.constraint(equalTo: trailingAnchor),
            indicator.bottomAnchor.constraint(equalTo: bottomAnchor),
            indicator.heightAnchor.constraint(equalToConstant: 2),
        ])

        setAccessibilityRole(.radioButton)
        setAccessibilityLabel(accessibilityLabel)
        setAccessibilityValue(0)
        self.toolTip = toolTip
        refreshAppearanceState()
    }

    override func updateLayer() {
        layer?.backgroundColor = NSColor.clear.cgColor
        if isSelectedTab {
            titleLabel.textColor = Theme.Colors.primary
            indicator.isHidden = false
            indicator.layer?.backgroundColor = Theme.Colors.primary.resolvedCGColor(for: effectiveAppearance)
        } else {
            titleLabel.textColor = (isHovered && isEnabled) ? Theme.Colors.ink : Theme.Colors.secondary
            indicator.isHidden = true
        }
    }
}

/// Toolbar button with optional leading SF Symbol and text label (used for Settings and NoticeAction).
final class ToolbarTextButton: HoverInteractiveControl {
    private let stack = NSStackView()
    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")

    var titleText: String {
        get { titleLabel.stringValue }
        set { titleLabel.stringValue = newValue }
    }

    init(title: String, symbolName: String? = nil, accessibilityLabel: String? = nil) {
        super.init(frame: .zero)

        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        if let symbolName {
            let config = NSImage.SymbolConfiguration(pointSize: 13.5, weight: .regular)
            iconView.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
                .withSymbolConfiguration(config)
            iconView.imageScaling = .scaleNone
            stack.addArrangedSubview(iconView)
        }

        titleLabel.stringValue = title
        titleLabel.font = Theme.Typography.body
        titleLabel.lineBreakMode = .byTruncatingTail
        stack.addArrangedSubview(titleLabel)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Theme.Layout.settingsButtonHeight),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])

        setAccessibilityRole(.button)
        setAccessibilityLabel(accessibilityLabel ?? title)
        refreshAppearanceState()
    }

    override func updateLayer() {
        layer?.cornerRadius = Theme.Layout.iconButtonCornerRadius
        let bg: NSColor
        if !isEnabled {
            bg = .clear
        } else if isPressed {
            bg = Theme.Colors.pressed
        } else if isHovered {
            bg = Theme.Colors.hover
        } else {
            bg = .clear
        }
        layer?.backgroundColor = bg.resolvedCGColor(for: effectiveAppearance)
        let fg = isEnabled ? Theme.Colors.ink : Theme.Colors.secondary
        titleLabel.textColor = fg
        iconView.contentTintColor = fg
    }
}

/// Dialog button matching `ButtonGhost` and `ButtonDanger` in `App.xaml`.
final class DialogActionButton: HoverInteractiveControl {
    enum Style {
        case ghost
        case danger
    }

    private let style: Style
    private let titleLabel = NSTextField(labelWithString: "")
    private var keyEquiv: String = ""

    init(title: String, style: Style = .ghost, minWidth: CGFloat = 150, accessibilityLabel: String? = nil) {
        self.style = style
        super.init(frame: .zero)

        titleLabel.stringValue = title
        titleLabel.font = Theme.Typography.label
        titleLabel.alignment = .center
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Theme.Layout.dialogButtonHeight),
            widthAnchor.constraint(greaterThanOrEqualToConstant: minWidth),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])

        setAccessibilityRole(.button)
        setAccessibilityLabel(accessibilityLabel ?? title)
        refreshAppearanceState()
    }

    func setKeyEquivalent(_ key: String) {
        keyEquiv = key
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard isEnabled, !keyEquiv.isEmpty else { return false }
        if event.charactersIgnoringModifiers == keyEquiv {
            sendAction(action, to: target)
            return true
        }
        return false
    }

    override func updateLayer() {
        layer?.cornerRadius = Theme.Layout.dialogButtonCornerRadius
        let bg: NSColor
        let fg: NSColor
        switch style {
        case .ghost:
            fg = Theme.Colors.primary
            if !isEnabled {
                bg = Theme.Colors.neutral
            } else if isPressed {
                bg = Theme.Colors.buttonGhostPressed
            } else if isHovered {
                bg = Theme.Colors.buttonGhostHover
            } else {
                bg = Theme.Colors.neutral
            }
        case .danger:
            fg = Theme.Colors.error
            if !isEnabled {
                bg = Theme.Colors.dangerGhost
            } else if isPressed {
                bg = Theme.Colors.dangerGhostPressed
            } else if isHovered {
                bg = Theme.Colors.dangerGhostHover
            } else {
                bg = Theme.Colors.dangerGhost
            }
        }
        layer?.backgroundColor = bg.resolvedCGColor(for: effectiveAppearance)
        titleLabel.textColor = fg
    }
}

/// Custom 20x20 rounded checkbox with primary fill and checkmark, paired with title + caption description.
final class StyledCheckbox: HoverInteractiveControl {
    var isChecked: Bool = false {
        didSet {
            setAccessibilityValue(isChecked ? 1 : 0)
            refreshAppearanceState()
        }
    }

    private let box = NSView()
    private let checkImage = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(wrappingLabelWithString: "")

    init(title: String, subtitle: String) {
        super.init(frame: .zero)

        box.wantsLayer = true
        box.translatesAutoresizingMaskIntoConstraints = false
        addSubview(box)

        let config = NSImage.SymbolConfiguration(pointSize: 11, weight: .bold)
        checkImage.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil)?
            .withSymbolConfiguration(config)
        checkImage.contentTintColor = .white
        checkImage.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(checkImage)

        titleLabel.stringValue = title
        titleLabel.font = Theme.Typography.body
        titleLabel.textColor = Theme.Colors.ink
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)

        subtitleLabel.stringValue = subtitle
        subtitleLabel.font = Theme.Typography.caption
        subtitleLabel.textColor = Theme.Colors.secondary
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(subtitleLabel)

        NSLayoutConstraint.activate([
            box.leadingAnchor.constraint(equalTo: leadingAnchor),
            box.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            box.widthAnchor.constraint(equalToConstant: Theme.Layout.checkboxSize),
            box.heightAnchor.constraint(equalToConstant: Theme.Layout.checkboxSize),

            checkImage.centerXAnchor.constraint(equalTo: box.centerXAnchor),
            checkImage.centerYAnchor.constraint(equalTo: box.centerYAnchor),

            titleLabel.leadingAnchor.constraint(equalTo: box.trailingAnchor, constant: 12),
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor),
            titleLabel.topAnchor.constraint(equalTo: topAnchor),

            subtitleLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            subtitleLabel.trailingAnchor.constraint(equalTo: trailingAnchor),
            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 3),
            subtitleLabel.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        setAccessibilityRole(.checkBox)
        setAccessibilityLabel(title)
        setAccessibilityValue(0)
        refreshAppearanceState()
    }

    override func mouseUp(with event: NSEvent) {
        let wasPressed = isPressed
        isPressed = false
        guard isEnabled, wasPressed else { return }
        let loc = convert(event.locationInWindow, from: nil)
        if bounds.contains(loc) {
            isChecked.toggle()
            sendAction(action, to: target)
        }
    }

    override func updateLayer() {
        box.layer?.cornerRadius = Theme.Layout.checkboxCornerRadius
        box.layer?.borderWidth = 1.5
        if isChecked {
            box.layer?.backgroundColor = Theme.Colors.primary.resolvedCGColor(for: effectiveAppearance)
            box.layer?.borderColor = Theme.Colors.primary.resolvedCGColor(for: effectiveAppearance)
            checkImage.isHidden = false
        } else {
            box.layer?.backgroundColor = Theme.Colors.surface.resolvedCGColor(for: effectiveAppearance)
            let borderColor = (isHovered && isEnabled) ? Theme.Colors.primary : Theme.Colors.line
            box.layer?.borderColor = borderColor.resolvedCGColor(for: effectiveAppearance)
            checkImage.isHidden = true
        }
        titleLabel.textColor = Theme.Colors.ink
        subtitleLabel.textColor = Theme.Colors.secondary
    }
}
