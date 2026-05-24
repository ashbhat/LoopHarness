//
//  LifeView.swift
//  Loop
//
//  Created by Ash Bhat on 12/30/25.
//
import UIKit
import AVFoundation

// Custom dot view with touch interaction
class InteractiveDot: UIView {
    let dayIndex: Int
    var isCounted: Bool = false
    var normalColor: UIColor? // Store the normal color for trail effect
    
    private let normalSize: CGFloat
    private let hapticFeedback = UIImpactFeedbackGenerator(style: .light)
    var isExpanded: Bool = false
    
    init(dayIndex: Int, size: CGFloat) {
        self.dayIndex = dayIndex
        self.normalSize = size
        super.init(frame: .zero)
        hapticFeedback.prepare()
        setupDot()
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    private func setupDot() {
        self.frame = CGRect(x: 0, y: 0, width: normalSize, height: normalSize)
        self.layer.cornerRadius = normalSize / 2
    }
    
    func expandDot() {
        guard !isExpanded else { return }
        isExpanded = true
        UIView.animate(withDuration: 0.15, delay: 0, usingSpringWithDamping: 0.7, initialSpringVelocity: 0.5, options: [.curveEaseOut, .allowUserInteraction]) {
            self.transform = CGAffineTransform(scaleX: 1.5, y: 1.5)
        }
    }
    
    func expandDotWithTrail() {
        guard !isExpanded else { return }
        isExpanded = true
        
        // Get the normal color (should be set by parent)
        let targetColor = normalColor ?? self.backgroundColor ?? UIColor.clear
        
        // Create a brighter version of the normal color for the trail effect
        var startColor = targetColor
        if let components = targetColor.cgColor.components, components.count >= 3 {
            let r = min(components[0] * 1.4, 1.0)
            let g = min(components[1] * 1.4, 1.0)
            let b = min(components[2] * 1.4, 1.0)
            let alpha = components.count > 3 ? components[3] : 1.0
            startColor = UIColor(red: r, green: g, blue: b, alpha: alpha)
        }
        
        // Start with the brighter color
        self.backgroundColor = startColor
        
        // Animate: expand and fade color back to normal
        UIView.animate(withDuration: 0.55, delay: 0, usingSpringWithDamping: 0.7, initialSpringVelocity: 0.5, options: [.curveEaseOut, .allowUserInteraction]) {
            self.transform = CGAffineTransform(scaleX: 1.5, y: 1.5)
            // Fade color back to normal
            self.backgroundColor = targetColor
        } completion: { _ in
            // Continue fading and scale down
            UIView.animate(withDuration: 0.5, delay: 0, options: [.curveEaseOut, .allowUserInteraction]) {
                self.transform = CGAffineTransform(scaleX: 1.0, y: 1.0)
            } completion: { _ in
                // Ensure we're back to normal
                self.isExpanded = false
                self.transform = .identity
            }
        }
    }
    
    func contractDot() {
        guard isExpanded else { return }
        isExpanded = false
        UIView.animate(withDuration: 1.0, delay: 0, usingSpringWithDamping: 0.7, initialSpringVelocity: 0.5, options: [.curveEaseOut, .allowUserInteraction]) {
            self.transform = .identity
        }
    }
}

class LifeView: UIView {
    
    let yearLabel = UILabel.init(frame: .zero)
    let dotsContainerView = UIView()
    let statusLabel = UILabel()
    
    private var totalDays: Int {
        // Check if current year is a leap year
        let calendar = Calendar.current
        let year = currentYear
        let dateComponents = DateComponents(year: year, month: 2, day: 29)
        if let date = calendar.date(from: dateComponents),
           calendar.component(.day, from: date) == 29 {
            return 366 // Leap year
        }
        return 365 // Regular year
    }
    private let columns = 14
    private let dotSize: CGFloat = 18
    private let dotSpacing: CGFloat = 2
    
    // Colors from images
    private let countedDotColor = UIColor(red: 0.6, green: 0.6, blue: 1.0, alpha: 1.0) // Light purple/periwinkle
    private let uncountedDotColor = UIColor.secondaryLabel
    
    // Color for weekends (lighter purple)
    private let weekendCountedColor = UIColor(red: 0.75, green: 0.75, blue: 1.0, alpha: 1.0) // Lighter purple for weekends
    private let weekendUncountedColor = UIColor(red: 0.4, green: 0.4, blue: 0.5, alpha: 1.0) // Lighter for uncounted weekends
    
