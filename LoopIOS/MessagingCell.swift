//
//  MessagingCell.swift
//  Loop
//
//  Created by Ash Bhat on 11/3/24.
//

import UIKit
import PhotosUI
import SafariServices
import PDFKit
import QuickLook


/// Tap-callbacks from the inline image bubble. Set on every cell that
/// renders an image attachment so MessagingVC can save / regenerate /
/// open the full-screen viewer.
protocol MessagingCellImageDelegate: AnyObject {
    func messagingCellDidTapDownload(attachmentId: String)
    func messagingCellDidTapRetry(attachmentId: String)
    /// `sourceView` is the tapped attachment image view, handed up so the
    /// full-screen viewer can run a zoom transition out of (and back into)
    /// this exact bubble.
    func messagingCellDidTapImage(attachmentId: String, sourceView: UIView)
}

class MessagingCell: UITableViewCell {
    let profileImageView = UIImageView()
    let textView = UITextView()
    let animatingtextView = UITextView()
    var timer: Timer?

    /// Vertical stack used when the assistant message contains a markdown
    /// table. Holds alternating UITextViews (prose segments) and UIViews
    /// (rendered table grids). Hidden — and emptied — for plain messages
    /// so the existing single-text-view fast path is untouched.
    let richContentStack = UIStackView()
    private var richContentConstraints: [NSLayoutConstraint] = []

    let actionButton = UIButton()

    let shimmerLabel = ShimmerLabel()
    let modelLabel = UILabel()
    /// Spinner shown next to `modelLabel` while TTS is generating audio. Set
    /// via `setTTSStatus(_:)`. Hidden by default so user/system messages stay
    /// untouched.
    let ttsIndicator = UIActivityIndicatorView(style: .medium)

    // MARK: - Inline image attachment views (image_spec)
    let attachmentImageView = UIImageView()
    let attachmentSpinner = UIActivityIndicatorView(style: .large)
    let attachmentErrorLabel = UILabel()
    let downloadButton = UIButton(type: .system)
    let retryButton = UIButton(type: .system)
    weak var imageDelegate: MessagingCellImageDelegate?
    private var currentAttachmentId: String?
    /// Set by `applyFileAttachment` (user upload) so the tap handler can
    /// open a QuickLook preview directly instead of routing through the
    /// AI-generated image viewer delegate.
    private var currentAttachmentFileURL: URL?
    private var attachmentConstraints: [NSLayoutConstraint] = []
    /// Lazy single-instance tap recognizer so the cell can re-gate it via
    /// isEnabled across reuse instead of stacking new gestures each pass.
    private lazy var imageTapRecognizer: UITapGestureRecognizer = {
        let r = UITapGestureRecognizer(target: self, action: #selector(handleImageTap))
        r.numberOfTapsRequired = 1
        return r
    }()

    /// The "raw" model name (e.g. "GPT 5.5 Instant") last applied via
    /// `setData`. Kept around so `setTTSStatus(_:)` can append the
    /// "| 2.03s to audio" suffix without losing the base text on cell reuse.
    private var baseModelText: String?

    // Store constraints to avoid conflicts during cell reuse
    private var textViewConstraints: [NSLayoutConstraint] = []
    private var animatingTextViewConstraints: [NSLayoutConstraint] = []
    private var profileImageViewConstraints: [NSLayoutConstraint] = []
    private var shimmerLabelConstraints: [NSLayoutConstraint] = []
    private var modelLabelConstraints: [NSLayoutConstraint] = []
    
    
    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        self.setup()
    }
    
    func setup() {
        self.selectionStyle = .none

        // Enable link interaction. The text views are not editable but must be
        // selectable for iOS to deliver tap events to attributed-string links.
        textView.isSelectable = true
        textView.isEditable = false
        textView.delegate = self
        animatingtextView.isSelectable = true
        animatingtextView.isEditable = false
        animatingtextView.delegate = self

        richContentStack.translatesAutoresizingMaskIntoConstraints = false
        richContentStack.axis = .vertical
        richContentStack.alignment = .fill
        richContentStack.distribution = .fill
        richContentStack.spacing = 8
        richContentStack.isHidden = true
    }
    
