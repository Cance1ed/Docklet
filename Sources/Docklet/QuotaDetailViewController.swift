import AppKit

/// Popover listing every feed's quota, one block per provider.
final class QuotaDetailViewController: NSViewController {
    private let feeds: [QuotaFeed]
    private let onOpenMenu: () -> Void

    private let sectionsStack = NSStackView()
    private let refreshButton = NSButton()

    init(feeds: [QuotaFeed], onOpenMenu: @escaping () -> Void) {
        self.feeds = feeds
        self.onOpenMenu = onOpenMenu
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 240))

        refreshButton.isBordered = false
        refreshButton.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "刷新")
        refreshButton.target = self
        refreshButton.action = #selector(refresh)
        refreshButton.toolTip = "全部刷新"

        let moreButton = NSButton()
        moreButton.isBordered = false
        moreButton.image = NSImage(systemSymbolName: "ellipsis.circle", accessibilityDescription: "更多")
        moreButton.target = self
        moreButton.action = #selector(openMenu)
        moreButton.toolTip = "更多选项"

        let title = NSTextField(labelWithString: "AI 额度")
        title.font = .systemFont(ofSize: 13, weight: .semibold)

        let header = NSStackView(views: [title, NSView(), refreshButton, moreButton])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 6

        sectionsStack.orientation = .vertical
        sectionsStack.alignment = .leading
        sectionsStack.spacing = 16

        let stack = NSStackView(views: [header, sectionsStack])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            stack.topAnchor.constraint(equalTo: root.topAnchor),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            root.widthAnchor.constraint(equalToConstant: 320),
            header.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28),
            sectionsStack.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28)
        ])

        view = root
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        // Bars sweep in only as the popover opens; later refreshes update them in place.
        reload(animated: true)
    }

    func reload() { reload(animated: false) }

    private func reload(animated: Bool) {
        guard isViewLoaded else { return }
        sectionsStack.arrangedSubviews.forEach {
            sectionsStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        for feed in feeds {
            let view = SectionView(section: feed.detailSection, kind: feed.kind, animated: animated)
            sectionsStack.addArrangedSubview(view)
            view.widthAnchor.constraint(equalTo: sectionsStack.widthAnchor).isActive = true
        }
    }

    @objc private func refresh() {
        feeds.forEach { $0.refresh() }
    }

    @objc private func openMenu() {
        onOpenMenu()
    }
}

/// One provider's block: title, subtitle, rows, and a footer that states data freshness.
private final class SectionView: NSView {
    init(section: DetailSection, kind: FeedKind, animated: Bool) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        let title = NSTextField(labelWithString: section.title)
        title.font = .systemFont(ofSize: 12, weight: .semibold)

        let subtitle = NSTextField(labelWithString: section.subtitle)
        subtitle.font = .systemFont(ofSize: 10)
        subtitle.textColor = .secondaryLabelColor

        let titles = NSStackView(views: [title, subtitle])
        titles.orientation = .vertical
        titles.alignment = .leading
        titles.spacing = 1

        let heading = NSStackView(views: [ProviderBadge(kind: kind), titles])
        heading.orientation = .horizontal
        heading.alignment = .centerY
        heading.spacing = 8

        var children: [NSView] = [heading]

        if let warning = section.warning {
            let label = NSTextField(labelWithString: "⚠︎ " + warning)
            label.font = .systemFont(ofSize: 10)
            label.textColor = .systemOrange
            label.lineBreakMode = .byWordWrapping
            label.maximumNumberOfLines = 3
            children.append(label)
        }

        for row in section.rows {
            children.append(RowView(row: row, animated: animated))
        }

        let footer = NSTextField(labelWithString: section.footer)
        footer.font = .systemFont(ofSize: 9)
        footer.textColor = .tertiaryLabelColor

        let accessory = NSTextField(labelWithString: section.accessory ?? "")
        accessory.font = .systemFont(ofSize: 9)
        accessory.textColor = .tertiaryLabelColor
        accessory.alignment = .right

        let footerStack = NSStackView(views: [footer, NSView(), accessory])
        footerStack.orientation = .horizontal
        footerStack.spacing = 6
        children.append(footerStack)

        let stack = NSStackView(views: children)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        for child in children {
            child.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }
}

/// One quota line: label, value, optional progress bar and sub-detail.
private final class RowView: NSView {
    init(row: DetailRow, animated: Bool) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        let name = NSTextField(labelWithString: row.name)
        name.font = .systemFont(ofSize: 12, weight: .medium)