    // Color for 1st of each month (more blue)
    private let firstOfMonthCountedColor = UIColor(red: 0.3, green: 0.4, blue: 1.0, alpha: 1.0) // Much more blue
    private let firstOfMonthUncountedColor = UIColor(red: 0.2, green: 0.25, blue: 0.6, alpha: 1.0) // Much more blue for uncounted
    
    private var dots: [InteractiveDot] = []
    private var containerHeightConstraint: NSLayoutConstraint?
    private var statusLabelResetTimer: Timer?
    private var originalStatusText: NSAttributedString?
    private var currentlyTouchedDot: InteractiveDot?
    private var lastHapticDotIndex: Int = -1
    private var panStartLocation: CGPoint = .zero
    private var panStartTime: CFTimeInterval = 0
    
    // Audio components for chime
    private var audioEngine: AVAudioEngine?
    private var playerNode: AVAudioPlayerNode?
    private var lastChimeTime: Date = Date.distantPast
    
    // Callback for title updates
    var onTitleUpdate: ((String?) -> Void)?
    
    // Year navigation
    private var currentYear: Int = {
        let calendar = Calendar.current
        return calendar.component(.year, from: Date())
    }() {
        didSet {
            // Update number of dots if year changed from leap to non-leap or vice versa
            updateDotsForYear()
            updateDotsLayout()
            updateStatusLabel()
            originalStatusText = statusLabel.attributedText
            onTitleUpdate?(String(currentYear))
        }
    }
    private var twoFingerPanStartLocation: CGPoint?
    
    init() {
        super.init(frame: .zero)
        self.translatesAutoresizingMaskIntoConstraints = false
        
        self.backgroundColor = .systemBackground
        
        setupDotsContainer()
        setupStatusLabel()
        setupConstraints()
        setupAudioEngine()
        updateStatusLabel()
        // Store original status text
        originalStatusText = statusLabel.attributedText
    }
    
    private func setupAudioEngine() {
        // Configure audio session to mix with other audio
        do {
            try AVAudioSession.sharedInstance().setCategory(.ambient, mode: .default, options: [.mixWithOthers])
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            print("Failed to configure audio session: \(error)")
        }
        
        audioEngine = AVAudioEngine()
        playerNode = AVAudioPlayerNode()
        
        guard let audioEngine = audioEngine, let playerNode = playerNode else { return }
        
        audioEngine.attach(playerNode)
        
        let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1)
        audioEngine.connect(playerNode, to: audioEngine.mainMixerNode, format: format)
        
        do {
            try audioEngine.start()
        } catch {
            print("Failed to start audio engine: \(error)")
        }
    }
    
