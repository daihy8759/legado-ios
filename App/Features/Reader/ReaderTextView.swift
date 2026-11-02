import SwiftUI
import UIKit

@available(iOS 16.0, *)
@MainActor
final class ReaderSelectionMenu: NSObject, @preconcurrency UIEditMenuInteractionDelegate {
    private var interaction: UIEditMenuInteraction?
    private let selectedText: String
    private let onSelect: (Bool) -> Void

    init(selectedText: String, onSelect: @escaping (Bool) -> Void) {
        self.selectedText = selectedText
        self.onSelect = onSelect
    }

    func present(on view: UIView, at point: CGPoint) {
        let interaction = UIEditMenuInteraction(delegate: self)
        self.interaction = interaction
        view.addInteraction(interaction)
        interaction.presentEditMenu(with: UIEditMenuConfiguration(identifier: nil, sourcePoint: point))
    }

    func dismiss() {
        interaction?.dismissMenu()
        if let interaction { interaction.view?.removeInteraction(interaction) }
    }

    func editMenuInteraction(_ interaction: UIEditMenuInteraction, menuFor configuration: UIEditMenuConfiguration,
                             suggestedActions: [UIMenuElement]) -> UIMenu? {
        UIMenu(children: [
            UIAction(title: "高亮", image: UIImage(systemName: "highlighter")) { [weak self] _ in self?.onSelect(false) },
            UIAction(title: "写想法", image: UIImage(systemName: "square.and.pencil")) { [weak self] _ in self?.onSelect(true) },
            UIAction(title: "复制", image: UIImage(systemName: "doc.on.doc")) { [weak self] _ in UIPasteboard.general.string = self?.selectedText }
        ] + suggestedActions)
    }
}

final class ReaderHighlightLayoutManager: NSLayoutManager {
    var highlights: [(range: NSRange, color: UIColor)] = []

    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: CGPoint) {
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
        for highlight in highlights {
            let glyphs = glyphRange(forCharacterRange: highlight.range, actualCharacterRange: nil)
            let visible = NSIntersectionRange(glyphs, glyphsToShow)
            guard visible.length > 0, let container = textContainers.first else { continue }
            highlight.color.setFill()
            enumerateEnclosingRects(forGlyphRange: visible, withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0), in: container) { rect, _ in
                UIRectFill(rect.offsetBy(dx: origin.x, dy: origin.y))
            }
        }
    }
}

private final class ReaderLayoutTextView: UITextView {
    var selectionAction: ((UITextView, Bool) -> Void)?
    @objc func highlightSelection() { selectionAction?(self, false) }
    @objc func annotateSelection() { selectionAction?(self, true) }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(highlightSelection) || action == #selector(annotateSelection) {
            return selectedRange.length > 0
        }
        return super.canPerformAction(action, withSender: sender)
    }
    var onLayout: ((UITextView) -> Void)?
    var clipsPagedText = false
    private var reportedSize = CGSize.zero
    private var reportedContentSize = CGSize.zero
    private let pageMask = CAShapeLayer()

    override func layoutSubviews() {
        super.layoutSubviews()
        if clipsPagedText, bounds.width > 0, bounds.height > 0 {
            var top = textContainerInset.top
            if layoutManager.numberOfGlyphs > 0 {
                let glyph = layoutManager.glyphIndex(for: CGPoint(x: 0, y: bounds.minY), in: textContainer)
                let line = layoutManager.lineFragmentUsedRect(forGlyphAt: glyph, effectiveRange: nil)
                let lineTop = line.minY + textContainerInset.top - bounds.minY
                let lineBottom = line.maxY + textContainerInset.top - bounds.minY
                if lineTop < top - 0.5, lineBottom > top { top = lineBottom }
            }
            pageMask.frame = bounds
            pageMask.path = UIBezierPath(rect: CGRect(
                x: 0, y: top, width: bounds.width,
                height: max(0, bounds.height - top - textContainerInset.bottom)
            )).cgPath
            layer.mask = pageMask
        } else {
            layer.mask = nil
        }
        guard bounds.width > 0, bounds.height > 0,
              bounds.size != reportedSize || contentSize != reportedContentSize else { return }
        reportedSize = bounds.size
        reportedContentSize = contentSize
        onLayout?(self)
    }
}

struct ReaderHighlight: Equatable {
    let quote: String
    let color: Int
    var startOffset: Int? = nil

    static let palette: [UIColor] = [
        UIColor(red: 1.00, green: 0.86, blue: 0.30, alpha: 0.45),
        UIColor(red: 0.55, green: 0.90, blue: 0.55, alpha: 0.40),
        UIColor(red: 0.50, green: 0.76, blue: 1.00, alpha: 0.40),
        UIColor(red: 1.00, green: 0.62, blue: 0.78, alpha: 0.38),
        UIColor(red: 0.76, green: 0.65, blue: 1.00, alpha: 0.38)
    ]

    static func uiColor(_ index: Int) -> UIColor {
        palette[min(max(index, 0), palette.count - 1)]
    }
}

@MainActor
enum ReaderPageLayout {
    static func pagedBottomInset(configured: CGFloat, fontSize: CGFloat, lineSpacing: CGFloat) -> CGFloat {
        max(configured, fontSize * 1.3 + max(lineSpacing, 0))
    }

    static func offsets(in view: UITextView) -> [CGFloat] {
        let minimum = -view.adjustedContentInset.top
        let maximum = max(view.contentSize.height - view.bounds.height + view.adjustedContentInset.bottom, minimum)
        let height = max(view.bounds.height - view.adjustedContentInset.top - view.adjustedContentInset.bottom
                         - view.textContainerInset.top - view.textContainerInset.bottom, 1)
        guard maximum > minimum + 0.5 else { return [minimum] }
        view.layoutManager.ensureLayout(for: view.textContainer)
        let glyphCount = view.layoutManager.numberOfGlyphs
        guard glyphCount > 0 else { return [minimum] }
        var lines: [(top: CGFloat, bottom: CGFloat)] = []
        view.layoutManager.enumerateLineFragments(forGlyphRange: NSRange(location: 0, length: glyphCount)) {
            rect, usedRect, _, _, _ in
            lines.append((rect.minY, usedRect.maxY))
        }
        var offsets = [minimum]
        var nextLine = 0
        while let current = offsets.last, current < maximum - 0.5 {
            let bottom = current + view.bounds.height - view.adjustedContentInset.bottom
                - view.textContainerInset.bottom - view.textContainerInset.top
            while nextLine < lines.count, lines[nextLine].bottom <= bottom + 0.5 { nextLine += 1 }
            guard nextLine < lines.count else { break }
            let lineOffset = lines[nextLine].top - view.adjustedContentInset.top
            let next = min(lineOffset > current + 0.5 ? lineOffset : current + height, maximum)
            guard next > current + 0.5 else { break }
            offsets.append(next)
        }
        return offsets
    }
}