        let value = NSTextField(labelWithString: row.value)
        value.font = .monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        value.alignment = .right
        value.textColor = row.fraction == nil ? .secondaryLabelColor : row.tint

        let top = NSStackView(views: [name, NSView(), value])
        top.orientation = .horizontal
        top.spacing = 8

        var children: [NSView] = [top]

        if let fraction = row.fraction {
            let bar = BarView()
            bar.tint = row.tint
            bar.animatesIn = animated
            bar.fraction = fraction
            bar.heightAnchor.constraint(equalToConstant: 6).isActive = true
            children.append(bar)
        }

        if let detail = row.detail {
            let label = NSTextField(labelWithString: detail)
            label.font = .systemFont(ofSize: 10)
            label.textColor = .secondaryLabelColor
            children.append(label)
        }

        let stack = NSStackView(views: children)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        for child in children {
            child.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }
}

/// A small rounded badge with the provider's symbol, so each block is recognisable at a glance.
private final class ProviderBadge: NSView {
    init(kind: FeedKind) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true

        let (symbol, top, bottom): (String, NSColor, NSColor) = {
            switch kind {
            case .copilot:
                return ("chevron.left.forwardslash.chevron.right", .systemIndigo, .systemPurple)
            case .codex:
                return ("terminal.fill", .systemTeal, .systemBlue)
            case .claude:
                return ("sparkle", .systemOrange, .systemRed)
            }
        }()

        let gradient = CAGradientLayer()
        gradient.colors = [top.cgColor, bottom.cgColor]
        gradient.startPoint = CGPoint(x: 0, y: 1)
        gradient.endPoint = CGPoint(x: 1, y: 0)
        gradient.cornerRadius = 6
        gradient.cornerCurve = .continuous
        layer = gradient

        let image = NSImageView()
        image.image = NSImage(systemSymbolName: symbol, accessibilityDescription: kind.displayName)?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .semibold))
        image.contentTintColor = .white
        image.translatesAutoresizingMaskIntoConstraints = false
        addSubview(image)

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 24),
            heightAnchor.constraint(equalToConstant: 24),
            image.centerXAnchor.constraint(equalTo: centerXAnchor),
            image.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }
}

/// Track plus a gradient fill, built from layers so the fill can sweep in when the popover opens.
final class BarView: NSView {
    var fraction: Double = 0 { didSet { needsLayout = true } }
    var tint: NSColor = .controlAccentColor { didSet { needsLayout = true } }
    /// Animate the fill from empty the first time the bar is laid out.
    var animatesIn = false

    private let track = CALayer()
    private let fill = CAGradientLayer()
    private var hasAppeared = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.addSublayer(track)
        layer?.addSublayer(fill)
        fill.startPoint = CGPoint(x: 0, y: 0.5)
        fill.endPoint = CGPoint(x: 1, y: 0.5)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    override func layout() {
        super.layout()
        guard bounds.width > 0 else { return }

        // Resolved here, inside the view's appearance, so dynamic colours pick the right variant.
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let base = tint.usingColorSpace(.sRGB) ?? tint
            track.backgroundColor = NSColor.labelColor.withAlphaComponent(0.1).cgColor
            fill.colors = [(base.blended(withFraction: 0.35, of: .white) ?? base).cgColor, base.cgColor]
        }

        let radius = bounds.height / 2
        let width = max(bounds.height, bounds.width * CGFloat(max(0, min(1, fraction))))
        let target = CGRect(x: 0, y: 0, width: width, height: bounds.height)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        track.frame = bounds
        track.cornerRadius = radius
        fill.cornerRadius = radius
        fill.frame = target
        CATransaction.commit()

        guard animatesIn, !hasAppeared,
              !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            hasAppeared = true
            return
        }
        hasAppeared = true
        let grow = CASpringAnimation(keyPath: "bounds.size.width")
        grow.fromValue = bounds.height
        grow.toValue = width
        grow.damping = 18
        grow.stiffness = 160
        grow.duration = grow.settlingDuration
        let slide = CASpringAnimation(keyPath: "position.x")
        slide.fromValue = bounds.height / 2
        slide.toValue = width / 2
        slide.damping = grow.damping
        slide.stiffness = grow.stiffness
        slide.duration = grow.duration
        fill.add(grow, forKey: "grow")
        fill.add(slide, forKey: "slide")
    }
}