    private func playChime(dayIndex: Int) {
        guard let playerNode = playerNode else { return }
        
        // Check if audio is muted
        if iCloudKVSDefaults.shared.bool(forKey: "audioMuted") {
            return // Skip if muted
        }
        
        // Throttle chimes to prevent overwhelming when dragging very fast
        let now = Date()
        if now.timeIntervalSince(lastChimeTime) < 0.005 {
            return // Skip if too soon
        }
        lastChimeTime = now
        
        // Generate a crisp, percussive tick sound
        let sampleRate: Double = 44100
        let duration: Double = 0.01 // Very short tick
        let frameCount = Int(sampleRate * duration)
        
        guard frameCount > 0 else { return }
        
        var audioBuffer = AVAudioPCMBuffer(pcmFormat: AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!, frameCapacity: AVAudioFrameCount(frameCount))
        audioBuffer?.frameLength = AVAudioFrameCount(frameCount)
        
        guard let buffer = audioBuffer, let channelData = buffer.floatChannelData else { return }
        
        let channel = channelData.pointee
        
        // Vary pitch slightly based on day index to create a musical flow
        // Use a pentatonic scale for pleasant intervals
        let baseFreq: Double = 800.0 // Base frequency
        let pitchVariation = Double(dayIndex % 5) * 50.0 // Cycle through 5 pitches
        let frequency = baseFreq + pitchVariation
        
        let amplitude: Float = 0.4
        
        for frame in 0..<frameCount {
            let time = Double(frame) / sampleRate
            
            // Create a sharp attack with quick exponential decay for crisp sound
            let attackTime: Double = 0.001 // Very quick attack
            let decayTime: Double = duration - attackTime
            
            var envelope: Float = 1.0
            if time < attackTime {
                // Sharp attack
                envelope = Float(time / attackTime)
            } else {
                // Quick exponential decay
                let decayProgress = (time - attackTime) / decayTime
                envelope = Float(exp(-decayProgress * 8.0)) // Exponential decay
            }
            
            // Generate tone with sharp attack
            let sample = Float(sin(2.0 * .pi * frequency * time)) * amplitude * envelope
            
            // Add a slight harmonic for richness
            let harmonic = Float(sin(2.0 * .pi * frequency * 2.0 * time)) * amplitude * envelope * 0.3
            channel[frame] = sample + harmonic
        }
        
        playerNode.scheduleBuffer(buffer, at: nil, options: [], completionHandler: nil)
        playerNode.play()
    }

    
    private func setupDotsContainer() {
        dotsContainerView.translatesAutoresizingMaskIntoConstraints = false
        dotsContainerView.backgroundColor = .clear
        dotsContainerView.isUserInteractionEnabled = true
        self.addSubview(dotsContainerView)
        
        // Create initial dots
        createDots()
        
        // Add pan gesture for smooth dragging (handles both taps and drags)
        let panGesture = UIPanGestureRecognizer(target: self, action: #selector(handlePanGesture(_:)))
        panGesture.maximumNumberOfTouches = 1
        panGesture.minimumNumberOfTouches = 1
        panGesture.delegate = self
        dotsContainerView.addGestureRecognizer(panGesture)
        
        // Add two-finger pan gesture for year navigation
        let twoFingerPanGesture = UIPanGestureRecognizer(target: self, action: #selector(handleTwoFingerPanGesture(_:)))
        twoFingerPanGesture.minimumNumberOfTouches = 2
        twoFingerPanGesture.maximumNumberOfTouches = 2
        twoFingerPanGesture.delegate = self
        dotsContainerView.addGestureRecognizer(twoFingerPanGesture)
        
        // Two-finger gesture should wait for single-finger to fail (so single-finger works immediately)
        twoFingerPanGesture.require(toFail: panGesture)
    }
    
    private func setupStatusLabel() {
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.font = UIFont.systemFont(ofSize: 14)
        statusLabel.textAlignment = .center
        self.addSubview(statusLabel)
    }
    
    private func setupConstraints() {
        NSLayoutConstraint.activate([
            // Year label
            
            // Dots container
            dotsContainerView.leadingAnchor.constraint(equalTo: self.leadingAnchor, constant: 20),
            dotsContainerView.trailingAnchor.constraint(equalTo: self.trailingAnchor, constant: -20),
            dotsContainerView.topAnchor.constraint(equalTo: self.safeAreaLayoutGuide.topAnchor, constant: 30),
            
            // Status label
            statusLabel.centerXAnchor.constraint(equalTo: self.centerXAnchor),
            statusLabel.topAnchor.constraint(equalTo: dotsContainerView.bottomAnchor, constant: 20),
            statusLabel.bottomAnchor.constraint(equalTo: self.bottomAnchor, constant: -20)
        ])
        
        // Set initial container height constraint
        let rows = Int(ceil(Double(totalDays) / Double(columns)))
        let containerHeight = CGFloat(rows) * dotSize + CGFloat(rows - 1) * dotSpacing
        containerHeightConstraint = dotsContainerView.heightAnchor.constraint(equalToConstant: containerHeight)
        containerHeightConstraint?.isActive = true
    }
    
    private func createDots() {
        // Remove existing dots
        dots.forEach { $0.removeFromSuperview() }
        dots = []
        
        // Create interactive dots (365 or 366 depending on leap year)
        for i in 0..<totalDays {
            let dot = InteractiveDot(dayIndex: i, size: dotSize)
            // Disable individual touch handling - pan gesture will handle everything
            dot.isUserInteractionEnabled = false
            dotsContainerView.addSubview(dot)
            dots.append(dot)
        }
    }
    
    private func updateDotsForYear() {
        let oldCount = dots.count
        let newCount = totalDays
        
        if newCount != oldCount {
            // Number of days changed (leap year transition)
            createDots()
            
            // Update container height constraint
            let rows = Int(ceil(Double(totalDays) / Double(columns)))
            let containerHeight = CGFloat(rows) * dotSize + CGFloat(rows - 1) * dotSpacing
            containerHeightConstraint?.constant = containerHeight
        }
    }
    
    override func layoutSubviews() {
        super.layoutSubviews()
        updateDotsLayout()
    }
    
    private func updateDotsLayout() {
        let daysCounted = getDaysCounted(for: currentYear)
        let containerWidth = dotsContainerView.bounds.width
        
        guard containerWidth > 0 else { return }
        
        // Calculate spacing to fill container width
        let totalDotWidth = CGFloat(columns) * dotSize
        let availableWidth = containerWidth - totalDotWidth
        let horizontalSpacing = availableWidth / CGFloat(columns - 1)
        
        for (index, dot) in dots.enumerated() {
            let row = index / columns
            let col = index % columns
            
            // Position dot
            let x = CGFloat(col) * (dotSize + horizontalSpacing)
            let y = CGFloat(row) * (dotSize + dotSpacing)
            
            dot.frame = CGRect(x: x, y: y, width: dotSize, height: dotSize)
            dot.layer.cornerRadius = dotSize / 2
            
            // Color dot based on whether it's been counted, if it's the 1st of a month, if it's today, or if it's a weekend
            let isCounted = index < daysCounted
            let isFirstOfMonth = isFirstOfMonth(dayIndex: index)
            let isToday = isToday(dayIndex: index)
            let isWeekend = isWeekend(dayIndex: index)
            dot.isCounted = isCounted
            
            let normalColor: UIColor
            if isToday {
                normalColor = UIColor.systemBlue
            } else if isFirstOfMonth {
                normalColor = isCounted ? firstOfMonthCountedColor : firstOfMonthUncountedColor
            } else if isWeekend {
                normalColor = isCounted ? weekendCountedColor : weekendUncountedColor
            } else {
                normalColor = isCounted ? countedDotColor : uncountedDotColor
            }
            
            dot.backgroundColor = normalColor
            dot.normalColor = normalColor // Store for trail effect
        }
    }
    
    private func handleDotTouch(dayIndex: Int) {
        // Cancel any existing timer
        statusLabelResetTimer?.invalidate()
        
        // Update status label with day information
        let dayNumber = dayIndex + 1
        let calendar = Calendar.current
        
        guard let startOfYear = calendar.date(from: DateComponents(year: currentYear, month: 1, day: 1)),
              let dayDate = calendar.date(byAdding: .day, value: dayIndex, to: startOfYear) else {
            return
        }
        
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "MMM d"
        let dateString = dateFormatter.string(from: dayDate)
        
        // Update title with date
        onTitleUpdate?(dateString)
        
        let attributedString = NSMutableAttributedString()
        
        // Day number and date in red
        let dayString = NSAttributedString(
            string: "Day \(dayNumber) • \(dateString)",
            attributes: [.foregroundColor: UIColor.systemRed]
        )
        attributedString.append(dayString)
        
        // Animate the status label update
        UIView.animate(withDuration: 0.2, delay: 0, options: [.curveEaseOut]) {
            self.statusLabel.alpha = 0
            self.statusLabel.transform = CGAffineTransform(scaleX: 0.9, y: 0.9)
        } completion: { _ in
            self.statusLabel.attributedText = attributedString
            UIView.animate(withDuration: 0.2, delay: 0, options: [.curveEaseOut]) {
                self.statusLabel.alpha = 1.0
                self.statusLabel.transform = .identity
            }
        }
    }
    
    @objc private func handlePanGesture(_ gesture: UIPanGestureRecognizer) {
        let location = gesture.location(in: dotsContainerView)
        
        switch gesture.state {
        case .began:
            panStartLocation = location
            panStartTime = CACurrentMediaTime()
            // Find which dot is under the touch point
            if let touchedDot = findDotAtLocation(location) {
                currentlyTouchedDot = touchedDot
                touchedDot.expandDotWithTrail()
                
                let haptic = UIImpactFeedbackGenerator(style: .light)
                haptic.impactOccurred()
                playChime(dayIndex: touchedDot.dayIndex)
                lastHapticDotIndex = touchedDot.dayIndex
                
                handleDotTouch(dayIndex: touchedDot.dayIndex)
            }
            
        case .changed:
            // Find which dot is under the touch point
            if let touchedDot = findDotAtLocation(location) {
                if touchedDot !== currentlyTouchedDot {
                    // Contract previous dot
                    currentlyTouchedDot?.contractDot()
                    
                    // Expand new dot with trail effect
                    currentlyTouchedDot = touchedDot
                    touchedDot.expandDotWithTrail()
                    
                    // Haptic feedback and chime only when entering a new dot
                    if touchedDot.dayIndex != lastHapticDotIndex {
                        let haptic = UIImpactFeedbackGenerator(style: .light)
                        haptic.impactOccurred()
                        playChime(dayIndex: touchedDot.dayIndex)
                        lastHapticDotIndex = touchedDot.dayIndex
                    }
                    
                    // Update status label
                    handleDotTouch(dayIndex: touchedDot.dayIndex)
                }
            } else {
                // Touch moved outside any dot - contract current dot but keep status
                if currentlyTouchedDot != nil {
                    currentlyTouchedDot?.contractDot()
                    currentlyTouchedDot = nil
                    lastHapticDotIndex = -1
                }
            }
            
        case .ended:
            // Check if this was a tap (minimal movement) or a drag
            let translation = gesture.translation(in: dotsContainerView)
            let distance = sqrt(translation.x * translation.x + translation.y * translation.y)
            let timeElapsed = CACurrentMediaTime() - panStartTime
            let isTap = distance < 10.0 && timeElapsed < 0.3 // Less than 10 points movement and less than 0.3 seconds
            
            // Contract all dots
            let finalDot = currentlyTouchedDot
            currentlyTouchedDot?.contractDot()
            currentlyTouchedDot = nil
            lastHapticDotIndex = -1
            
            // Show context menu if it was a tap or if we ended on a dot
            if let dot = finalDot {
                if isTap {
                    // Immediate menu for tap
                    showContextMenu(for: dot, at: location)
                } else {
                    // Show menu after a brief delay for drag end
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                        self?.showContextMenu(for: dot, at: location)
                    }
                }
            }
            
            handleDotRelease()
            
        case .cancelled, .failed:
            // Contract all dots
            currentlyTouchedDot?.contractDot()
            currentlyTouchedDot = nil
            lastHapticDotIndex = -1
            handleDotRelease()
            
        default:
            break
        }
    }
    
    @objc private func handleTwoFingerPanGesture(_ gesture: UIPanGestureRecognizer) {
        let location = gesture.location(in: dotsContainerView)
        let translation = gesture.translation(in: dotsContainerView)
        let swipeThreshold: CGFloat = 50 // Minimum distance for a swipe
        
        switch gesture.state {
        case .began:
            twoFingerPanStartLocation = location
            
        case .ended:
            guard let startLocation = twoFingerPanStartLocation else { break }
            
            let deltaX = location.x - startLocation.x
            
            // Swipe left (next year)
            if deltaX < -swipeThreshold {
                currentYear += 1
                let haptic = UINotificationFeedbackGenerator()
                haptic.notificationOccurred(.success)
            }
            // Swipe right (previous year)
            else if deltaX > swipeThreshold {
                currentYear -= 1
                let haptic = UINotificationFeedbackGenerator()
                haptic.notificationOccurred(.success)
            }
            
            twoFingerPanStartLocation = nil
            
        case .cancelled, .failed:
            twoFingerPanStartLocation = nil
            
        default:
            break
        }
    }
    
    private func findDotAtLocation(_ location: CGPoint) -> InteractiveDot? {
        // Check each dot to see if the touch point is within its bounds
        // Use a larger hit area for easier dragging
        let hitAreaSize: CGFloat = dotSize * 2.0
        
        for dot in dots {
            let center = CGPoint(x: dot.frame.midX, y: dot.frame.midY)
            let distance = sqrt(pow(location.x - center.x, 2) + pow(location.y - center.y, 2))
            
            if distance <= hitAreaSize / 2 {
                return dot
            }
        }
        return nil
    }
    
    private func handleDotRelease() {
        // Reset timer to restore original status after 1 second
        statusLabelResetTimer?.invalidate()
        statusLabelResetTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: false) { [weak self] _ in
            self?.restoreOriginalStatus()
        }
    }
    