    override func prepareForReuse() {
        super.prepareForReuse()

        // Invalidate any running timer
        timer?.invalidate()
        timer = nil

        // Hide all views instead of removing them for better performance
        profileImageView.isHidden = true
        textView.isHidden = true
        animatingtextView.isHidden = true
        actionButton.isHidden = true
        shimmerLabel.isHidden = true
        modelLabel.isHidden = true
        modelLabel.text = nil
        ttsIndicator.stopAnimating()
        ttsIndicator.isHidden = true
        baseModelText = nil

        // Image attachment cleanup — stop spinner, drop the bitmap so a
        // recycled cell doesn't briefly flash a stale image.
        attachmentSpinner.stopAnimating()
        attachmentSpinner.isHidden = true
        attachmentImageView.image = nil
        attachmentImageView.isHidden = true
        attachmentErrorLabel.isHidden = true
        attachmentErrorLabel.text = nil
        downloadButton.isHidden = true
        retryButton.isHidden = true
        currentAttachmentId = nil
        currentAttachmentFileURL = nil
        NSLayoutConstraint.deactivate(attachmentConstraints)
        attachmentConstraints.removeAll()
        
        // Reset view states
        textView.alpha = 1.0
        animatingtextView.alpha = 1.0
        textView.attributedText = nil
        animatingtextView.attributedText = nil
        textView.text = nil
        animatingtextView.text = nil
        
        // Reset text view properties
        textView.textContainerInset = .zero
        textView.layer.cornerRadius = 0
        textView.layer.borderWidth = 0
        textView.layer.borderColor = UIColor.clear.cgColor

        // Tear down rich-content (table) views so the next message starts
        // from a clean slate. The stack itself is reused.
        NSLayoutConstraint.deactivate(richContentConstraints)
        richContentConstraints.removeAll()
        richContentStack.arrangedSubviews.forEach {
            richContentStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        richContentStack.isHidden = true
    }
    
    private func clearAllConstraints() {
        // Deactivate all stored constraints
        NSLayoutConstraint.deactivate(textViewConstraints)
        NSLayoutConstraint.deactivate(animatingTextViewConstraints)
        NSLayoutConstraint.deactivate(profileImageViewConstraints)
        NSLayoutConstraint.deactivate(shimmerLabelConstraints)
        NSLayoutConstraint.deactivate(modelLabelConstraints)

        // Clear the arrays
        textViewConstraints.removeAll()
        animatingTextViewConstraints.removeAll()
        profileImageViewConstraints.removeAll()
        shimmerLabelConstraints.removeAll()
        modelLabelConstraints.removeAll()
    }
    
    func setAnimationState(state: AIState) {
        // Clear existing constraints
        clearAllConstraints()

        // Ensure all views are added to content view (only once)
        if profileImageView.superview == nil {
            self.addViews(views: [profileImageView, textView, animatingtextView, actionButton, shimmerLabel, modelLabel, ttsIndicator])
        }

        // Show animation views, hide others. Profile image is gone for the
        // assistant — the nav-bar AvatarView is the new single visual anchor
        // for "the AI is here," so cells just left-align their copy.
        profileImageView.isHidden = true
        textView.isHidden = true
        animatingtextView.isHidden = true
        actionButton.isHidden = true
        shimmerLabel.isHidden = false
        modelLabel.isHidden = true

        shimmerLabelConstraints = [
            shimmerLabel.leadingAnchor.constraint(equalTo: self.contentView.leadingAnchor, constant: 20),
            shimmerLabel.trailingAnchor.constraint(lessThanOrEqualTo: self.contentView.trailingAnchor, constant: -20),
            shimmerLabel.topAnchor.constraint(equalTo: self.contentView.topAnchor, constant: 20),
            self.contentView.bottomAnchor.constraint(greaterThanOrEqualTo: shimmerLabel.bottomAnchor, constant: 20),
        ]

        NSLayoutConstraint.activate(shimmerLabelConstraints)

        shimmerLabel.font = UIFont.preferredFont(forTextStyle: .body)
        shimmerLabel.text = state.displayText
        shimmerLabel.shimmerColor = .tertiarySystemBackground
        shimmerLabel.textColor = .label
        shimmerLabel.numberOfLines = 0
        shimmerLabel.lineBreakMode = .byWordWrapping

        
    }
    
    func setData(data: MessageStruct, shouldAnimate: Bool) {
        // Clear existing constraints
        clearAllConstraints()

        // Ensure all views are added to content view (only once)
        if profileImageView.superview == nil {
            self.addViews(views: [profileImageView, textView, animatingtextView, actionButton, shimmerLabel, modelLabel, ttsIndicator])
        }
        if attachmentImageView.superview == nil {
            self.addViews(views: [attachmentImageView, attachmentSpinner, attachmentErrorLabel, downloadButton, retryButton])
        }

        // Inline image attachment (image_spec) takes a separate code path so
        // we don't need to interleave it with text-bubble layout.
        if let attachment = data.imageAttachment {
            applyImageAttachment(attachment, modelLabelText: data.model)
            return
        }

        // User-uploaded file (image or PDF). Renders on the user side
        // (right-aligned) above any accompanying text.
        if let fileAttachment = data.fileAttachment {
            applyFileAttachment(fileAttachment, accompanyingText: data.content, role: data.role)
            return
        }

        if data.role == "assistant" {
            // Markdown-table fast branch: when the response contains a GFM
            // table, lay it out as a real UIStackView grid instead of
            // routing through the single-text-view + animation path.
            // Streaming animation is skipped here because table responses
            // are typically already complete by the time they render.
            if MarkdownSegmenter.containsTable(in: data.content) {
                applyRichContent(data: data)
                return
            }

            // Show assistant views, hide user views. The profile image is
            // gone — the nav-bar AvatarView covers the visual identity, so
            // assistant text just left-aligns to the cell edge.
            profileImageView.isHidden = true
            textView.isHidden = false
            animatingtextView.isHidden = false
            actionButton.isHidden = true
            shimmerLabel.isHidden = true
            modelLabel.isHidden = false

            // Text view: left-aligned, leaves room on the right for any
            // trailing UI to grow without crowding.
            textViewConstraints = [
                textView.leadingAnchor.constraint(equalTo: self.contentView.leadingAnchor, constant: 20),
                textView.topAnchor.constraint(equalTo: self.contentView.topAnchor, constant: 12),
                textView.widthAnchor.constraint(lessThanOrEqualTo: self.contentView.widthAnchor, multiplier: 1.0, constant: -40)
            ]

            animatingTextViewConstraints = [
                animatingtextView.leadingAnchor.constraint(equalTo: textView.leadingAnchor, constant: 0),
                animatingtextView.topAnchor.constraint(equalTo: textView.topAnchor, constant: 0),
                animatingtextView.trailingAnchor.constraint(equalTo: textView.trailingAnchor, constant: 0),
                animatingtextView.bottomAnchor.constraint(equalTo: textView.bottomAnchor, constant: 0)
            ]

            // Model label sits below the message bubble; drives the cell's bottom.
            // The TTS indicator pins to the trailing edge of modelLabel and is
            // hidden until setTTSStatus(_:) flips it on.
            modelLabelConstraints = [
                modelLabel.leadingAnchor.constraint(equalTo: textView.leadingAnchor),
                modelLabel.topAnchor.constraint(equalTo: textView.bottomAnchor, constant: 4),
                self.contentView.bottomAnchor.constraint(greaterThanOrEqualTo: modelLabel.bottomAnchor, constant: 10),
                ttsIndicator.leadingAnchor.constraint(equalTo: modelLabel.trailingAnchor, constant: 6),
                ttsIndicator.centerYAnchor.constraint(equalTo: modelLabel.centerYAnchor),
                ttsIndicator.widthAnchor.constraint(equalToConstant: 12),
                ttsIndicator.heightAnchor.constraint(equalToConstant: 12),
                ttsIndicator.trailingAnchor.constraint(lessThanOrEqualTo: textView.trailingAnchor)
            ]

            NSLayoutConstraint.activate(textViewConstraints)
            NSLayoutConstraint.activate(animatingTextViewConstraints)
            NSLayoutConstraint.activate(modelLabelConstraints)

            textView.textContainerInset = .zero
            textView.textContainer.lineFragmentPadding = 0
            textView.isScrollEnabled = false
            textView.isEditable = false
            textView.textContainer.maximumNumberOfLines = 0
            textView.textContainer.widthTracksTextView = true
            
            animatingtextView.textContainerInset = .zero
            animatingtextView.textContainer.lineFragmentPadding = 0
            animatingtextView.isScrollEnabled = false
            animatingtextView.isEditable = false
            animatingtextView.textContainer.maximumNumberOfLines = 0
            animatingtextView.textContainer.widthTracksTextView = true
            
            
            textView.attributedText = self.attributedString(from: data.content)
            textView.textColor = .label
            textView.font = UIFont.preferredFont(forTextStyle: .body)
            textView.alpha = 0.1
            textView.layer.borderWidth = 0
            textView.layer.borderColor = UIColor.clear.cgColor
            
            animatingtextView.alpha = 1
            animatingtextView.textColor = .label
//            animatingtextView.text = data.content
            animatingtextView.font = UIFont.preferredFont(forTextStyle: .body)

            baseModelText = data.model
            modelLabel.text = data.model
            modelLabel.textColor = .secondaryLabel
            modelLabel.font = UIFont.preferredFont(forTextStyle: .caption2)
            modelLabel.numberOfLines = 1
            ttsIndicator.color = .secondaryLabel
            ttsIndicator.hidesWhenStopped = true
            ttsIndicator.stopAnimating()
            ttsIndicator.isHidden = true

            // Disable typing animation for better scroll performance
            if shouldAnimate {
                animateText(content: data.content)
            } else {
                textView.alpha = 1.0
                animatingtextView.attributedText = self.attributedString(from: data.content)
            }
            
            // Update content size after setting text
            // updateContentSize() // Disabled for better scroll performance
        }
        else {
            // Show user views, hide assistant views
            profileImageView.isHidden = true
            textView.isHidden = false
            animatingtextView.isHidden = true
            actionButton.isHidden = true
            shimmerLabel.isHidden = true
            modelLabel.isHidden = true
            
            // Store and activate text view constraints for user messages
            textViewConstraints = [
                textView.trailingAnchor.constraint(equalTo: self.contentView.trailingAnchor, constant: -10),
                textView.topAnchor.constraint(equalTo: self.contentView.topAnchor, constant: 6),
                textView.widthAnchor.constraint(lessThanOrEqualTo: self.contentView.widthAnchor, multiplier: 0.8, constant: -40),
                textView.bottomAnchor.constraint(equalTo: self.contentView.bottomAnchor, constant: -6)
            ]
            
            NSLayoutConstraint.activate(textViewConstraints)
            animatingtextView.alpha = 0
            textView.alpha = 1
            textView.textContainerInset = .init(top: 8, left: 10, bottom: 8, right: 10)
            textView.textContainer.lineFragmentPadding = 0
            textView.textContainer.maximumNumberOfLines = 0
            textView.textContainer.widthTracksTextView = true
            textView.layer.cornerRadius = 10
            textView.layer.borderWidth = 2
            textView.layer.borderColor = UIColor.systemFill.cgColor
            textView.font = UIFont.preferredFont(forTextStyle: .body)
            textView.isScrollEnabled = false
            textView.isEditable = false
            textView.attributedText = self.attributedString(from: data.content)
            animatingtextView.isEditable = false
            
            // Update content size after setting text
            // updateContentSize() // Disabled for better scroll performance
        }
    }

    /// TTS audio-generation status applied on top of `modelLabel`. The cell
    /// is reused, so callers should reapply this every time the cell becomes
    /// visible (typically from `cellForRowAt`).
    enum TTSStatus {
        /// Audio request is in flight. Spinner shown next to the model name.
        case generating
        /// Audio finished generating. Appends "| 2.03s to audio" to the label.
        case ready(seconds: TimeInterval)
        /// No TTS happening for this message — restore the bare model name.
        case none
    }

    func setTTSStatus(_ status: TTSStatus) {
        let base = baseModelText ?? modelLabel.text ?? ""
        switch status {
        case .none:
            modelLabel.text = base
            ttsIndicator.stopAnimating()
            ttsIndicator.isHidden = true
        case .generating:
            modelLabel.text = base
            ttsIndicator.isHidden = false
            ttsIndicator.startAnimating()
        case .ready(let seconds):
            let formatted = String(format: "%.2fs", seconds)
            modelLabel.text = base.isEmpty ? "\(formatted) to audio"
                                          : "\(base) | \(formatted) to audio"
            ttsIndicator.stopAnimating()
            ttsIndicator.isHidden = true
        }
    }

    private func animateText(content: String) {
        animatingtextView.text = "" // Start with an empty string
        let words = content.split(separator: " ") // Split content into words
        var currentIndex = 0
        
        // Invalidate any previous timer before starting a new one
        timer?.invalidate()
        
        
        let impactGenerator = UIImpactFeedbackGenerator(style: .light, view: self.textView)
//        impactGenerator.prepare()
        // Run a timer on a background queue to minimize UI thread congestion
        
        var textCache: String = ""
        timer = Timer.scheduledTimer(withTimeInterval: 0.01, repeats: true) { [weak self] timer in
            guard let self = self else {
                timer.invalidate()
                return
            }
            
            if currentIndex < words.count {
                let word = words[currentIndex]
                
                let newText = (textCache) + (self.animatingtextView.text?.isEmpty ?? true ? "" : " ") + word
                textCache = newText
                currentIndex += 1
                
                // Batch UI updates to main thread for smoother rendering
                DispatchQueue.main.async {
                    self.animatingtextView.attributedText = self.attributedString(from: newText)
//                    impactGenerator.impactOccurred()
                    
                    // Update content size during animation
                    self.updateContentSize()
                }
            } else {
                timer.invalidate()
            }
        }
        
        // Ensure the timer runs in the common run loop mode to prevent interruptions
        RunLoop.main.add(timer!, forMode: .common)
    }
    
    private func updateContentSize() {
        // Force layout update to ensure proper content size calculation
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            
            // Ensure text views have proper content size
            self.textView.invalidateIntrinsicContentSize()
            self.animatingtextView.invalidateIntrinsicContentSize()
            
            // Force layout update
            self.contentView.setNeedsLayout()
            self.contentView.layoutIfNeeded()
            
            // Update table view cell height if needed
            if let tableView = self.superview as? UITableView {
                tableView.beginUpdates()
                tableView.endUpdates()
            }
        }
    }
    