struct ReaderTextView: UIViewRepresentable {
    let text: String
    let title: String
    let previousTitle: String?
    let previousText: String
    let isPreviousReady: Bool
    let continuationTitle: String?
    let continuationText: String
    let isContinuationReady: Bool
    let isVolume: Bool
    let fontSize: Double
    let fontPath: String
    let letterSpacing: Double
    let lineSpacing: Double
    let paragraphSpacing: Double
    let paragraphIndent: String
    let paddingLeft: Double
    let paddingRight: Double
    let paddingTop: Double
    let paddingBottom: Double
    let headerInset: Double
    let footerInset: Double
    let fontWeight: Int
    let titleMode: Int
    let titleSize: Double
    let titleTopSpacing: Double
    let titleBottomSpacing: Double
    let underlineMode: Int
    let isSelectable: Bool
    let fullJustify: Bool
    let pageAnimation: Int
    let isEInkMode: Bool
    let clickActions: [Int]
    let backgroundColor: UIColor
    let foregroundColor: UIColor
    let requestedPosition: Int
    let jumpPosition: Int?
    let renderRevision: Int
    @Binding var readerPosition: Int
    @Binding var pageRanges: [NSRange]
    @Binding var currentPage: Int
    @Binding var totalPages: Int
    let isAutoReading: Bool
    let isAutoReadPaused: Bool
    let isAutoFlipping: Bool
    let autoFlipInterval: Double
    let isLoadingNextChapter: Bool
    let secondsPerScreen: Double
    var highlights: [ReaderHighlight] = []
    let onReachedEnd: (Int) -> Void
    let onReachedStart: (Int) -> Void
    let onEnteredPrevious: (Int) -> Void
    let onEnteredContinuation: (Int) -> Void
    let onDeferredRender: () -> Void
    let onCancelNextLoading: () -> Void
    let onPageChanged: () -> Void
    let onTapAction: (Int) -> Void
    var onSelectionNote: ((String, Int, Bool) -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeUIView(context: Context) -> UITextView {
        // Pagination uses NSLayoutManager. Start in TextKit 1 rather than
        // switching a TextKit 2 view after its content size has been computed.
        let storage = NSTextStorage()
        let manager = ReaderHighlightLayoutManager()
        let container = NSTextContainer(size: .zero)
        manager.addTextContainer(container)
        storage.addLayoutManager(manager)
        let view = ReaderLayoutTextView(frame: .zero, textContainer: container)
        view.onLayout = { [weak coordinator = context.coordinator] view in
            coordinator?.reportPage(in: view)
            coordinator?.reportPageRanges(in: view)
        }
        view.accessibilityIdentifier = "reader.text"
        let effectivePageAnimation = isEInkMode ? 4 : pageAnimation
        view.clipsPagedText = effectivePageAnimation != 3
        view.backgroundColor = backgroundColor
        view.isOpaque = backgroundColor != .clear
        view.delegate = context.coordinator
        view.isEditable = false
        view.isSelectable = context.coordinator.selectionActive
        view.alwaysBounceVertical = effectivePageAnimation == 3
        view.isScrollEnabled = true
        view.contentInsetAdjustmentBehavior = .never
        view.panGestureRecognizer.isEnabled = effectivePageAnimation == 3
        view.textContainer.lineFragmentPadding = 4
        view.showsVerticalScrollIndicator = false
        view.isPagingEnabled = effectivePageAnimation != 3
        view.decelerationRate = effectivePageAnimation == 3 ? .normal : .fast
        context.coordinator.installDisplayLink(for: view)
        context.coordinator.installGestures(on: view)
        context.coordinator.updateInteractionMode(on: view, isScrollMode: effectivePageAnimation == 3)
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        context.coordinator.parent = self
        let viewportSizeChanged = view.bounds.size != .zero
            && context.coordinator.lastViewportSize != view.bounds.size
        if viewportSizeChanged {
            context.coordinator.lastViewportSize = view.bounds.size
        }
        let effectivePageAnimation = isEInkMode ? 4 : pageAnimation
        if let view = view as? ReaderLayoutTextView {
            view.clipsPagedText = effectivePageAnimation != 3
            view.setNeedsLayout()
        }
        view.isSelectable = context.coordinator.selectionActive
        view.alwaysBounceVertical = effectivePageAnimation == 3
        view.isScrollEnabled = true
        view.panGestureRecognizer.isEnabled = effectivePageAnimation == 3
        view.showsVerticalScrollIndicator = false
        view.isPagingEnabled = effectivePageAnimation != 3
        view.decelerationRate = effectivePageAnimation == 3 ? .normal : .fast
        context.coordinator.updateInteractionMode(on: view, isScrollMode: effectivePageAnimation == 3)
        view.backgroundColor = backgroundColor
        view.isOpaque = backgroundColor != .clear
        view.isSelectable = context.coordinator.selectionActive
        if !context.coordinator.selectionActive {
            view.selectedRange = NSRange(location: 0, length: 0)
            view.resignFirstResponder()
        }
        view.textContainerInset = .init(
            top: CGFloat(paddingTop + headerInset),
            left: CGFloat(paddingLeft),
            bottom: CGFloat(paddingBottom + footerInset),
            right: CGFloat(paddingRight)
        )
        let contentKey = text.hashValue
        let primaryContentKey = "\(title)|\(text)".hashValue
        let showsContinuation = effectivePageAnimation == 3 && isContinuationReady && continuationTitle != nil
        let showsPrevious = showsContinuation && isPreviousReady && previousTitle != nil
        let adjacentContentKey = "\(showsPrevious)|\(previousTitle ?? "")|\(previousText)|\(showsContinuation)|\(continuationTitle ?? "")|\(continuationText)".hashValue
        let displaysTitle = titleMode != 2 || isVolume
        let titlePrefix = displaysTitle && !title.isEmpty ? title + "\n" : ""
        let styleKey = "\(contentKey)|\(adjacentContentKey)|\(title)|\(isVolume)|\(fontSize)|\(fontPath)|\(letterSpacing)|\(lineSpacing)|\(paragraphSpacing)|\(paragraphIndent)|\(paddingLeft)|\(paddingRight)|\(paddingTop)|\(paddingBottom)|\(headerInset)|\(footerInset)|\(fontWeight)|\(titleMode)|\(titleSize)|\(titleTopSpacing)|\(titleBottomSpacing)|\(underlineMode)|\(isSelectable)|\(fullJustify)|\(effectivePageAnimation)|\(foregroundColor.hash)"
        if context.coordinator.styleKey != styleKey {
            if context.coordinator.shouldDeferRender(in: view) {
                context.coordinator.needsDeferredRender = true
                return
            }
            let primaryContentChanged = context.coordinator.primaryContentKey != primaryContentKey
            let visiblePosition = context.coordinator.contentCharacter(at: view.contentOffset, in: view)
            context.coordinator.resetAutoReadForPageChange()
            context.coordinator.resetPageRangeRetry()
            context.coordinator.contentKey = contentKey
            context.coordinator.primaryContentKey = primaryContentKey
            context.coordinator.styleKey = styleKey
            let typography = ReaderTypography(configuration: self)
            let bodyAttributes = typography.bodyAttributes
            let rendered = NSMutableAttributedString(string: "")
            context.coordinator.previousBodyStart = nil
            context.coordinator.previousBodyEnd = nil
            context.coordinator.continuationSectionStart = nil
            context.coordinator.continuationBodyStart = nil
            if showsPrevious {
                let previousHeading = displaysTitle ? (previousTitle ?? "") + "\n" : ""
                rendered.append(NSAttributedString(string: previousHeading, attributes: typography.headingAttributes))
                context.coordinator.previousBodyStart = rendered.length
                rendered.append(NSAttributedString(
                    string: previousText.isEmpty ? String(repeating: "\n", count: 80) : previousText,
                    attributes: bodyAttributes
                ))
                context.coordinator.previousBodyEnd = rendered.length
                rendered.append(NSAttributedString(string: "\n\n", attributes: bodyAttributes))
            }
            context.coordinator.currentSectionStart = rendered.length
            if !titlePrefix.isEmpty {
                rendered.append(NSAttributedString(string: titlePrefix, attributes: typography.headingAttributes))
            }
            context.coordinator.renderedPrefixLength = rendered.length
            rendered.append(NSAttributedString(string: text, attributes: bodyAttributes))
            context.coordinator.currentBodyEnd = rendered.length
            if showsContinuation {
                rendered.append(NSAttributedString(string: "\n\n", attributes: bodyAttributes))
                context.coordinator.continuationSectionStart = rendered.length
                let continuationHeading = displaysTitle ? (continuationTitle ?? "") + "\n" : ""
                rendered.append(NSAttributedString(string: continuationHeading, attributes: typography.headingAttributes))
                context.coordinator.continuationBodyStart = rendered.length
                rendered.append(NSAttributedString(
                    string: continuationText.isEmpty ? String(repeating: "\n", count: 80) : continuationText,
                    attributes: bodyAttributes
                ))
            }
            context.coordinator.isApplyingContent = true
            view.attributedText = rendered
            context.coordinator.isApplyingContent = false
            context.coordinator.scroll(
                to: primaryContentChanged ? requestedPosition : visiblePosition,
                in: view
            )
            let generation = context.coordinator.layoutGeneration
            DispatchQueue.main.async { [weak coordinator = context.coordinator] in
                guard coordinator?.layoutGeneration == generation else { return }
                coordinator?.reportPage(in: view)
                coordinator?.reportPageRanges(in: view)
            }
        } else if viewportSizeChanged {
            context.coordinator.scroll(to: readerPosition, in: view)
            let generation = context.coordinator.layoutGeneration
            DispatchQueue.main.async { [weak coordinator = context.coordinator] in
                guard coordinator?.layoutGeneration == generation else { return }
                coordinator?.reportPage(in: view)
                coordinator?.reportPageRanges(in: view)
            }
        }
        if let jumpPosition, context.coordinator.lastJumpPosition != jumpPosition {
            context.coordinator.lastJumpPosition = jumpPosition
            context.coordinator.scroll(to: jumpPosition, in: view)
        } else if jumpPosition == nil {
            context.coordinator.lastJumpPosition = nil
        }
        context.coordinator.updateLoadingFooter(in: view, visible: isLoadingNextChapter)
        context.coordinator.updateAutoRead(
            isRunning: isAutoReading,
            isPaused: isAutoReadPaused,
            secondsPerScreen: secondsPerScreen
        )
        context.coordinator.updateAutoFlip(
            isRunning: isAutoFlipping,
            isPaused: isAutoReadPaused,
            interval: autoFlipInterval
        )
        Self.applyHighlights(highlights, to: view, bodyRange: NSRange(
            location: context.coordinator.renderedPrefixLength,
            length: max(context.coordinator.currentBodyEnd - context.coordinator.renderedPrefixLength, 0)
        ))
        // SwiftUI can reset the bindings after the chapter's TextKit layout has
        // already completed. Reconcile them even when the text/style is unchanged.
        if view.bounds.width > 0, view.bounds.height > 0 {
            context.coordinator.reportPage(in: view)
            if pageRanges.isEmpty { context.coordinator.reportPageRanges(in: view) }
        }
    }

    /// 把笔记对应的原文段落涂上底色。段落锚点比字符偏移稳定：
    /// 换字号、换字体、重排后依然能定位到同一段。
    private static func applyHighlights(
        _ highlights: [ReaderHighlight],
        to view: UITextView,
        bodyRange: NSRange
    ) {
        let text = (view.text ?? "") as NSString
        guard let manager = view.layoutManager as? ReaderHighlightLayoutManager else { return }
        manager.highlights = []
        defer {
            manager.invalidateDisplay(forCharacterRange: NSRange(location: 0, length: text.length))
            view.setNeedsDisplay()
        }
        guard !highlights.isEmpty, bodyRange.length > 0 else { return }
        for item in highlights {
            let quote = item.quote.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !quote.isEmpty else { continue }
            if let offset = item.startOffset {
                let range = NSRange(location: bodyRange.location + max(offset, 0), length: (quote as NSString).length)
                if NSMaxRange(range) <= NSMaxRange(bodyRange), text.substring(with: range) == quote {
                    manager.highlights.append((range, ReaderHighlight.uiColor(item.color)))
                    continue
                }
            }
            var searchRange = bodyRange
            var matched = 0
            while searchRange.length > 0, matched < 1 {
                let found = text.range(of: quote, options: [.caseInsensitive], range: searchRange)
                if found.location == NSNotFound { break }
                manager.highlights.append((found, ReaderHighlight.uiColor(item.color)))
                let next = found.location + max(found.length, 1)
                searchRange = NSRange(
                    location: next,
                    length: max(bodyRange.location + bodyRange.length - next, 0)
                )
                matched += 1
            }
        }
    }

    static func dismantleUIView(_ view: UITextView, coordinator: Coordinator) {
        coordinator.invalidate()
    }

    final class Coordinator: NSObject, UITextViewDelegate, UIGestureRecognizerDelegate {
        var parent: ReaderTextView
        var selectionActive = false
        var selectionMenu: AnyObject?
        var contentKey = 0
        var primaryContentKey = 0
        var styleKey = ""
        var renderedPrefixLength = 0
        var currentSectionStart = 0
        var currentBodyEnd = 0
        var previousBodyStart: Int?
        var previousBodyEnd: Int?
        var continuationSectionStart: Int?
        var continuationBodyStart: Int?
        var lastJumpPosition: Int?
        private(set) var layoutGeneration = 0
        var lastViewportSize = CGSize.zero
        private var isAutoReading = false
        private var isAutoReadPaused = false
        private var isAutoFlipping = false
        private var secondsPerScreen = 10.0
        private var autoFlipInterval: Double = 12
        private var flipElapsed: CFTimeInterval = 0
        private weak var textView: UITextView?
        private var displayLink: CADisplayLink?
        private var lastTimestamp: CFTimeInterval = 0
        private var isUserDragging = false
        private var lastDragOffsetY: CGFloat = 0
        private var dragDirection = 0
        private var didReachEnd = false
        private var didReachStart = false
        private var didEnterPrevious = false
        private var didEnterContinuation = false
        private var pendingPreviousPosition: Int?
        private var pendingContinuationPosition: Int?
        var needsDeferredRender = false
        var isApplyingContent = false
        private var isTurningPage = false
        private var isRenderingAutoPage = false
        private var isCapturingPageTurn = false
        private var pageCurlAnimator: ReaderPageCurlAnimator?
        private var lastReportedPage: Int?
        private var autoPageProgress: CGFloat = 0
        private var eInkElapsed: CFTimeInterval = 0
        private var eInkPageInterval: CFTimeInterval = 10
        private var autoPageTarget: CGFloat?
        private weak var autoPageOverlay: UIImageView?
        private var pageRangeRetryCount = 0
        private var pageOffsetsKey = ""
        private var cachedPageOffsets: [CGFloat] = []
        private weak var nextSwipe: UISwipeGestureRecognizer?
        private weak var previousSwipe: UISwipeGestureRecognizer?
        private weak var readerTap: UITapGestureRecognizer?
        private weak var readerLongPress: UILongPressGestureRecognizer?
        private weak var loadingFooter: UIView?
        private var didRequestLoadingCancellation = false

        init(parent: ReaderTextView) { self.parent = parent }

        func installDisplayLink(for view: UITextView) {
            textView = view
            let link = CADisplayLink(target: self, selector: #selector(step(_:)))
            link.add(to: .main, forMode: .common)
            displayLink = link
        }

        func installGestures(on view: UITextView) {
            let tap = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
            tap.delaysTouchesBegan = false
            tap.cancelsTouchesInView = false
            tap.delegate = self
            view.addGestureRecognizer(tap)
            readerTap = tap
            // 长按任意位置弹出阅读菜单（比“点中心格”更容错）。
            let longPress = UILongPressGestureRecognizer(target: self, action: #selector(longPressed(_:)))
            longPress.minimumPressDuration = 0.35
            longPress.allowableMovement = 24
            longPress.delegate = self
            view.addGestureRecognizer(longPress)
            readerLongPress = longPress
            // 快速点击仍然走 tap；只有长按失败（抬手未到 0.35s）才交给 tap。
            tap.require(toFail: longPress)
            let next = UISwipeGestureRecognizer(target: self, action: #selector(swiped(_:)))
            next.direction = .left
            view.addGestureRecognizer(next)
            let previous = UISwipeGestureRecognizer(target: self, action: #selector(swiped(_:)))
            previous.direction = .right
            view.addGestureRecognizer(previous)
            nextSwipe = next
            previousSwipe = previous
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            gestureRecognizer === readerTap || otherGestureRecognizer === readerTap
                || gestureRecognizer === readerLongPress || otherGestureRecognizer === readerLongPress
        }

        func updateInteractionMode(on view: UITextView, isScrollMode: Bool) {
            // The scroll reader owns the vertical pan gesture. Horizontal
            // swipe recognizers must be disabled there or UIKit can cancel the
            // pan before the user reaches the end of a long chapter.
            nextSwipe?.isEnabled = !isScrollMode
            previousSwipe?.isEnabled = !isScrollMode
            view.panGestureRecognizer.isEnabled = isScrollMode
            view.alwaysBounceVertical = isScrollMode
            view.isPagingEnabled = !isScrollMode
            view.showsVerticalScrollIndicator = false
        }

        func updateLoadingFooter(in view: UITextView, visible: Bool) {
            if !visible {
                loadingFooter?.removeFromSuperview()
                loadingFooter = nil
                view.contentInset.bottom = 0
                didRequestLoadingCancellation = false
                return
            }
            let footer: UIView
            if let loadingFooter {
                footer = loadingFooter
            } else {
                let container = UIView()
                container.isUserInteractionEnabled = false
                let indicator = UIActivityIndicatorView(style: .medium)
                indicator.color = parent.foregroundColor.withAlphaComponent(0.65)
                indicator.startAnimating()
                let label = UILabel()
                label.text = "正在加载下一章…"
                label.textColor = parent.foregroundColor.withAlphaComponent(0.65)
                label.font = .systemFont(ofSize: 13)
                let stack = UIStackView(arrangedSubviews: [indicator, label])
                stack.axis = .horizontal
                stack.spacing = 8
                stack.alignment = .center
                stack.translatesAutoresizingMaskIntoConstraints = false
                container.addSubview(stack)
                NSLayoutConstraint.activate([
                    stack.centerXAnchor.constraint(equalTo: container.centerXAnchor),
                    stack.centerYAnchor.constraint(equalTo: container.centerYAnchor)
                ])
                view.addSubview(container)
                loadingFooter = container
                footer = container
            }
            view.contentInset.bottom = 64
            footer.frame = CGRect(x: 0, y: view.contentSize.height, width: view.bounds.width, height: 52)
        }

        func shouldDeferRender(in view: UITextView) -> Bool {
            parent.pageAnimation == 3 && (isUserDragging || view.isDragging || view.isDecelerating)
        }

        func invalidate() {
            layoutGeneration &+= 1
            pageCurlAnimator?.cancel()
            pageCurlAnimator = nil
            isTurningPage = false
            resetAutoPage()
            displayLink?.invalidate()
            displayLink = nil
        }

        func updateAutoRead(isRunning: Bool, isPaused: Bool, secondsPerScreen: Double) {
            let wasRunning = isAutoReading
            let wasPaused = isAutoReadPaused
            self.isAutoReading = isRunning
            isAutoReadPaused = isPaused
            self.secondsPerScreen = max(1, secondsPerScreen)
            if wasRunning && !isRunning {
                resetAutoPage()
            } else if !wasRunning && isRunning {
                didReachEnd = false
                lastTimestamp = 0
                eInkPageInterval = self.secondsPerScreen
            } else if isPaused || wasPaused != isPaused {
                lastTimestamp = 0
            }
        }

        func updateAutoFlip(isRunning: Bool, isPaused: Bool, interval: Double) {
            let wasRunning = isAutoFlipping
            isAutoFlipping = isRunning
            autoFlipInterval = max(1, interval)
            if !wasRunning, isRunning {
                flipElapsed = 0
                lastTimestamp = 0
            } else if wasRunning, !isRunning {
                flipElapsed = 0
            }
        }

        func resetAutoReadForPageChange() {
            didReachEnd = false
            didReachStart = false
            lastReportedPage = nil
            didEnterPrevious = false
            didEnterContinuation = false
            pendingPreviousPosition = nil
            pendingContinuationPosition = nil
            flipElapsed = 0
            resetAutoPage()
        }

        func scroll(to characterPosition: Int, in view: UITextView) {
            guard !view.text.isEmpty else { return }
            layoutGeneration &+= 1
            let generation = layoutGeneration
            let prefix = characterPosition == 0
                ? currentSectionStart
                : renderedPrefixLength
            let location = ReaderPositionResolver.renderedLocation(
                position: characterPosition,
                prefixLength: prefix,
                renderedLength: view.text.utf16.count
            )
            DispatchQueue.main.async { [weak self] in
                guard let self, self.layoutGeneration == generation else { return }
                view.layoutManager.ensureLayout(for: view.textContainer)
                let glyph = view.layoutManager.glyphIndexForCharacter(at: location)
                var point = view.layoutManager.boundingRect(
                    forGlyphRange: NSRange(location: glyph, length: 1),
                    in: view.textContainer
                ).origin
                point.y += view.textContainerInset.top
                let limits = self.scrollLimits(for: view)
                let target = characterPosition == 0 && self.currentSectionStart == 0
                    ? limits.minimum
                    : min(max(point.y - view.textContainerInset.top - view.adjustedContentInset.top, limits.minimum), limits.maximum)
                view.setContentOffset(CGPoint(x: 0, y: target), animated: false)
            }
        }

        private func readingViewportHeight(for view: UITextView) -> CGFloat {
            max(
                view.bounds.height
                    - view.adjustedContentInset.top
                    - view.adjustedContentInset.bottom
                    - view.textContainerInset.top
                    - view.textContainerInset.bottom,
                1
            )
        }

        private func scrollLimits(for view: UITextView) -> (minimum: CGFloat, maximum: CGFloat) {
            let minimum = -view.adjustedContentInset.top
            let maximum = max(
                view.contentSize.height - view.bounds.height + view.adjustedContentInset.bottom,
                minimum
            )
            return (minimum, maximum)
        }

        private func pageOffsets(for view: UITextView) -> [CGFloat] {
            let key = "\(styleKey)|\(view.bounds.size)|\(view.contentSize)|\(view.textContainerInset)|\(view.adjustedContentInset)"
            if key != pageOffsetsKey || cachedPageOffsets.isEmpty {
                cachedPageOffsets = ReaderPageLayout.offsets(in: view)
                pageOffsetsKey = key
            }
            return cachedPageOffsets
        }

        private func pageIndex(for view: UITextView, offsets: [CGFloat]) -> Int {
            offsets.lastIndex(where: { $0 <= view.contentOffset.y + 0.5 }) ?? 0
        }

        private func pageMetrics(for view: UITextView) -> (current: Int, total: Int) {
            let pageHeight = readingViewportHeight(for: view)
            if parent.pageAnimation == 3, currentBodyEnd > currentSectionStart {
                view.layoutManager.ensureLayout(for: view.textContainer)
                let glyphCount = view.layoutManager.numberOfGlyphs
                if glyphCount > 0 {
                    let first = min(view.layoutManager.glyphIndexForCharacter(at: currentSectionStart), glyphCount - 1)
                    let last = min(view.layoutManager.glyphIndexForCharacter(at: currentBodyEnd - 1), glyphCount - 1)
                    let start = view.layoutManager.boundingRect(
                        forGlyphRange: NSRange(location: first, length: 1), in: view.textContainer
                    ).minY + view.textContainerInset.top - view.adjustedContentInset.top
                    let end = view.layoutManager.boundingRect(
                        forGlyphRange: NSRange(location: last, length: 1), in: view.textContainer
                    ).maxY + view.textContainerInset.top - view.adjustedContentInset.top
                    let total = max(Int(ceil((end - start) / pageHeight)), 1)
                    let position = max(view.contentOffset.y - start, 0)
                    return (min(Int(floor(position / pageHeight)) + 1, total), total)
                }
            }
            let offsets = pageOffsets(for: view)
            return (pageIndex(for: view, offsets: offsets) + 1, offsets.count)
        }

        private func renderedCharacter(at offset: CGPoint, in view: UITextView) -> Int {
            guard !view.text.isEmpty else { return 0 }
            let point = CGPoint(
                x: view.textContainerInset.left + 1,
                y: offset.y + view.textContainerInset.top + 1
            )
            let glyphCount = view.layoutManager.numberOfGlyphs
            guard glyphCount > 0 else { return 0 }
            let glyph = min(view.layoutManager.glyphIndex(for: point, in: view.textContainer), glyphCount - 1)
            let character = view.layoutManager.characterIndexForGlyph(at: glyph)
            return min(max(character, 0), view.text.utf16.count)
        }

        func contentCharacter(at offset: CGPoint, in view: UITextView) -> Int {
            let character = renderedCharacter(at: offset, in: view)
            return min(max(character - renderedPrefixLength, 0), parent.text.utf16.count)
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            guard !isRenderingAutoPage, !isApplyingContent, !isCapturingPageTurn else { return }
            guard let view = scrollView as? UITextView, !view.text.isEmpty else { return }
            if parent.isLoadingNextChapter, !didRequestLoadingCancellation {
                let textBottom = max(
                    view.contentSize.height - view.bounds.height
                        + view.adjustedContentInset.bottom - view.contentInset.bottom,
                    -view.adjustedContentInset.top
                )
                if view.contentOffset.y < textBottom - 44 {
                    didRequestLoadingCancellation = true
                    DispatchQueue.main.async { [weak self] in self?.parent.onCancelNextLoading() }
                }
            }
            if isUserDragging {
                let delta = scrollView.contentOffset.y - lastDragOffsetY
                if abs(delta) > 0.5 { dragDirection = delta > 0 ? 1 : -1 }
                lastDragOffsetY = scrollView.contentOffset.y
            }
            let metrics = pageMetrics(for: view)
            reportPage(in: view)
            if let lastReportedPage, lastReportedPage != metrics.current {
                self.lastReportedPage = metrics.current
                let generation = layoutGeneration
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.layoutGeneration == generation else { return }
                    self.parent.onPageChanged()
                }
            } else if lastReportedPage == nil {
                lastReportedPage = metrics.current
            }
            let contentCharacter = contentCharacter(at: scrollView.contentOffset, in: view)
            let renderedCharacter = renderedCharacter(at: scrollView.contentOffset, in: view)
            if let previousBodyStart,
               let previousBodyEnd,
               renderedCharacter < currentSectionStart {
                pendingContinuationPosition = nil
                let position = min(max(renderedCharacter - previousBodyStart, 0), max(previousBodyEnd - previousBodyStart - 1, 0))
                if isUserDragging || view.isDecelerating {
                    pendingPreviousPosition = position
                    return
                }
                guard !didEnterPrevious else { return }
                didEnterPrevious = true
                let generation = layoutGeneration
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.layoutGeneration == generation else { return }
                    self.parent.onEnteredPrevious(position)
                }
                return
            }
            if let continuationSectionStart,
               let continuationBodyStart,
               renderedCharacter >= continuationSectionStart {
                pendingPreviousPosition = nil
                let position = max(renderedCharacter - continuationBodyStart, 0)
                if isUserDragging || view.isDecelerating {
                    pendingContinuationPosition = position
                    return
                }
                guard !didEnterContinuation else { return }
                didEnterContinuation = true
                let generation = layoutGeneration
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.layoutGeneration == generation else { return }
                    self.parent.onEnteredContinuation(position)
                }
                return
            }
            pendingPreviousPosition = nil
            pendingContinuationPosition = nil
            guard contentCharacter != parent.readerPosition else { return }
            let generation = layoutGeneration
            DispatchQueue.main.async { [weak self] in
                guard let self, self.layoutGeneration == generation else { return }
                self.parent.readerPosition = contentCharacter
            }
        }

        func reportPage(in view: UITextView) {
            guard view.bounds.width > 0, view.bounds.height > 0 else { return }
            let metrics = pageMetrics(for: view)
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-uiPagingDiagnostics") {
                view.accessibilityLabel = "bounds=\(view.bounds.size) content=\(view.contentSize) used=\(view.layoutManager.usedRect(for: view.textContainer)) mode=\(parent.pageAnimation) pages=\(metrics.total)"
            }
            #endif
            guard metrics.current != parent.currentPage || metrics.total != parent.totalPages else { return }
            let generation = layoutGeneration
            DispatchQueue.main.async { [weak self] in
                guard let self, self.layoutGeneration == generation else { return }
                self.parent.currentPage = metrics.current
                self.parent.totalPages = metrics.total
            }
        }

        func reportPageRanges(in view: UITextView) {
            guard view.bounds.width > 0, view.bounds.height > 0 else { return }
            if parent.pageAnimation == 3 {
                let ranges = parent.text.isEmpty
                    ? []
                    : [NSRange(location: 0, length: parent.text.utf16.count)]
                guard ranges != parent.pageRanges else { return }
                DispatchQueue.main.async { [weak self] in self?.parent.pageRanges = ranges }
                return
            }
            guard !view.text.isEmpty else { return }
            view.layoutManager.ensureLayout(for: view.textContainer)
            let pageHeight = readingViewportHeight(for: view)
            let offsets = pageOffsets(for: view)
            var ranges: [NSRange] = []
            for (page, offset) in offsets.enumerated() {
                let rect = CGRect(
                    x: 0,
                    y: max(0, offset + view.adjustedContentInset.top),
                    width: max(view.textContainer.size.width, 1),
                    height: page + 1 < offsets.count ? max(1, offsets[page + 1] - offset - 0.01) : pageHeight
                )
                let glyphRange = view.layoutManager.glyphRange(
                    forBoundingRect: rect,
                    in: view.textContainer
                )
                guard glyphRange.length > 0 else { continue }
                let characterRange = view.layoutManager.characterRange(
                    forGlyphRange: glyphRange,
                    actualGlyphRange: nil
                )
                let start = max(characterRange.location - renderedPrefixLength, 0)
                let end = min(
                    characterRange.location + characterRange.length - renderedPrefixLength,
                    parent.text.utf16.count
                )
                guard end > start else { continue }
                let range = NSRange(location: start, length: end - start)
                if ranges.last?.location == range.location,
                   ranges.last?.length == range.length { continue }
                ranges.append(range)
            }
            if ranges.isEmpty {
                guard pageRangeRetryCount < 10 else { return }
                pageRangeRetryCount += 1
                let generation = layoutGeneration
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                    guard let self, self.layoutGeneration == generation else { return }
                    self.reportPageRanges(in: view)
                }
                return
            }
            pageRangeRetryCount = 0
            guard ranges != parent.pageRanges else { return }
            let generation = layoutGeneration
            DispatchQueue.main.async { [weak self] in
                guard let self, self.layoutGeneration == generation else { return }
                self.parent.pageRanges = ranges
            }
        }

        func resetPageRangeRetry() {
            pageRangeRetryCount = 0
        }

        func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
            isUserDragging = true
            lastDragOffsetY = scrollView.contentOffset.y
            dragDirection = 0
            didReachEnd = false
            didReachStart = false
        }
        func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
            if parent.pageAnimation == 3, let view = scrollView as? UITextView {
                triggerChapterBoundaryIfNeeded(in: view)
            }
            if !decelerate {
                isUserDragging = false
                flushPendingChapterTransition()
                requestDeferredRenderIfNeeded()
            }
        }
        func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
            if parent.pageAnimation == 3, let view = scrollView as? UITextView {
                triggerChapterBoundaryIfNeeded(in: view)
            }
            isUserDragging = false
            flushPendingChapterTransition()
            requestDeferredRenderIfNeeded()
        }

        private func requestDeferredRenderIfNeeded() {
            guard needsDeferredRender else { return }
            needsDeferredRender = false
            DispatchQueue.main.async { [weak self] in self?.parent.onDeferredRender() }
        }

        private func flushPendingChapterTransition() {
            let previous = pendingPreviousPosition
            let continuation = pendingContinuationPosition
            pendingPreviousPosition = nil
            pendingContinuationPosition = nil
            let generation = layoutGeneration
            if let previous, !didEnterPrevious {
                didEnterPrevious = true
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.layoutGeneration == generation else { return }
                    self.parent.onEnteredPrevious(previous)
                }
            } else if let continuation, !didEnterContinuation {
                didEnterContinuation = true
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.layoutGeneration == generation else { return }
                    self.parent.onEnteredContinuation(continuation)
                }
            }
        }

        private func triggerChapterBoundaryIfNeeded(in view: UITextView) {
            let (minimum, maximum) = scrollLimits(for: view)
            let atEnd = view.contentOffset.y >= maximum - 0.5
            let atStart = view.contentOffset.y <= minimum + 0.5
            if atEnd, dragDirection > 0, continuationSectionStart == nil, !didReachEnd {
                didReachEnd = true
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                parent.onReachedEnd(contentCharacter(at: view.contentOffset, in: view))
            } else if atStart, dragDirection < 0, previousBodyStart == nil, !didReachStart {
                didReachStart = true
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                parent.onReachedStart(contentCharacter(at: view.contentOffset, in: view))
            }
        }

        @objc private func tapped(_ gesture: UITapGestureRecognizer) {
            guard let view = textView, gesture.state == .ended else { return }
            if selectionActive {
                selectionActive = false
                view.selectedRange = NSRange(location: 0, length: 0)
                view.isSelectable = false
                view.resignFirstResponder()
                if #available(iOS 16.0, *) { (selectionMenu as? ReaderSelectionMenu)?.dismiss() }
                return
            }
            let point = gesture.location(in: view)
            // UIScrollView changes its bounds origin as content scrolls, and
            // gesture locations use that content coordinate space. Convert
            // back to viewport coordinates before mapping the visible screen.
            let viewportX = point.x - view.bounds.minX
            let viewportY = point.y - view.bounds.minY
            let action = ReaderTapMapping.action(
                for: CGPoint(x: viewportX, y: viewportY),
                in: view.bounds.size,
                clickActions: parent.clickActions
            )

            if parent.pageAnimation == 3, action == 1 || action == 2 {
                return
            }
            switch action {
            case 1: turnPage(1)
            case 2: turnPage(-1)
            case -1: break
            default: parent.onTapAction(action)
            }
        }

        @objc private func longPressed(_ gesture: UILongPressGestureRecognizer) {
            guard gesture.state == .began, let view = textView, !view.isDragging else { return }
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            guard parent.onSelectionNote != nil, let reader = view as? ReaderLayoutTextView else {
                parent.onTapAction(0)
                return
            }
            let point = gesture.location(in: view)
            guard let position = view.closestPosition(to: point),
                  let word = view.tokenizer.rangeEnclosingPosition(position, with: .word, inDirection: UITextDirection(rawValue: 1)) else { return }
            let start = view.offset(from: view.beginningOfDocument, to: word.start)
            let end = view.offset(from: view.beginningOfDocument, to: word.end)
            guard start >= renderedPrefixLength, end <= currentBodyEnd else { return }
            selectionActive = true
            view.isSelectable = true
            view.becomeFirstResponder()
            view.selectedRange = NSRange(location: start, length: end - start)
            reader.selectionAction = { [weak self] view, writesIdea in
                guard let self else { return }
                let range = view.selectedRange
                guard range.location >= self.renderedPrefixLength, NSMaxRange(range) <= self.currentBodyEnd,
                      range.length > 0 else { return }
                self.parent.onSelectionNote?((view.text as NSString).substring(with: range),
                                             range.location - self.renderedPrefixLength, writesIdea)
                self.selectionActive = false
                view.selectedRange = NSRange(location: 0, length: 0)
                view.isSelectable = false
                view.resignFirstResponder()
            }
            if #available(iOS 16.0, *) {
                (selectionMenu as? ReaderSelectionMenu)?.dismiss()
                let menu = ReaderSelectionMenu(selectedText: (view.text as NSString).substring(with: view.selectedRange)) { [weak reader] writesIdea in
                    guard let reader else { return }
                    reader.selectionAction?(reader, writesIdea)
                }
                selectionMenu = menu
                menu.present(on: view, at: point)
            } else {
                UIMenuController.shared.menuItems = [
                    UIMenuItem(title: "高亮", action: #selector(ReaderLayoutTextView.highlightSelection)),
                    UIMenuItem(title: "写想法", action: #selector(ReaderLayoutTextView.annotateSelection))
                ]
                UIMenuController.shared.showMenu(from: view, rect: view.firstRect(for: word))
            }
        }

        @objc private func swiped(_ gesture: UISwipeGestureRecognizer) {
            turnPage(gesture.direction == .left ? 1 : -1)
        }

        private func turnPage(_ direction: Int) {
            guard !isTurningPage, let view = textView else { return }
            if isAutoReading || isAutoFlipping { resetAutoReadForPageChange() }
            let offsets = pageOffsets(for: view)
            let index = pageIndex(for: view, offsets: offsets)
            if direction < 0, index == 0, view.contentOffset.y <= offsets[0] + 0.5 {
                parent.onReachedStart(contentCharacter(at: view.contentOffset, in: view))
                return
            }
            if direction > 0, index == offsets.count - 1 {
                parent.onReachedEnd(contentCharacter(at: view.contentOffset, in: view))
                return
            }
            let targetIndex = direction > 0 ? min(index + 1, offsets.count - 1)
                : (view.contentOffset.y > offsets[index] + 0.5 ? index : max(index - 1, 0))
            let target = offsets[targetIndex]
            isTurningPage = true
            switch parent.isEInkMode ? 4 : parent.pageAnimation {
            case 4:
                view.setContentOffset(CGPoint(x: 0, y: target), animated: false)
                isTurningPage = false
            case 0:
                let transition = CATransition()
                transition.duration = 0.3
                transition.type = direction > 0 ? .reveal : .moveIn
                transition.subtype = direction > 0 ? .fromRight : .fromLeft
                view.layer.add(transition, forKey: "reader-cover")
                view.setContentOffset(CGPoint(x: 0, y: target), animated: false)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.31) { [weak self] in self?.isTurningPage = false }
            case 1:
                let transition = CATransition()
                transition.duration = 0.3
                transition.type = .push
                transition.subtype = direction > 0 ? .fromRight : .fromLeft
                view.layer.add(transition, forKey: "reader-slide")
                view.setContentOffset(CGPoint(x: 0, y: target), animated: false)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.31) { [weak self] in self?.isTurningPage = false }
            case 2:
                startPageCurlTurn(direction: direction, target: target, view: view)
            default:
                view.setContentOffset(CGPoint(x: 0, y: target), animated: true)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.32) { [weak self] in self?.isTurningPage = false }
            }
        }

        /// 仿真翻页：先把当前页与目标页各渲染成一张位图，再交给
        /// ReaderPageCurlAnimator 做「折页 + 阴影」动画。
        ///
        /// 旧实现用 `UIView.transition(with: textView, .transitionCurlUp)`
        /// 直接对 UITextView 做系统卷页。UITextView 是 UIScrollView，且此视图
        /// 带有一层 `pageMask`（裁掉跨页的半行），系统卷页在动画期间会对这个
        /// 滚动视图反复取快照，遮罩与正在滚动的内容叠加，就出现上一页/下一行
        /// 文字残留的「残影」。改为对纯位图做动画后，live 文本视图不再参与
        /// 转场，残影消失。
        private func startPageCurlTurn(direction: Int, target: CGFloat, view: UITextView) {
            let currentOffset = view.contentOffset.y
            guard abs(target - currentOffset) > 0.5 else {
                view.setContentOffset(CGPoint(x: 0, y: target), animated: false)
                isTurningPage = false
                return
            }

            let sourceImage = renderPageImage(in: view)
            let destinationImage = renderPageImage(in: view, at: target)

            let background = parent.backgroundColor
            let paperColor: UIColor = background.cgColor.alpha > 0.01
                ? background
                : UIColor.secondarySystemBackground

            guard let animator = ReaderPageCurlAnimator(
                host: view,
                source: sourceImage,
                destination: destinationImage,
                forward: direction > 0,
                targetOffset: target,
                paperColor: paperColor,
                foldAccentColor: parent.foregroundColor,
                duration: 0.4
            ) else {
                view.setContentOffset(CGPoint(x: 0, y: target), animated: false)
                isTurningPage = false
                return
            }

            pageCurlAnimator = animator
            animator.start { [weak self] _ in
                guard let self else { return }
                self.pageCurlAnimator = nil
                self.isTurningPage = false
            }
        }

        /// 渲染文本视图当前可见页为位图；传入 offset 时先临时滚动到该位置再
        /// 渲染，随后恢复到原位置（用于抓取目标页）。整个过程屏蔽
        /// scrollViewDidScroll 回调，避免误触发换页/进度写入。
        private func renderPageImage(in view: UITextView, at offset: CGFloat? = nil) -> UIImage {
            let originalOffset = view.contentOffset.y
            if let offset {
                isCapturingPageTurn = true
                view.setContentOffset(CGPoint(x: 0, y: offset), animated: false)
                view.layoutIfNeeded()
            }
            let renderer = UIGraphicsImageRenderer(bounds: view.bounds)
            let image = renderer.image { context in
                view.layer.render(in: context.cgContext)
            }
            if offset != nil {
                view.setContentOffset(CGPoint(x: 0, y: originalOffset), animated: false)
                view.layoutIfNeeded()
                isCapturingPageTurn = false
            }
            return image
        }

        private func resetAutoPage() {
            autoPageProgress = 0
            eInkElapsed = 0
            eInkPageInterval = secondsPerScreen
            autoPageTarget = nil
            autoPageOverlay?.removeFromSuperview()
            autoPageOverlay = nil
            lastTimestamp = 0
        }

        private func prepareAutoPage(in view: UITextView) -> Bool {
            let offsets = pageOffsets(for: view)
            let index = pageIndex(for: view, offsets: offsets)
            guard index + 1 < offsets.count else { return false }
            let target = offsets[index + 1]
            let originalOffset = view.contentOffset
            isRenderingAutoPage = true
            view.setContentOffset(CGPoint(x: 0, y: target), animated: false)
            view.layoutIfNeeded()
            let renderer = UIGraphicsImageRenderer(bounds: view.bounds)
            let image = renderer.image { context in view.layer.render(in: context.cgContext) }
            view.setContentOffset(originalOffset, animated: false)
            isRenderingAutoPage = false

            let overlay = UIImageView(image: image)
            overlay.isUserInteractionEnabled = false
            overlay.contentMode = .top
            overlay.clipsToBounds = true
            overlay.layer.borderColor = view.tintColor.cgColor
            overlay.layer.borderWidth = 0
            overlay.frame = CGRect(x: 0, y: originalOffset.y, width: view.bounds.width, height: 0)
            view.addSubview(overlay)
            autoPageOverlay = overlay
            autoPageTarget = target
            return true
        }

        private func advancePagedAutoRead(in view: UITextView, elapsed: CFTimeInterval) {
            if autoPageOverlay == nil, !prepareAutoPage(in: view) {
                guard !didReachEnd else { return }
                didReachEnd = true
                parent.onReachedEnd(contentCharacter(at: view.contentOffset, in: view))
                return
            }
            didReachEnd = false
            let pageHeight = readingViewportHeight(for: view)
            autoPageProgress += pageHeight / CGFloat(secondsPerScreen) * CGFloat(elapsed)
            let revealedHeight = min(autoPageProgress, pageHeight)
            if let overlay = autoPageOverlay {
                overlay.frame = CGRect(
                    x: 0,
                    y: view.contentOffset.y,
                    width: view.bounds.width,
                    height: revealedHeight
                )
                overlay.layer.borderWidth = revealedHeight > 0 ? 0.5 : 0
            }
            guard autoPageProgress >= pageHeight, let target = autoPageTarget else { return }
            autoPageOverlay?.removeFromSuperview()
            autoPageOverlay = nil
            autoPageTarget = nil
            autoPageProgress = 0
            view.setContentOffset(CGPoint(x: 0, y: target), animated: false)
        }

        private func advanceEInkAutoRead(in view: UITextView, elapsed: CFTimeInterval) {
            eInkElapsed += elapsed
            guard eInkElapsed >= eInkPageInterval else { return }
            eInkElapsed = 0
            eInkPageInterval = secondsPerScreen
            let offsets = pageOffsets(for: view)
            let index = pageIndex(for: view, offsets: offsets)
            guard index + 1 < offsets.count else {
                guard !didReachEnd else { return }
                didReachEnd = true
                parent.onReachedEnd(contentCharacter(at: view.contentOffset, in: view))
                return
            }
            didReachEnd = false
            let target = offsets[index + 1]
            view.setContentOffset(CGPoint(x: 0, y: target), animated: false)
        }

        private func advanceAutoFlip(elapsed: CFTimeInterval) {
            // Hold the countdown while a turn animation is still settling so
            // the interval always measures a full resting page.
            guard !isTurningPage else { return }
            flipElapsed += elapsed
            guard flipElapsed >= autoFlipInterval else { return }
            turnPage(1)
        }

        @objc private func step(_ link: CADisplayLink) {
            defer { lastTimestamp = link.timestamp }
            guard isAutoReading || isAutoFlipping, !isAutoReadPaused, !isUserDragging, let view = textView else { return }
            guard lastTimestamp > 0 else { return }
            let elapsed = link.timestamp - lastTimestamp
            if isAutoFlipping {
                advanceAutoFlip(elapsed: elapsed)
                return
            }
            if parent.isEInkMode {
                advanceEInkAutoRead(in: view, elapsed: elapsed)
                return
            }
            if parent.pageAnimation != 3 {
                advancePagedAutoRead(in: view, elapsed: elapsed)
                return
            }
            let maximum = scrollLimits(for: view).maximum
            let next = view.contentOffset.y
                + readingViewportHeight(for: view) / CGFloat(secondsPerScreen) * CGFloat(elapsed)
            if next >= maximum - 0.5 {
                view.setContentOffset(CGPoint(x: 0, y: maximum), animated: false)
                guard !didReachEnd else { return }
                didReachEnd = true
                parent.onReachedEnd(contentCharacter(at: view.contentOffset, in: view))
            } else {
                didReachEnd = false
                view.setContentOffset(CGPoint(x: 0, y: next), animated: false)
            }
        }
    }
}