    private func restoreOriginalStatus() {
        // Restore title to current year
        onTitleUpdate?(String(currentYear))
        
        // Animate back to original status
        UIView.animate(withDuration: 0.2, delay: 0, options: [.curveEaseOut]) {
            self.statusLabel.alpha = 0
            self.statusLabel.transform = CGAffineTransform(scaleX: 0.9, y: 0.9)
        } completion: { _ in
            if let originalText = self.originalStatusText {
                self.statusLabel.attributedText = originalText
            } else {
                self.updateStatusLabel()
                self.originalStatusText = self.statusLabel.attributedText
            }
            UIView.animate(withDuration: 0.2, delay: 0, options: [.curveEaseOut]) {
                self.statusLabel.alpha = 1.0
                self.statusLabel.transform = .identity
            }
        }
    }
    
    private func showContextMenu(for dot: InteractiveDot, at location: CGPoint) {
        let calendar = Calendar.current
        
        guard let startOfYear = calendar.date(from: DateComponents(year: currentYear, month: 1, day: 1)),
              let dayDate = calendar.date(byAdding: .day, value: dot.dayIndex, to: startOfYear) else {
            return
        }
        
        // Format date as title: "Fri, Apr 25"
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "EEE, MMM d"
        let dateTitle = dateFormatter.string(from: dayDate)
        
        // Find the view controller to present from
        var responder: UIResponder? = self
        while responder != nil {
            responder = responder?.next
            if let viewController = responder as? UIViewController {
                // Create action sheet menu
                let alertController = UIAlertController(title: dateTitle, message: nil, preferredStyle: .actionSheet)
                
                // Generate image action
                let generateImageAction = UIAlertAction(title: "Generate image", style: .default) { [weak self] _ in
                    self?.handleGenerateImage(for: dot.dayIndex, date: dayDate)
                }
                alertController.addAction(generateImageAction)
                
                // Review note action
                let reviewNoteAction = UIAlertAction(title: "Review", style: .default) { [weak self] _ in
                    self?.handleReviewNote(for: dot.dayIndex, date: dayDate)
                }
                alertController.addAction(reviewNoteAction)
                
                // Cancel action
                let cancelAction = UIAlertAction(title: "Cancel", style: .cancel)
                alertController.addAction(cancelAction)
                
                // Configure for iPad (popover presentation)
                if let popover = alertController.popoverPresentationController {
                    // Calculate the dot's position
                    let dotFrame = dot.frame
                    let dotTopCenter = CGPoint(
                        x: dotFrame.midX,
                        y: dotFrame.minY
                    )
                    let dotBottomCenter = CGPoint(
                        x: dotFrame.midX,
                        y: dotFrame.maxY
                    )
                    
                    // Convert from dotsContainerView to view controller's view
                    let dotTopCenterInView = self.convert(dotTopCenter, from: dotsContainerView)
                    let dotBottomCenterInView = self.convert(dotBottomCenter, from: dotsContainerView)
                    let dotTopCenterInVCView = viewController.view.convert(dotTopCenterInView, from: self)
                    let dotBottomCenterInVCView = viewController.view.convert(dotBottomCenterInView, from: self)
                    
                    // Estimate menu height (approximate: title + 3 actions + padding ≈ 250 points)
                    let estimatedMenuHeight: CGFloat = 250
                    let minimumSpaceAbove: CGFloat = estimatedMenuHeight + 20 // Add some padding
                    
                    // Check if there's enough space above the dot
                    let spaceAbove = dotTopCenterInVCView.y
                    let showAbove = spaceAbove >= minimumSpaceAbove
                    
                    if showAbove {
                        // Show menu above the dot
                        popover.sourceView = viewController.view
                        popover.sourceRect = CGRect(origin: dotTopCenterInVCView, size: .zero)
                        popover.permittedArrowDirections = [.down] // Arrow points down to the dot
                    } else {
                        // Show menu below the dot
                        popover.sourceView = viewController.view
                        popover.sourceRect = CGRect(origin: dotBottomCenterInVCView, size: .zero)
                        popover.permittedArrowDirections = [.up] // Arrow points up to the dot
                    }
                }
                
                viewController.present(alertController, animated: true)
                break
            }
        }
    }
    