    override func systemLayoutSizeFitting(_ targetSize: CGSize, withHorizontalFittingPriority horizontalFittingPriority: UILayoutPriority, verticalFittingPriority: UILayoutPriority) -> CGSize {
        // Force layout to get accurate size
        self.contentView.setNeedsLayout()
        self.contentView.layoutIfNeeded()
        
        // Calculate the size based on content
        let size = self.contentView.systemLayoutSizeFitting(targetSize, withHorizontalFittingPriority: horizontalFittingPriority, verticalFittingPriority: verticalFittingPriority)
        
        // Only apply minimum height for assistant cells (those with profile image)
        // Check if profileImageView is in the view hierarchy
        let hasProfileImage = profileImageView.superview != nil
        
        if hasProfileImage {
            // Use the calculated size - don't force a minimum height that creates extra padding
            // The contentView's profileImageView constraint already ensures proper spacing
            return size
        } else {
            // For user cells, use a smaller minimum height for more compact single-line messages
            let minimumHeight: CGFloat = 40
            return CGSize(width: size.width, height: max(size.height, minimumHeight))
        }
    }
    
    func addViews(views: [UIView]) {
        for view in views {
            view.translatesAutoresizingMaskIntoConstraints = false
            self.contentView.addSubview(view)
        }
    }
    