/// 仿真翻页动画器。
///
/// 用两张整页位图合成一次「纸张对折」动画：
/// - 底层 `destView`：目标页，按进度裁切出「已翻开」的一侧；
/// - `flatView`：当前页，只保留尚未被折走的部分；
/// - `flapView`：被折起半张纸的背面（纯纸色 + 渐变阴影 + 折痕线）。
///
/// 折线从书页一侧扫到另一侧，进度由 `CADisplayLink` 驱动并做缓动。
/// 全程只改位图与遮罩，live 文本视图保持静止，动画结束后再一次性把
/// `contentOffset` 落到目标页，因此不会再出现残影。
@MainActor
final class ReaderPageCurlAnimator {
    private let host: UITextView
    private let forward: Bool
    private let targetOffset: CGFloat
    private let duration: CFTimeInterval
    private let width: CGFloat
    private let height: CGFloat

    private let container = UIView()
    private let destView = UIImageView()
    private let flatView = UIImageView()
    private let destMask = CAShapeLayer()
    private let flatMask = CAShapeLayer()
    private let flapView = UIView()
    private let flapGradient = CAGradientLayer()
    private let foldLine = UIView()

    private var link: CADisplayLink?
    private var startTime: CFTimeInterval = 0
    private var didFinish = false
    private var onComplete: ((Bool) -> Void)?