    private func handleGenerateImage(for dayIndex: Int, date: Date) {
        // Not yet implemented.
        print("Generate image for day \(dayIndex), date: \(date)")
    }
    
    private func handleReviewNote(for dayIndex: Int, date: Date) {
        // Not yet implemented.
        print("Review note for day \(dayIndex), date: \(date)")
    }
    
    private func updateStatusLabel() {
        let daysCounted = getDaysCounted(for: currentYear)
        let daysLeft = totalDays - daysCounted
        let percentage = Int((Double(daysCounted) / Double(totalDays)) * 100)
        
        let attributedString = NSMutableAttributedString()
        
        // "2d left" in red
        let daysLeftString = NSAttributedString(
            string: "\(daysLeft)d left",
            attributes: [.foregroundColor: UIColor.systemRed]
        )
        attributedString.append(daysLeftString)
        
        // " • 99%" in secondaryLabel color
        let percentageString = NSAttributedString(
            string: " • \(percentage)%",
            attributes: [.foregroundColor: UIColor.secondaryLabel]
        )
        attributedString.append(percentageString)
        
        statusLabel.attributedText = attributedString
        // Update original status text if it hasn't been set or if we're restoring
        if originalStatusText == nil {
            originalStatusText = attributedString
        }
    }
    
    private func isFirstOfMonth(dayIndex: Int) -> Bool {
        let calendar = Calendar.current
        
        guard let startOfYear = calendar.date(from: DateComponents(year: currentYear, month: 1, day: 1)),
              let targetDate = calendar.date(byAdding: .day, value: dayIndex, to: startOfYear) else {
            return false
        }
        
        // Check if this date is the 1st of a month
        let day = calendar.component(.day, from: targetDate)
        return day == 1
    }
    