    func attributedString(from text: String) -> NSAttributedString {
        let fullRange = NSRange(location: 0, length: text.count)
        let attributedString = NSMutableAttributedString(
            string: text,
            attributes: [
                NSAttributedString.Key.font: UIFont.preferredFont(forTextStyle: .body),
                NSAttributedString.Key.foregroundColor: UIColor.label
            ]
        )

        // Regular expression to find headers that start with '#'
        let headerRegexPattern = "^(#{1,6})\\s*(.*?)$"

        do {
            let headerRegex = try NSRegularExpression(pattern: headerRegexPattern, options: [.anchorsMatchLines])
            let headerMatches = headerRegex.matches(in: text, options: [], range: fullRange)

            // Iterate over each match and apply header style
            for match in headerMatches.reversed() {
                let headerLevel = match.range(at: 1).length // Number of '#' indicates the header level
                if let headerContentRange = Range(match.range(at: 2), in: text) {
                    let headerText = String(text[headerContentRange])
                    let headerFont = UIFont.boldSystemFont(ofSize: UIFont.preferredFont(forTextStyle: .title3).pointSize - CGFloat(headerLevel - 1) * 2)
                    let headerAttributedString = NSAttributedString(
                        string: headerText,
                        attributes: [
                            NSAttributedString.Key.font: headerFont,
                            NSAttributedString.Key.foregroundColor: UIColor.label
                        ]
                    )

                    // Replace the range in the mutable attributed string
                    attributedString.replaceCharacters(in: match.range, with: headerAttributedString)
                }
            }

            // Regular expression to find text within "**" for bold styling
            let boldRegexPattern = "\\*\\*(.*?)\\*\\*"
            let boldRegex = try NSRegularExpression(pattern: boldRegexPattern, options: [])
            let boldMatches = boldRegex.matches(in: attributedString.string, options: [], range: NSRange(location: 0, length: attributedString.length))

            // Iterate over each match and apply bold style
            for match in boldMatches.reversed() {
                if let boldRange = Range(match.range(at: 1), in: attributedString.string) {
                    let boldText = String(attributedString.string[boldRange])
                    let boldAttributedString = NSAttributedString(
                        string: boldText,
                        attributes: [
                            NSAttributedString.Key.font: UIFont.boldSystemFont(ofSize: UIFont.preferredFont(forTextStyle: .body).pointSize),
                            NSAttributedString.Key.foregroundColor: UIColor.label
                        ]
                    )

                    // Replace the range in the mutable attributed string
                    attributedString.replaceCharacters(in: match.range, with: boldAttributedString)
                }
            }

            // Markdown links: [text](url). Replace the whole match with `text`,
            // preserving any existing inline attributes (bold from above, etc),
            // then layer on the link/blue/underline attributes.
            let linkRegex = try NSRegularExpression(pattern: #"\[([^\]]+)\]\(([^)\s]+)\)"#, options: [])
            let linkMatches = linkRegex.matches(in: attributedString.string,
                                                options: [],
                                                range: NSRange(location: 0, length: attributedString.length))
            for match in linkMatches.reversed() {
                guard match.numberOfRanges == 3 else { continue }
                let textRange = match.range(at: 1)
                let urlRange = match.range(at: 2)
                let urlString = (attributedString.string as NSString).substring(with: urlRange)
                guard let url = URL(string: urlString) else { continue }

                let inner = attributedString.attributedSubstring(from: textRange).mutableCopy() as! NSMutableAttributedString
                let innerRange = NSRange(location: 0, length: inner.length)
                inner.addAttribute(.link, value: url, range: innerRange)
                inner.addAttribute(.foregroundColor, value: UIColor.systemBlue, range: innerRange)
                inner.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: innerRange)

                attributedString.replaceCharacters(in: match.range, with: inner)
            }

            // Filesystem paths → tappable file name. Vault-relative paths
            // become obsidian:// links, others become file://. Runs before
            // the NSDataDetector pass so a path never gets reinterpreted as
            // a generic URL.
            let pathRegex = try NSRegularExpression(pattern: FilePathLinkifier.pattern, options: [])
            let pathMatches = pathRegex.matches(in: attributedString.string,
                                                options: [],
                                                range: NSRange(location: 0, length: attributedString.length))
            for match in pathMatches.reversed() {
                if attributedString.attribute(.link,
                                              at: match.range.location,
                                              effectiveRange: nil) != nil {
                    continue
                }
                let raw = (attributedString.string as NSString).substring(with: match.range)
                guard let resolved = FilePathLinkifier.resolve(raw) else { continue }

                let replacement = NSMutableAttributedString(string: resolved.displayName, attributes: [
                    .font: UIFont.preferredFont(forTextStyle: .body),
                    .foregroundColor: UIColor.systemBlue,
                ])
                let r = NSRange(location: 0, length: replacement.length)
                replacement.addAttribute(.link, value: resolved.url, range: r)
                replacement.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: r)
                attributedString.replaceCharacters(in: match.range, with: replacement)
            }

            // Bare URL detection — turn anything that already looks like a URL
            // into a tappable link. NSDataDetector handles "http(s)://…" plus
            // common tlds. Skip ranges that already carry a .link from the
            // markdown pass above so we don't double-style.
            let detector = try NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
            let urlMatches = detector.matches(in: attributedString.string,
                                              options: [],
                                              range: NSRange(location: 0, length: attributedString.length))
            for match in urlMatches {
                guard let url = match.url else { continue }
                if attributedString.attribute(.link,
                                              at: match.range.location,
                                              effectiveRange: nil) != nil {
                    continue
                }
                attributedString.addAttribute(.link, value: url, range: match.range)
                attributedString.addAttribute(.foregroundColor, value: UIColor.systemBlue, range: match.range)
                attributedString.addAttribute(.underlineStyle,
                                              value: NSUnderlineStyle.single.rawValue,
                                              range: match.range)
            }
        } catch {
            print("Error creating regex: \(error)")
        }