    init?(
        host: UITextView,
        source: UIImage,
        destination: UIImage,
        forward: Bool,
        targetOffset: CGFloat,
        paperColor: UIColor,
        foldAccentColor: UIColor,
        duration: CFTimeInterval
    ) {
        let size = host.bounds.size
        guard size.width > 1, size.height > 1 else { return nil }
        self.host = host
        self.forward = forward
        self.targetOffset = targetOffset
        self.duration = max(duration, 0.01)
        self.width = size.width
        self.height = size.height

        container.frame = CGRect(x: 0, y: host.contentOffset.y, width: size.width, height: size.height)
        container.clipsToBounds = true
        container.isUserInteractionEnabled = false
        container.backgroundColor = .clear

        destView.image = destination
        destView.contentMode = .scaleToFill
        destView.frame = container.bounds
        destView.layer.mask = destMask
        destMask.frame = destView.bounds
        container.addSubview(destView)

        flatView.image = source
        flatView.contentMode = .scaleToFill
        flatView.frame = container.bounds
        flatView.layer.mask = flatMask
        flatMask.frame = flatView.bounds
        container.addSubview(flatView)

        for mask in [destMask, flatMask] {
            mask.fillColor = UIColor.black.cgColor
            mask.strokeColor = nil
            mask.actions = ["path": NSNull(), "position": NSNull(), "bounds": NSNull()]
        }

        flapView.backgroundColor = paperColor
        container.addSubview(flapView)

        flapGradient.startPoint = CGPoint(x: 0, y: 0.5)
        flapGradient.endPoint = CGPoint(x: 1, y: 0.5)
        if forward {
            flapGradient.colors = [
                UIColor.white.withAlphaComponent(0).cgColor,
                UIColor.black.withAlphaComponent(0.02).cgColor,
                UIColor.black.withAlphaComponent(0.20).cgColor
            ]
            flapGradient.locations = [0, 0.72, 1]
        } else {
            flapGradient.colors = [
                UIColor.black.withAlphaComponent(0.20).cgColor,
                UIColor.black.withAlphaComponent(0.02).cgColor,
                UIColor.white.withAlphaComponent(0).cgColor
            ]
            flapGradient.locations = [0, 0.28, 1]
        }
        flapView.layer.addSublayer(flapGradient)

        foldLine.backgroundColor = foldAccentColor.withAlphaComponent(0.14)
        foldLine.isUserInteractionEnabled = false
        container.addSubview(foldLine)

        host.addSubview(container)
        apply(progress: 0)
    }