    private func isToday(dayIndex: Int) -> Bool {
        let calendar = Calendar.current
        let now = Date()
        
        guard let startOfYear = calendar.date(from: DateComponents(year: currentYear, month: 1, day: 1)),
              let targetDate = calendar.date(byAdding: .day, value: dayIndex, to: startOfYear) else {
            return false
        }
        
        // Check if this date is today (only for current year)
        let currentYearFromDate = calendar.component(.year, from: now)
        if currentYear == currentYearFromDate {
            return calendar.isDate(targetDate, inSameDayAs: now)
        }
        return false
    }
    
    private func isWeekend(dayIndex: Int) -> Bool {
        let calendar = Calendar.current
        
        guard let startOfYear = calendar.date(from: DateComponents(year: currentYear, month: 1, day: 1)),
              let targetDate = calendar.date(byAdding: .day, value: dayIndex, to: startOfYear) else {
            return false
        }
        
        // Check if this date is a Saturday (6) or Sunday (7)
        let weekday = calendar.component(.weekday, from: targetDate)
        return weekday == 1 || weekday == 7 // Sunday = 1, Saturday = 7
    }
    
    private func getDaysCounted(for year: Int) -> Int {
        let calendar = Calendar.current
        let now = Date()
        let currentYearFromDate = calendar.component(.year, from: now)
        
        guard let startOfYear = calendar.date(from: DateComponents(year: year, month: 1, day: 1)) else {
            return 0
        }
        
        // If viewing a past year, all days are counted
        if year < currentYearFromDate {
            return totalDays
        }
        
        // If viewing a future year, no days are counted
        if year > currentYearFromDate {
            return 0
        }
        
        // For current year, calculate based on today
        let startOfToday = calendar.startOfDay(for: now)
        let startOfYearDay = calendar.startOfDay(for: startOfYear)
        
        guard let daysSinceStart = calendar.dateComponents([.day], from: startOfYearDay, to: startOfToday).day else {
            return 0
        }
        
        // Return days counted (don't count today, so days left includes today)
        // daysSinceStart is the number of complete days that have passed
        // So if today is Dec 30, daysSinceStart = 363, meaning we've counted 363 days (Jan 1 - Dec 29)
        // and there are 2 days left (Dec 30 and Dec 31)
        return min(daysSinceStart, totalDays)
    }
    
    required init?(coder: NSCoder) {
        fatalError()
    }
}

// MARK: - UIGestureRecognizerDelegate
extension LifeView: UIGestureRecognizerDelegate {
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        // Don't allow simultaneous recognition - they have different touch counts anyway
        return false
    }
}