        return attributedString
    }

    // MARK: - Rich content (markdown tables)

    /// Build the assistant bubble as a vertical stack of prose UITextViews
    /// and grid UIViews when the response contains a GFM table. Mirrors
    /// the layout of the plain-text branch (left-aligned, model label
    /// underneath) but swaps the single text view for `richContentStack`.
    private func applyRichContent(data: MessageStruct) {
        profileImageView.isHidden = true
        textView.isHidden = true
        animatingtextView.isHidden = true
        actionButton.isHidden = true
        shimmerLabel.isHidden = true
        modelLabel.isHidden = false

        // Idempotent re-entry: drop any rich state from a prior setData
        // call so we never stack duplicate constraints / subviews if the
        // cell is reconfigured without a prepareForReuse pass in between.
        NSLayoutConstraint.deactivate(richContentConstraints)
        richContentConstraints.removeAll()
        richContentStack.arrangedSubviews.forEach {
            richContentStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }

        if richContentStack.superview == nil {
            richContentStack.translatesAutoresizingMaskIntoConstraints = false
            self.contentView.addSubview(richContentStack)
        }
        richContentStack.isHidden = false

        // Populate the stack with one subview per parsed segment.
        for segment in MarkdownSegmenter.segments(from: data.content) {
            switch segment {
            case .text(let prose):
                let tv = makeProseTextView(text: prose)
                richContentStack.addArrangedSubview(tv)
            case .table(let table):
                let view = makeTableView(table: table)
                richContentStack.addArrangedSubview(view)
            }
        }

        // Pin the rich stack to the full available content width (not
        // lessThanOrEqual): without an enforced width the UIStackView
        // shrinks to its arranged-subviews' intrinsic widths, which
        // squishes a grid of short cells like ("ash", "founder") down to
        // an unreadable thumbnail. Tables need to occupy the bubble.
        richContentConstraints = [
            richContentStack.leadingAnchor.constraint(equalTo: self.contentView.leadingAnchor, constant: 20),
            richContentStack.trailingAnchor.constraint(equalTo: self.contentView.trailingAnchor, constant: -20),
            richContentStack.topAnchor.constraint(equalTo: self.contentView.topAnchor, constant: 12),
        ]
        NSLayoutConstraint.activate(richContentConstraints)

        // Model label / TTS indicator hang off the bottom of the rich stack
        // instead of the now-hidden text view.
        modelLabelConstraints = [
            modelLabel.leadingAnchor.constraint(equalTo: richContentStack.leadingAnchor),
            modelLabel.topAnchor.constraint(equalTo: richContentStack.bottomAnchor, constant: 4),
            self.contentView.bottomAnchor.constraint(greaterThanOrEqualTo: modelLabel.bottomAnchor, constant: 10),
            ttsIndicator.leadingAnchor.constraint(equalTo: modelLabel.trailingAnchor, constant: 6),
            ttsIndicator.centerYAnchor.constraint(equalTo: modelLabel.centerYAnchor),
            ttsIndicator.widthAnchor.constraint(equalToConstant: 12),
            ttsIndicator.heightAnchor.constraint(equalToConstant: 12),
            ttsIndicator.trailingAnchor.constraint(lessThanOrEqualTo: richContentStack.trailingAnchor),
        ]
        NSLayoutConstraint.activate(modelLabelConstraints)

        baseModelText = data.model
        modelLabel.text = data.model
        modelLabel.textColor = .secondaryLabel
        modelLabel.font = UIFont.preferredFont(forTextStyle: .caption2)
        modelLabel.numberOfLines = 1
        ttsIndicator.color = .secondaryLabel
        ttsIndicator.hidesWhenStopped = true
        ttsIndicator.stopAnimating()
        ttsIndicator.isHidden = true
    }

    /// A non-scrolling UITextView styled like the existing prose bubble.
    /// Re-uses `attributedString(from:)` so bold/italic/links/paths render
    /// identically to plain messages.
    private func makeProseTextView(text: String) -> UITextView {
        let tv = UITextView()
        tv.translatesAutoresizingMaskIntoConstraints = false
        tv.isScrollEnabled = false
        tv.isEditable = false
        tv.isSelectable = true
        tv.backgroundColor = .clear
        tv.textContainerInset = .zero
        tv.textContainer.lineFragmentPadding = 0
        tv.delegate = self
        tv.font = UIFont.preferredFont(forTextStyle: .body)
        tv.textColor = .label
        tv.attributedText = attributedString(from: text)
        return tv
    }

    /// Build a UIStackView grid for `table`. Rows are full-width with
    /// equal-width columns; header is bold on a tinted background; body
    /// rows alternate fill for readability. Borders and dividers use
    /// `.separator` so dark mode looks right out of the box.
    private func makeTableView(table: MarkdownTable) -> UIView {
        // AdaptiveBorderView re-resolves layer.borderColor on appearance
        // changes — UIView.backgroundColor handles that itself for dynamic
        // UIColors, but CGColors on CALayer don't, and the border would
        // otherwise stay frozen at whatever mode was active when the
        // table was first built.
        let container = AdaptiveBorderView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.layer.cornerRadius = 8
        container.adaptiveBorderColor = UIColor.separator
        container.layer.borderWidth = 0.5
        container.layer.masksToBounds = true
        container.backgroundColor = UIColor.secondarySystemBackground

        let vstack = UIStackView()
        vstack.translatesAutoresizingMaskIntoConstraints = false
        vstack.axis = .vertical
        vstack.alignment = .fill
        vstack.distribution = .fill
        vstack.spacing = 0
        container.addSubview(vstack)
        NSLayoutConstraint.activate([
            vstack.topAnchor.constraint(equalTo: container.topAnchor),
            vstack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            vstack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            vstack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])

        vstack.addArrangedSubview(
            makeTableRow(cells: table.headers,
                         alignments: table.alignments,
                         isHeader: true,
                         altBackground: false))

        for (i, row) in table.rows.enumerated() {
            vstack.addArrangedSubview(makeHairlineDivider())
            vstack.addArrangedSubview(
                makeTableRow(cells: row,
                             alignments: table.alignments,
                             isHeader: false,
                             altBackground: i.isMultiple(of: 2) == false))
        }

        return container
    }

    private func makeHairlineDivider() -> UIView {
        let v = UIView()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.backgroundColor = UIColor.separator
        v.heightAnchor.constraint(equalToConstant: 0.5).isActive = true
        return v
    }

    private func makeTableRow(cells: [String],
                              alignments: [MarkdownColumnAlignment],
                              isHeader: Bool,
                              altBackground: Bool) -> UIView {
        let row = UIView()
        row.translatesAutoresizingMaskIntoConstraints = false
        if isHeader {
            row.backgroundColor = UIColor.tertiarySystemBackground
        } else if altBackground {
            row.backgroundColor = UIColor.systemBackground.withAlphaComponent(0.5)
        } else {
            row.backgroundColor = .clear
        }

        let hstack = UIStackView()
        hstack.translatesAutoresizingMaskIntoConstraints = false
        hstack.axis = .horizontal
        hstack.alignment = .fill
        hstack.distribution = .fillEqually
        hstack.spacing = 0
        row.addSubview(hstack)
        NSLayoutConstraint.activate([
            hstack.topAnchor.constraint(equalTo: row.topAnchor),
            hstack.bottomAnchor.constraint(equalTo: row.bottomAnchor),
            hstack.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            hstack.trailingAnchor.constraint(equalTo: row.trailingAnchor),
        ])

        // Column dividers go *inside* each non-leading cell rather than
        // as arranged subviews of `hstack`. `.fillEqually` requires every
        // arranged subview to share width — a 0.5pt divider sitting in
        // the line-up either gets stretched (breaking the divider) or
        // wins its own width (breaking equal-column sizing), producing
        // the squished-column layout we hit before.
        for (i, cellText) in cells.enumerated() {
            let alignment = i < alignments.count ? alignments[i] : .left
            let cellView = makeTableCell(text: cellText,
                                          alignment: alignment,
                                          isHeader: isHeader,
                                          leadingDivider: i > 0)
            hstack.addArrangedSubview(cellView)
        }

        return row
    }

    private func makeTableCell(text: String,
                                alignment: MarkdownColumnAlignment,
                                isHeader: Bool,
                                leadingDivider: Bool) -> UIView {
        let container = UIView()
        container.translatesAutoresizingMaskIntoConstraints = false

        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.numberOfLines = 0
        label.lineBreakMode = .byWordWrapping
        // Let `.fillEqually` win the width sizing battle. UILabel hugs
        // its content by default, which can fight an equal-width row
        // when one cell's text is much shorter than the rest.
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let base = UIFont.preferredFont(forTextStyle: .subheadline)
        label.font = isHeader
            ? UIFont.systemFont(ofSize: base.pointSize, weight: .semibold)
            : base
        label.textColor = .label
        // Inline marks (bold/italic/links) inside cells reuse the same
        // renderer the surrounding prose uses, so styling stays consistent.
        // UILabel ignores `textAlignment` when `attributedText` is set, so
        // the alignment is folded into the attributed string via a
        // paragraph style applied over the full range.
        let attributed = NSMutableAttributedString(attributedString: attributedString(from: text))
        let paragraph = NSMutableParagraphStyle()
        switch alignment {
        case .left:   paragraph.alignment = .left
        case .center: paragraph.alignment = .center
        case .right:  paragraph.alignment = .right
        }
        paragraph.lineBreakMode = .byWordWrapping
        attributed.addAttribute(.paragraphStyle,
                                value: paragraph,
                                range: NSRange(location: 0, length: attributed.length))
        label.attributedText = attributed

        container.addSubview(label)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: container.topAnchor, constant: 6),
            label.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -6),
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
        ])

        if leadingDivider {
            let line = UIView()
            line.translatesAutoresizingMaskIntoConstraints = false
            line.backgroundColor = UIColor.separator
            container.addSubview(line)
            NSLayoutConstraint.activate([
                line.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                line.topAnchor.constraint(equalTo: container.topAnchor),
                line.bottomAnchor.constraint(equalTo: container.bottomAnchor),
                line.widthAnchor.constraint(equalToConstant: 0.5),
            ])
        }

        return container
    }

    // MARK: - Inline image attachment rendering (image_spec)

    /// Lay out an inline-image bubble on the assistant's avatar row. Three
    /// visual states drive button visibility + center content:
    /// - .generating: spinner over a placeholder rect, no buttons
    /// - .ready:      image filled, download + retry buttons below
    /// - .failed:     error label centered, retry button below
    private func applyImageAttachment(_ attachment: ImageAttachment,
                                       modelLabelText: String) {
        currentAttachmentId = attachment.id

        // Profile image is gone — the bubble left-aligns to the cell edge,
        // matching the text branch above.
        profileImageView.isHidden = true
        textView.isHidden = true
        animatingtextView.isHidden = true
        actionButton.isHidden = true
        shimmerLabel.isHidden = true
        modelLabel.isHidden = false

        attachmentImageView.isHidden = false
        attachmentImageView.translatesAutoresizingMaskIntoConstraints = false
        attachmentImageView.contentMode = .scaleAspectFill
        attachmentImageView.clipsToBounds = true
        attachmentImageView.layer.cornerRadius = 14
        attachmentImageView.layer.borderWidth = 1
        attachmentImageView.layer.borderColor = UIColor.systemFill.cgColor
        attachmentImageView.backgroundColor = UIColor.secondarySystemBackground

        // Tap-to-zoom: install once (lazy gesture is idempotent per instance,
        // and addGestureRecognizer is a no-op if already attached). Gating on
        // .ready avoids opening a viewer for an empty placeholder or error
        // bubble where there's nothing to show.
        attachmentImageView.isUserInteractionEnabled = (attachment.status == .ready)
        if imageTapRecognizer.view !== attachmentImageView {
            attachmentImageView.addGestureRecognizer(imageTapRecognizer)
        }
        imageTapRecognizer.isEnabled = (attachment.status == .ready)

        attachmentSpinner.translatesAutoresizingMaskIntoConstraints = false
        attachmentSpinner.color = .secondaryLabel
        attachmentSpinner.hidesWhenStopped = true

        attachmentErrorLabel.translatesAutoresizingMaskIntoConstraints = false
        attachmentErrorLabel.font = UIFont.preferredFont(forTextStyle: .footnote)
        attachmentErrorLabel.textColor = .secondaryLabel
        attachmentErrorLabel.numberOfLines = 0
        attachmentErrorLabel.textAlignment = .center

        // Configure buttons (idempotent — safe to re-run on cell reuse).
        configureRoundButton(downloadButton,
                             systemImage: "arrow.down.circle",
                             accessibility: "Save to Photos",
                             action: #selector(handleDownloadTap))
        configureRoundButton(retryButton,
                             systemImage: "arrow.clockwise.circle",
                             accessibility: "Generate again",
                             action: #selector(handleRetryTap))

        // Image bubble: fixed 240×240 inline. Compact enough that two iterations
        // fit on screen; large enough to see the result without tapping in.
        let imageSide: CGFloat = 240
        attachmentConstraints = [
            attachmentImageView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            attachmentImageView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 12),
            attachmentImageView.widthAnchor.constraint(equalToConstant: imageSide),
            attachmentImageView.heightAnchor.constraint(equalToConstant: imageSide),

            attachmentSpinner.centerXAnchor.constraint(equalTo: attachmentImageView.centerXAnchor),
            attachmentSpinner.centerYAnchor.constraint(equalTo: attachmentImageView.centerYAnchor),

            attachmentErrorLabel.leadingAnchor.constraint(equalTo: attachmentImageView.leadingAnchor, constant: 12),
            attachmentErrorLabel.trailingAnchor.constraint(equalTo: attachmentImageView.trailingAnchor, constant: -12),
            attachmentErrorLabel.centerYAnchor.constraint(equalTo: attachmentImageView.centerYAnchor),

            downloadButton.leadingAnchor.constraint(equalTo: attachmentImageView.leadingAnchor),
            downloadButton.topAnchor.constraint(equalTo: attachmentImageView.bottomAnchor, constant: 8),
            downloadButton.widthAnchor.constraint(equalToConstant: 32),
            downloadButton.heightAnchor.constraint(equalToConstant: 32),

            retryButton.leadingAnchor.constraint(equalTo: downloadButton.trailingAnchor, constant: 8),
            retryButton.centerYAnchor.constraint(equalTo: downloadButton.centerYAnchor),
            retryButton.widthAnchor.constraint(equalToConstant: 32),
            retryButton.heightAnchor.constraint(equalToConstant: 32),

            modelLabel.leadingAnchor.constraint(equalTo: attachmentImageView.leadingAnchor),
            modelLabel.topAnchor.constraint(equalTo: downloadButton.bottomAnchor, constant: 6),
            contentView.bottomAnchor.constraint(greaterThanOrEqualTo: modelLabel.bottomAnchor, constant: 12),
        ]
        NSLayoutConstraint.activate(attachmentConstraints)

        // State-specific UI.
        switch attachment.status {
        case .generating:
            attachmentImageView.image = nil
            attachmentSpinner.isHidden = false
            attachmentSpinner.startAnimating()
            attachmentErrorLabel.isHidden = true
            downloadButton.isHidden = true
            retryButton.isHidden = true
        case .ready:
            attachmentSpinner.stopAnimating()
            attachmentSpinner.isHidden = true
            attachmentErrorLabel.isHidden = true
            if let url = attachment.fileURL,
               let data = try? Data(contentsOf: url),
               let image = UIImage(data: data) {
                attachmentImageView.image = image
            }
            downloadButton.isHidden = false
            retryButton.isHidden = false
        case .failed:
            attachmentImageView.image = nil
            attachmentSpinner.stopAnimating()
            attachmentSpinner.isHidden = true
            attachmentErrorLabel.isHidden = false
            attachmentErrorLabel.text = attachment.failureReason ?? "Image generation failed."
            downloadButton.isHidden = true
            retryButton.isHidden = false
        }

        // Model label — same caption styling as the text-bubble branch so
        // the user can tell which model produced the image.
        baseModelText = modelLabelText
        modelLabel.text = modelLabelText
        modelLabel.textColor = .secondaryLabel
        modelLabel.font = UIFont.preferredFont(forTextStyle: .caption2)
        modelLabel.numberOfLines = 1
        ttsIndicator.stopAnimating()
        ttsIndicator.isHidden = true
    }

    private func configureRoundButton(_ button: UIButton,
                                      systemImage: String,
                                      accessibility: String,
                                      action: Selector) {
        button.translatesAutoresizingMaskIntoConstraints = false
        let cfg = UIImage.SymbolConfiguration(pointSize: 26, weight: .regular)
        button.setImage(UIImage(systemName: systemImage, withConfiguration: cfg), for: .normal)
        button.tintColor = .label
        button.accessibilityLabel = accessibility
        button.removeTarget(nil, action: nil, for: .allEvents)
        button.addTarget(self, action: action, for: .touchUpInside)
    }

    @objc private func handleDownloadTap() {
        guard let id = currentAttachmentId else { return }
        imageDelegate?.messagingCellDidTapDownload(attachmentId: id)
    }

    @objc private func handleRetryTap() {
        guard let id = currentAttachmentId else { return }
        imageDelegate?.messagingCellDidTapRetry(attachmentId: id)
    }

    @objc private func handleImageTap() {
        // User-uploaded attachment (image or PDF): QuickLook the file
        // directly. AI-generated images route through the existing delegate
        // so MessagingVC can present its own zoom viewer.
        if let url = currentAttachmentFileURL {
            presentQuickLook(for: url)
            return
        }
        guard let id = currentAttachmentId else { return }
        imageDelegate?.messagingCellDidTapImage(attachmentId: id, sourceView: attachmentImageView)
    }

    private func presentQuickLook(for url: URL) {
        guard let presenter = parentViewController else { return }
        let preview = QLPreviewController()
        let source = MessagingCellQLSource(url: url)
        preview.dataSource = source
        // Hold the source on the preview so it survives the present animation
        // — QLPreviewController only weakly references its data source.
        objc_setAssociatedObject(preview, &MessagingCellQLSource.assocKey, source,
                                 .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        presenter.present(preview, animated: true)
    }

    // MARK: - User-uploaded file attachment rendering

    /// Renders a user-attached image or PDF as a right-aligned bubble, with
    /// any accompanying text in a smaller caption underneath. Tapping the
    /// bubble opens a QuickLook preview of the file.
    fileprivate func applyFileAttachment(_ attachment: FileAttachment,
                                         accompanyingText: String,
                                         role: String) {
        currentAttachmentId = attachment.id
        currentAttachmentFileURL = attachment.fileURL

        profileImageView.isHidden = true
        animatingtextView.isHidden = true
        actionButton.isHidden = true
        shimmerLabel.isHidden = true
        modelLabel.isHidden = true
        attachmentErrorLabel.isHidden = true
        downloadButton.isHidden = true
        retryButton.isHidden = true
        attachmentSpinner.stopAnimating()
        attachmentSpinner.isHidden = true

        // Accompanying user text below the file bubble (e.g. "what is this?")
        // — only shown if the message actually has copy. We piggyback on
        // `textView` since the cell already configures it for plain text.
        let hasText = !accompanyingText.isEmpty
        textView.isHidden = !hasText

        attachmentImageView.isHidden = false
        attachmentImageView.translatesAutoresizingMaskIntoConstraints = false
        attachmentImageView.contentMode = .scaleAspectFill
        attachmentImageView.clipsToBounds = true
        attachmentImageView.layer.cornerRadius = 14
        attachmentImageView.layer.borderWidth = 1
        attachmentImageView.layer.borderColor = UIColor.systemFill.cgColor
        attachmentImageView.backgroundColor = UIColor.secondarySystemBackground

        attachmentImageView.isUserInteractionEnabled = true
        if imageTapRecognizer.view !== attachmentImageView {
            attachmentImageView.addGestureRecognizer(imageTapRecognizer)
        }
        imageTapRecognizer.isEnabled = true

        // Size differs by kind — square for images, shorter for PDFs.
        let imageSide: CGFloat = 240
        let pdfHeight: CGFloat = 140

        // Bubble pinned to the trailing edge (user side).
        var constraints: [NSLayoutConstraint] = [
            attachmentImageView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -10),
            attachmentImageView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 12),
            attachmentImageView.widthAnchor.constraint(equalToConstant: imageSide),
        ]
        constraints.append(
            attachmentImageView.heightAnchor.constraint(equalToConstant: attachment.kind == .pdf ? pdfHeight : imageSide)
        )

        if hasText {
            textView.translatesAutoresizingMaskIntoConstraints = false
            textView.textContainerInset = .init(top: 8, left: 10, bottom: 8, right: 10)
            textView.textContainer.lineFragmentPadding = 0
            textView.textContainer.maximumNumberOfLines = 0
            textView.textContainer.widthTracksTextView = true
            textView.layer.cornerRadius = 10
            textView.layer.borderWidth = 2
            textView.layer.borderColor = UIColor.systemFill.cgColor
            textView.font = UIFont.preferredFont(forTextStyle: .body)
            textView.alpha = 1
            textView.isScrollEnabled = false
            textView.isEditable = false
            textView.attributedText = self.attributedString(from: accompanyingText)

            constraints += [
                textView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -10),
                textView.topAnchor.constraint(equalTo: attachmentImageView.bottomAnchor, constant: 6),
                textView.widthAnchor.constraint(lessThanOrEqualTo: contentView.widthAnchor, multiplier: 0.8, constant: -40),
                textView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -6),
            ]
        } else {
            constraints.append(
                contentView.bottomAnchor.constraint(greaterThanOrEqualTo: attachmentImageView.bottomAnchor, constant: 12)
            )
        }

        attachmentConstraints = constraints
        NSLayoutConstraint.activate(constraints)

        // Render the preview off the main thread. PDFs become a thumbnail of
        // page 1; images get loaded directly. Either way `currentAttachmentId`
        // is the gate against stale callbacks on a recycled cell.
        let id = attachment.id
        let url = attachment.fileURL
        let kind = attachment.kind
        let pdfSize = CGSize(width: imageSide, height: pdfHeight)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let image: UIImage?
            switch kind {
            case .image:
                image = (try? Data(contentsOf: url)).flatMap(UIImage.init(data:))
            case .pdf:
                image = MessagingCell.renderPDFThumbnail(at: url, size: pdfSize)
            }
            DispatchQueue.main.async {
                guard let self = self, self.currentAttachmentId == id else { return }
                self.attachmentImageView.image = image
                if kind == .pdf {
                    // PDFs aren't full-bleed — center the rendered page inside
                    // the bubble so blank margins are obvious as such.
                    self.attachmentImageView.contentMode = .scaleAspectFit
                    self.attachmentImageView.backgroundColor = UIColor.systemBackground
                }
            }
        }
    }

    /// Render page 1 of a PDF as a UIImage sized to fit the bubble. Returns
    /// nil for malformed or empty PDFs — caller handles the placeholder.
    private static func renderPDFThumbnail(at url: URL, size: CGSize) -> UIImage? {
        guard let doc = PDFDocument(url: url), let page = doc.page(at: 0) else { return nil }
        let pageRect = page.bounds(for: .mediaBox)
        let scale = min(size.width / pageRect.width, size.height / pageRect.height)
        let target = CGSize(width: pageRect.width * scale, height: pageRect.height * scale)
        let renderer = UIGraphicsImageRenderer(size: target)
        return renderer.image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(origin: .zero, size: target))
            ctx.cgContext.translateBy(x: 0, y: target.height)
            ctx.cgContext.scaleBy(x: scale, y: -scale)
            page.draw(with: .mediaBox, to: ctx.cgContext)
        }
    }

    required init?(coder: NSCoder) {
        fatalError()
    }
}