    func start(completion: @escaping (Bool) -> Void) {
        onComplete = completion
        let displayLink = CADisplayLink(target: self, selector: #selector(step(_:)))
        displayLink.add(to: .main, forMode: .common)
        link = displayLink
        startTime = 0
    }

    func cancel() {
        finish(commit: false)
    }

    @objc private func step(_ displayLink: CADisplayLink) {
        if startTime == 0 {
            startTime = displayLink.timestamp
            return
        }
        let raw = (displayLink.timestamp - startTime) / duration
        let t = min(max(raw, 0), 1)
        apply(progress: Self.easeInOut(CGFloat(t)))
        if t >= 1 { finish(commit: true) }
    }

    private static func easeInOut(_ t: CGFloat) -> CGFloat {
        if t < 0.5 { return 2 * t * t }
        let v = -2 * t + 2
        return 1 - v * v / 2
    }

    private func apply(progress: CGFloat) {
        let p = min(max(progress, 0), 1)
        let fold = forward ? width * (1 - p) : width * p
        let f = min(max(fold, 0), width)

        let revealed: CGRect
        let remaining: CGRect
        let flap: CGRect
        if forward {
            revealed = CGRect(x: f, y: 0, width: max(width - f, 0), height: height)
            remaining = CGRect(x: 0, y: 0, width: f, height: height)
            let flapMin = max(0, 2 * f - width)
            flap = CGRect(x: flapMin, y: 0, width: max(f - flapMin, 0), height: height)
        } else {
            revealed = CGRect(x: 0, y: 0, width: f, height: height)
            remaining = CGRect(x: f, y: 0, width: max(width - f, 0), height: height)
            let flapMax = min(width, 2 * f)
            flap = CGRect(x: f, y: 0, width: max(flapMax - f, 0), height: height)
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        destMask.path = UIBezierPath(rect: revealed).cgPath
        flatMask.path = UIBezierPath(rect: remaining).cgPath
        flapView.frame = flap
        flapGradient.frame = flapView.bounds
        foldLine.frame = CGRect(x: f - 0.5, y: 0, width: 1, height: height)
        foldLine.isHidden = f <= 1 || f >= width - 1
        CATransaction.commit()
    }

    private func finish(commit: Bool) {
        guard !didFinish else { return }
        didFinish = true
        link?.invalidate()
        link = nil
        if commit {
            apply(progress: 1)
            if abs(host.contentOffset.y - targetOffset) > 0.5 {
                host.setContentOffset(CGPoint(x: 0, y: targetOffset), animated: false)
            }
        }
        container.removeFromSuperview()
        let completion = onComplete
        onComplete = nil
        completion?(commit)
    }
}