extension UIView {
    var parentViewController: UIViewController? {
        var parentResponder: UIResponder? = self
        while parentResponder != nil {
            parentResponder = parentResponder?.next
            if let viewController = parentResponder as? UIViewController {
                return viewController
            }
        }
        return nil
    }
}

/// Single-item data source for QLPreviewController, used by user-uploaded
/// file attachments. Held via associated object so the preview controller
/// keeps it alive (the controller's reference to dataSource is weak).
final class MessagingCellQLSource: NSObject, QLPreviewControllerDataSource {
    fileprivate static var assocKey: UInt8 = 0
    let url: URL
    init(url: URL) { self.url = url }
    func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
    func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
        return url as NSURL
    }
}

// MARK: - Tap-to-open links via SFSafariViewController

extension MessagingCell: UITextViewDelegate {
    /// iOS 17+ link interception. Tapping a link presents an in-app browser
    /// instead of bouncing the user out to Safari.
    func textView(_ textView: UITextView,
                  primaryActionFor textItem: UITextItem,
                  defaultAction: UIAction) -> UIAction? {
        if case .link(let url) = textItem.content {
            return UIAction { [weak self] _ in
                self?.openLink(url)
            }
        }
        return defaultAction
    }

    private func openLink(_ url: URL) {
        // A markdown file link opens in the in-app editor (read + edit)
        // rather than bouncing out to the Files app.
        if url.isFileURL,
           MarkdownEditorViewController.isMarkdownFile(url),
           FileManager.default.fileExists(atPath: url.path),
           let presenter = parentViewController {
            MarkdownEditorViewController.present(for: url, from: presenter)
            return
        }
        // SFSafariViewController only supports http/https. Fall back to
        // UIApplication for everything else (mailto:, tel:, custom schemes).
        let scheme = url.scheme?.lowercased()
        if scheme != "http" && scheme != "https" {
            UIApplication.shared.open(url)
            return
        }
        guard let presenter = parentViewController else {
            UIApplication.shared.open(url)
            return
        }
        let safari = SFSafariViewController(url: url)
        presenter.present(safari, animated: true)
    }
}

/// UIView whose `layer.borderColor` re-resolves through its UIColor on
/// trait collection changes. `UIView.backgroundColor` adapts to dynamic
/// UIColors automatically, but CGColors on CALayer are static — without
/// this, a table built in dark mode keeps a dark border after a switch
/// to light mode and vice versa.
final class AdaptiveBorderView: UIView {
    var adaptiveBorderColor: UIColor? {
        didSet { applyBorder() }
    }

    private func applyBorder() {
        layer.borderColor = adaptiveBorderColor?.resolvedColor(with: traitCollection).cgColor
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        guard traitCollection.hasDifferentColorAppearance(comparedTo: previousTraitCollection) else { return }
        applyBorder()
    }
}
