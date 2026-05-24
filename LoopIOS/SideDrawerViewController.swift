//
//  SideDrawerViewController.swift
//  Loop
//
//  Created by Ash Bhat on 11/2/24.
//

import UIKit
import QuickLook

protocol SideDrawerDelegate: AnyObject {
    func sideDrawerDidClose()
    func sideDrawerDidSelectConversation(_ conversation: Conversation?)
}

class SideDrawerViewController: UIViewController {

    weak var delegate: SideDrawerDelegate?

    // MARK: - UI Components
    private let containerView = UIView()
    private let navigationBar = UINavigationBar()
    private let newNavigationItem = UINavigationItem()
    private let segmentedControl = UISegmentedControl(items: ["Conversations", "Files", "Skills"])

    /// UserDefaults key for the last-selected segment. Restored on setup so the
    /// drawer reopens on whatever tab the user left it on.
    private static let selectedTabDefaultsKey = "SideDrawer.selectedTab"
    private let tableView = UITableView()
    private let overlayView = UIView()

    // MARK: - Mode

    /// What the table is currently showing. The same UITableView is reused
    /// for both modes — the cell types, row heights, and data sources all
    /// branch on this flag rather than swapping the table out.
    private enum Mode {
        case conversations
        case files
        case skills
    }
    private var mode: Mode = .conversations

    /// Map a segmented-control index to a mode. Centralised so the restore
    /// path and the value-changed handler can't drift apart.
    private func mode(forSegmentIndex index: Int) -> Mode {
        switch index {
        case 1:  return .files
        case 2:  return .skills
        default: return .conversations
        }
    }

    // MARK: - File tree state

    /// Folder URLs that the user has expanded. The flat row list is rebuilt
    /// from this set on every toggle so the order always reflects the live
    /// directory contents.
    private var expandedFolders: Set<URL> = []
    private var fileRows: [FileRow] = []

    /// One row in the flattened file tree. `depth` drives the visual indent.
    private struct FileRow {
        let url: URL
        let isDirectory: Bool
        let depth: Int
    }

    // MARK: - Skills state

    /// One row in the Skills tab. `isDynamic` distinguishes user-authored JS
    /// skills (loaded from disk, removable) from the bundled built-ins.
    private struct SkillRow {
        let title: String
        let subtitle: String
        let isDynamic: Bool
    }
    private var skillRows: [SkillRow] = []

    /// Holds the URL we're previewing so QLPreviewController can ask for it
    /// via the data source protocol (which can't capture state in a closure).
    private var previewURL: URL?
    
    // MARK: - Animation Properties
    private var drawerWidth: CGFloat {
        // Use view width for full overlay, or a percentage if preferred
        // Fallback to screen width if view bounds not available yet
        let width = view.bounds.width > 0 ? view.bounds.width : UIScreen.main.bounds.width
        return width * 0.85 // 85% of screen width for full overlay feel
    }
    private var isOpen = false
    var panGestureRecognizer: UIPanGestureRecognizer!
    private var tapGestureRecognizer: UITapGestureRecognizer!
    
    // MARK: - Pan Gesture Properties
    private var initialDrawerPosition: CGFloat = 0
    private var currentDrawerPosition: CGFloat = 0
    private var panStartTime: CFTimeInterval = 0
    private var closeCompletion: (() -> Void)?
    
    // MARK: - Edge Pan Properties
    private var isEdgePanTracking = false
    private var edgePanStartPosition: CGFloat = 0
    
    // MARK: - Constraints
    private var containerLeadingConstraint: NSLayoutConstraint!
    private var overlayAlphaConstraint: NSLayoutConstraint!
    
    // MARK: - Data
    private var conversations: [Conversation] = []
    private let conversationManager = SimpleConversationManager.shared
    private var currentConversationId: String?
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        // Ensure drawer view is on top and covers everything
        view.backgroundColor = .clear
        view.isOpaque = false
        
        setupUI()
        setupGestures()
        setupConstraints()
        loadConversations()
        
        // Don't automatically open drawer - let the parent decide when to open
        // This prevents flashing when used for edge pan tracking
    }
    
    // MARK: - Setup Methods
    
    private func setupUI() {
        view.backgroundColor = .clear
        
        // Extend edges under status bar and navigation bar
        if #available(iOS 11.0, *) {
            // Allow content to extend under safe areas
        }
        edgesForExtendedLayout = .all
        
        // Setup overlay
        overlayView.backgroundColor = UIColor.black.withAlphaComponent(0.5)
        overlayView.alpha = 0
        overlayView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(overlayView)
        
        // Setup container
        containerView.backgroundColor = UIColor.systemBackground
        containerView.translatesAutoresizingMaskIntoConstraints = false
        containerView.layer.shadowColor = UIColor.black.cgColor
        containerView.layer.shadowOffset = CGSize(width: 2, height: 0)
        containerView.layer.shadowRadius = 10
        containerView.layer.shadowOpacity = 0.3
        view.addSubview(containerView)
        
        // Setup navigation bar
        navigationBar.translatesAutoresizingMaskIntoConstraints = false
        navigationBar.backgroundColor = UIColor.systemBackground
        navigationBar.barTintColor = UIColor.systemBackground
        navigationBar.isTranslucent = false
        containerView.addSubview(navigationBar)
        
        // The segmented control replaces a static title here — set the
        // navigation bar's title view so it tracks the bar's vertical
        // centering automatically.
        // Restore the last-selected tab. Clamp to the valid range in case the
        // segment count ever shrinks below a previously stored index.
        let storedIndex = UserDefaults.standard.integer(forKey: Self.selectedTabDefaultsKey)
        let restoredIndex = min(max(storedIndex, 0), segmentedControl.numberOfSegments - 1)
        segmentedControl.selectedSegmentIndex = restoredIndex
        mode = mode(forSegmentIndex: restoredIndex)
        rebuildRows(for: mode)
        segmentedControl.addTarget(self, action: #selector(segmentedControlChanged), for: .valueChanged)
        navigationBar.setItems([newNavigationItem], animated: false)

        // Pinned into the bar with explicit horizontal insets (rather than set
        // as `titleView`, which centers it at its intrinsic width and lets the
        // labels hug the drawer edges). Constraints are wired in
        // setupConstraints once the bar is in the hierarchy.
        segmentedControl.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(segmentedControl)

        // Setup table view
        tableView.delegate = self
        tableView.dataSource = self
        tableView.register(ConversationCell.self, forCellReuseIdentifier: "ConversationCell")
        tableView.register(FileTreeCell.self, forCellReuseIdentifier: "FileTreeCell")
        tableView.register(SkillCell.self, forCellReuseIdentifier: "SkillCell")
        tableView.separatorStyle = .none
        tableView.backgroundColor = .clear
        tableView.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(tableView)
    }
    
    private func setupGestures() {
        // Pan gesture for the entire drawer container
        panGestureRecognizer = UIPanGestureRecognizer(target: self, action: #selector(handlePanGesture(_:)))
        containerView.addGestureRecognizer(panGestureRecognizer)
        
        // Tap gesture for overlay
        tapGestureRecognizer = UITapGestureRecognizer(target: self, action: #selector(overlayTapped))
        overlayView.addGestureRecognizer(tapGestureRecognizer)
    }
    
    private func setupConstraints() {
        // Overlay constraints - full screen overlay
        NSLayoutConstraint.activate([
            overlayView.topAnchor.constraint(equalTo: view.topAnchor),
            overlayView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            overlayView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            overlayView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        
        // Container constraints - full vertical overlay
        containerLeadingConstraint = containerView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: -drawerWidth)
        NSLayoutConstraint.activate([
            containerView.topAnchor.constraint(equalTo: view.topAnchor), // Full height from top
            containerLeadingConstraint,
            containerView.widthAnchor.constraint(equalToConstant: drawerWidth),
            containerView.bottomAnchor.constraint(equalTo: view.bottomAnchor) // Full height to bottom
        ])
        
        // Navigation bar constraints - respect safe area at top
        NSLayoutConstraint.activate([
            navigationBar.topAnchor.constraint(equalTo: containerView.safeAreaLayoutGuide.topAnchor, constant: 0),
            navigationBar.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
            navigationBar.trailingAnchor.constraint(equalTo: containerView.trailingAnchor)
        ])

        // Segmented control: centered in the bar, inset from both edges so the
        // labels don't run into the drawer's sides.
        let segmentSideInset: CGFloat = 16
        NSLayoutConstraint.activate([
            segmentedControl.centerYAnchor.constraint(equalTo: navigationBar.centerYAnchor),
            segmentedControl.leadingAnchor.constraint(equalTo: navigationBar.leadingAnchor, constant: segmentSideInset),
            segmentedControl.trailingAnchor.constraint(equalTo: navigationBar.trailingAnchor, constant: -segmentSideInset)
        ])
        
        // Table view constraints
        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: navigationBar.bottomAnchor),
            tableView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: containerView.bottomAnchor)
        ])
    }
    
    // MARK: - Data Methods
    
    private func loadConversations() {
        // Load conversations from Core Data
        let conversationEntities = conversationManager.getAllConversations()
        conversations = conversationEntities.map { conversationManager.conversationStruct(from: $0) }
        
        // Update current conversation ID
        currentConversationId = conversationManager.currentConversation?.id
        
        tableView.reloadData()
    }
    
    private func deleteConversation(at indexPath: IndexPath) {
        let conversation = conversations[indexPath.row]
        let wasCurrentConversation = conversation.id == currentConversationId
        
        // Delete from conversation manager
        if let conversationEntity = conversationManager.getConversation(by: conversation.id) {
            conversationManager.deleteConversation(conversationEntity)
        }
        
        // Remove from local array
        conversations.remove(at: indexPath.row)
        
        // Update table view
        tableView.deleteRows(at: [indexPath], with: .fade)
        
        // If we deleted the current conversation, select the previous one
        if wasCurrentConversation {
            selectPreviousConversation()
        }
    }
    
    private func selectPreviousConversation() {
        // Find the conversation that should be selected next
        // Priority: 1) Previous conversation in list, 2) Next conversation in list, 3) Create new conversation
        var conversationToSelect: Conversation?
        
        if let currentId = currentConversationId,
           let currentIndex = conversations.firstIndex(where: { $0.id == currentId }) {
            // Try to select the previous conversation
            if currentIndex > 0 {
                conversationToSelect = conversations[currentIndex - 1]
            } else if !conversations.isEmpty {
                // If we're at the first item, select the next one (which is now at index 0)
                conversationToSelect = conversations[0]
            }
        } else if !conversations.isEmpty {
            // If no current conversation, select the first one
            conversationToSelect = conversations[0]
        }
        
        // Select the conversation
        if let conversation = conversationToSelect {
            delegate?.sideDrawerDidSelectConversation(conversation)
        } else {
            // No conversations left, create a new one
            delegate?.sideDrawerDidSelectConversation(nil)
        }
    }
    
    // MARK: - Animation Methods
    
    func openDrawer() {
        // Refresh conversations when opening drawer
        loadConversations()
        animateToPosition(0, velocity: 0, duration: 0.4)
    }
    
    func prepareForButtonOpening() {
        // Ensure drawer starts in closed position for button opening
        containerLeadingConstraint.constant = -drawerWidth
        overlayView.alpha = 0
        currentDrawerPosition = -drawerWidth
        isOpen = false
        view.layoutIfNeeded()
    }
    
    private func closeDrawer(completion: (() -> Void)? = nil) {
        // Store completion for use in animateToPosition
        self.closeCompletion = completion
        animateToPosition(-drawerWidth, velocity: 0, duration: 0.3)
    }
    
    // MARK: - Gesture Handlers
    
    @objc private func handlePanGesture(_ gesture: UIPanGestureRecognizer) {
        let translation = gesture.translation(in: view)
        let velocity = gesture.velocity(in: view)
        
        switch gesture.state {
        case .began:
            // Store initial position and start time
            initialDrawerPosition = containerLeadingConstraint.constant
            currentDrawerPosition = initialDrawerPosition
            panStartTime = CACurrentMediaTime()
            
        case .changed:
            // Calculate new position based on translation
            let newPosition = initialDrawerPosition + translation.x
            
            // Constrain the drawer position
            // Allow dragging left (closing) and right (opening from closed state)
            let minPosition: CGFloat = -drawerWidth
            let maxPosition: CGFloat = 0
            
            currentDrawerPosition = max(minPosition, min(maxPosition, newPosition))
            
            // Apply the position directly to the constraint for real-time tracking
            containerLeadingConstraint.constant = currentDrawerPosition
            
            // Update overlay alpha based on drawer position
            let progress = (currentDrawerPosition - minPosition) / (CGFloat(maxPosition) - minPosition)
            overlayView.alpha = progress
            
            // Force immediate layout update
            view.layoutIfNeeded()
            
        case .ended, .cancelled:
            // Calculate gesture duration for inertia
            let gestureDuration = CACurrentMediaTime() - panStartTime
            
            // Determine final position based on velocity and current position
            let shouldClose: Bool
            
            if abs(velocity.x) > 500 {
                // High velocity - use velocity direction
                shouldClose = velocity.x < 0
            } else {
                // Low velocity - use position threshold
                let dragProgress = abs(currentDrawerPosition) / drawerWidth
                shouldClose = dragProgress > 0.3
            }
            
            if shouldClose {
                // Animate to closed position with inertia
                animateToPosition(-drawerWidth, velocity: velocity.x, duration: gestureDuration)
            } else {
                // Animate to open position with inertia
                animateToPosition(0, velocity: velocity.x, duration: gestureDuration)
            }
            
        default:
            break
        }
    }
    
    private func animateToPosition(_ targetPosition: CGFloat, velocity: CGFloat, duration: CFTimeInterval) {
        // Calculate animation duration based on velocity and distance
        let baseDuration = 0.3
        let velocityFactor = min(abs(velocity) / 1000, 1.0) // Normalize velocity
        let dynamicDuration = baseDuration * (1 - velocityFactor * 0.5) // Faster for higher velocity
        
        // Use spring animation for natural feel
        UIView.animate(
            withDuration: dynamicDuration,
            delay: 0,
            usingSpringWithDamping: 0.8,
            initialSpringVelocity: abs(velocity) / 1000,
            options: [.curveEaseOut, .allowUserInteraction],
            animations: {
                self.containerLeadingConstraint.constant = targetPosition
                self.currentDrawerPosition = targetPosition
                
                // Update overlay alpha
                let progress = (targetPosition - (-self.drawerWidth)) / self.drawerWidth
                self.overlayView.alpha = progress
                
                self.view.layoutIfNeeded()
            },
            completion: { _ in
                // Update open state
                self.isOpen = targetPosition == 0
                
                // Call delegate if closing
                if targetPosition == -self.drawerWidth {
                    self.delegate?.sideDrawerDidClose()
                    self.closeCompletion?()
                    self.closeCompletion = nil
                }
            }
        )
    }
    
    @objc private func overlayTapped() {
        closeDrawer()
    }
    
    @objc private func newChatTapped() {
        delegate?.sideDrawerDidSelectConversation(nil)
        closeDrawer()
    }

    @objc private func segmentedControlChanged() {
        let index = segmentedControl.selectedSegmentIndex
        UserDefaults.standard.set(index, forKey: Self.selectedTabDefaultsKey)
        mode = mode(forSegmentIndex: index)
        rebuildRows(for: mode)
        tableView.reloadData()
    }

    /// Rebuild whichever flat row list backs `mode`. Conversations are loaded
    /// separately (Core Data) so they need no prep here.
    private func rebuildRows(for mode: Mode) {
        switch mode {
        case .conversations: break
        case .files:         rebuildFileRows()
        case .skills:        rebuildSkillRows()
        }
    }

    // MARK: - Skills

    /// Flatten the registered skills into display rows: the bundled built-ins
    /// first (catalog order from `AgentHarness`), then any user-authored
    /// dynamic skills loaded from `Workspace/Skills/`, alphabetised. We kick
    /// the dynamic registry to reload first so skills authored this session
    /// show up without an app relaunch.
    private func rebuildSkillRows() {
        var rows: [SkillRow] = AgentHarness.bundledSkillCatalog.map {
            SkillRow(title: $0.name, subtitle: $0.summary, isDynamic: false)
        }
        DynamicSkillRegistry.shared.reload()
        let dynamic = DynamicSkillRegistry.shared.skills.values
            .sorted { $0.name < $1.name }
            .map { SkillRow(title: $0.name, subtitle: $0.description, isDynamic: true) }
        rows.append(contentsOf: dynamic)
        skillRows = rows
    }

    // MARK: - File tree

    /// Walk the workspace root from scratch, honoring whatever's currently
    /// expanded. Cheap enough for hundreds of files; if it ever needs to scale
    /// past that we can cache per-folder listings keyed by URL.
    private func rebuildFileRows() {
        fileRows = []
        appendFileRows(in: Workspace.shared.rootURL, depth: 0)
    }

    private func appendFileRows(in dirURL: URL, depth: Int) {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isDirectoryKey, .nameKey]
        guard let contents = try? fm.contentsOfDirectory(at: dirURL,
                                                          includingPropertiesForKeys: keys,
                                                          options: [.skipsHiddenFiles])
        else { return }
        // Folders first, then files; both alphabetical, case-insensitive — the
        // visual rhythm users expect from Files.app.
        let sorted = contents.sorted { a, b in
            let aDir = (try? a.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            let bDir = (try? b.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if aDir != bDir { return aDir }
            return a.lastPathComponent.localizedCaseInsensitiveCompare(b.lastPathComponent) == .orderedAscending
        }
        for url in sorted {
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            fileRows.append(FileRow(url: url, isDirectory: isDir, depth: depth))
            if isDir, expandedFolders.contains(url) {
                appendFileRows(in: url, depth: depth + 1)
            }
        }
    }

    /// Triggered by tapping a file row. Downloads the file if it's
    /// iCloud-evicted (best-effort, time-boxed), then presents the standard
    /// QuickLook preview controller full-screen with an X close button in
    /// the nav bar.
    private func presentPreview(for url: URL) {
        // Markdown opens in the full editor (read + edit) instead of the
        // read-only QuickLook preview. The editor handles its own
        // iCloud-download + loading spinner.
        if MarkdownEditorViewController.isMarkdownFile(url) {
            let presenter = topMostPresenter() ?? self
            MarkdownEditorViewController.present(for: url, from: presenter)
            return
        }
        previewURL = url
        DispatchQueue.global(qos: .userInitiated).async {
            try? Workspace.shared.ensureDownloaded(url)
            DispatchQueue.main.async { [weak self] in
                guard let self = self, self.previewURL == url else { return }
                let preview = QLPreviewController()
                preview.dataSource = self
                // Full-screen presentation puts the file front-and-centre;
                // wrapping in a UINavigationController gives us the title
                // bar and a guaranteed slot for the close button (QL's own
                // bar items are positioned by the framework and can't host
                // an X reliably across iOS versions).
                preview.navigationItem.leftBarButtonItem = UIBarButtonItem(
                    barButtonSystemItem: .close,
                    target: self,
                    action: #selector(dismissPreviewController)
                )
                let nav = UINavigationController(rootViewController: preview)
                nav.modalPresentationStyle = .fullScreen
                // The drawer is added as a child of the window or messaging
                // VC; presenting directly from `self` can land on the drawer's
                // own view which is mid-animation. Walk to the topmost
                // presented controller so the preview opens reliably.
                let presenter = self.topMostPresenter() ?? self
                presenter.present(nav, animated: true)
            }
        }
    }

    @objc private func dismissPreviewController() {
        // The presenter is whoever currently owns the preview's nav; ask
        // from the topmost so we close exactly the one we put up.
        topMostPresenter()?.dismiss(animated: true)
    }

    private func topMostPresenter() -> UIViewController? {
        // Start from the key window's root and dive through whatever's
        // already presented. Falls back to the side-drawer's parent if no
        // window is available (shouldn't happen while the drawer is on
        // screen, but it's a safe default).
        let root: UIViewController? = {
            if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
               let keyWindow = scene.windows.first(where: { $0.isKeyWindow }) ?? scene.windows.first {
                return keyWindow.rootViewController
            }
            return parent
        }()
        var top = root
        while let presented = top?.presentedViewController {
            top = presented
        }
        return top
    }
    
    // MARK: - Edge Pan Tracking Methods
    
    func startEdgePanTracking() {
        isEdgePanTracking = true
        edgePanStartPosition = -drawerWidth
        currentDrawerPosition = edgePanStartPosition
        
        // Start with drawer completely hidden to avoid flash
        containerLeadingConstraint.constant = -drawerWidth
        overlayView.alpha = 0
        
        // Ensure the view is properly laid out before any animations
        view.layoutIfNeeded()
    }
    
    func updateEdgePanPosition(translation: CGFloat) {
        guard isEdgePanTracking else { return }
        
        // Calculate new position based on translation
        let newPosition = edgePanStartPosition + translation
        
        // Constrain the drawer position
        let minPosition: CGFloat = -drawerWidth
        let maxPosition: CGFloat = 0
        
        currentDrawerPosition = max(minPosition, min(maxPosition, newPosition))
        
        // Apply the position directly to the constraint for real-time tracking
        containerLeadingConstraint.constant = currentDrawerPosition
        
        // Update overlay alpha based on drawer position
        let progress = (currentDrawerPosition - minPosition) / (maxPosition - minPosition)
        overlayView.alpha = progress
        
        // Force immediate layout update
        view.layoutIfNeeded()
    }
    
    func completeEdgePanOpening(velocity: CGFloat, duration: CFTimeInterval) {
        guard isEdgePanTracking else { return }
        isEdgePanTracking = false
        
        // Animate to fully open position with inertia
        animateToPosition(0, velocity: velocity, duration: duration)
    }
    
    func cancelEdgePanOpening() {
        guard isEdgePanTracking else { return }
        isEdgePanTracking = false
        
        // Animate back to closed position
        animateToPosition(-drawerWidth, velocity: 0, duration: 0.3)
    }
}

// MARK: - UITableViewDataSource & UITableViewDelegate

extension SideDrawerViewController: UITableViewDataSource, UITableViewDelegate {

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch mode {
        case .conversations: return conversations.count
        case .files:         return fileRows.count
        case .skills:        return skillRows.count
        }
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        switch mode {
        case .conversations:
            let cell = tableView.dequeueReusableCell(withIdentifier: "ConversationCell", for: indexPath) as! ConversationCell
            let conversation = conversations[indexPath.row]
            let isCurrent = conversation.id == currentConversationId
            cell.configure(with: conversation, isCurrent: isCurrent)
            return cell
        case .files:
            let cell = tableView.dequeueReusableCell(withIdentifier: "FileTreeCell", for: indexPath) as! FileTreeCell
            let row = fileRows[indexPath.row]
            cell.configure(with: row.url,
                           isDirectory: row.isDirectory,
                           depth: row.depth,
                           isExpanded: expandedFolders.contains(row.url))
            return cell
        case .skills:
            let cell = tableView.dequeueReusableCell(withIdentifier: "SkillCell", for: indexPath) as! SkillCell
            let row = skillRows[indexPath.row]
            cell.configure(title: row.title, subtitle: row.subtitle, isDynamic: row.isDynamic)
            return cell
        }
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        switch mode {
        case .conversations:
            let conversation = conversations[indexPath.row]
            delegate?.sideDrawerDidSelectConversation(conversation)
            closeDrawer()
        case .files:
            let row = fileRows[indexPath.row]
            if row.isDirectory {
                if expandedFolders.contains(row.url) {
                    expandedFolders.remove(row.url)
                } else {
                    expandedFolders.insert(row.url)
                }
                rebuildFileRows()
                tableView.reloadData()
            } else {
                presentPreview(for: row.url)
            }
        case .skills:
            // Read-only listing — no detail screen yet. Deselect so the row
            // doesn't stay highlighted.
            break
        }
    }

    func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        switch mode {
        case .conversations: return 80
        case .files:         return 44
        case .skills:        return 60
        }
    }

    func tableView(_ tableView: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        // Swipe-to-delete only applies to conversations — file destructive
        // actions stay in the Files app where the user already has a familiar
        // confirmation flow.
        guard mode == .conversations else { return nil }
        let deleteAction = UIContextualAction(style: .destructive, title: "Delete") { [weak self] (action, view, completionHandler) in
            self?.deleteConversation(at: indexPath)
            completionHandler(true)
        }
        deleteAction.backgroundColor = .systemRed
        deleteAction.image = UIImage(systemName: "trash")

        return UISwipeActionsConfiguration(actions: [deleteAction])
    }
}

// MARK: - QLPreviewControllerDataSource

extension SideDrawerViewController: QLPreviewControllerDataSource {
    func numberOfPreviewItems(in controller: QLPreviewController) -> Int {
        return previewURL == nil ? 0 : 1
    }

    func previewController(_ controller: QLPreviewController,
                           previewItemAt index: Int) -> QLPreviewItem {
        // Falling back to the workspace root keeps the data source contract
        // satisfied if `previewURL` somehow nilled out between presentation
        // and the data-source query.
        return (previewURL ?? Workspace.shared.rootURL) as NSURL
    }
}

// MARK: - File tree cell

/// Single row in the workspace file tree. Indent grows with `depth`; folder
/// rows show a chevron that flips on expansion to telegraph the tap action.
private final class FileTreeCell: UITableViewCell {

    private let iconView = UIImageView()
    private let nameLabel = UILabel()
    private let chevronView = UIImageView()
    private var leadingConstraint: NSLayoutConstraint!

    /// Per-depth indent (points). 18pt felt right against the 20pt cell padding
    /// — enough to read the hierarchy, not so much that deep trees scroll off.
    private static let indentPerDepth: CGFloat = 18
    private static let baseLeading: CGFloat = 20

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        setupUI()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupUI() {
        backgroundColor = .clear
        selectionStyle = .default

        iconView.contentMode = .scaleAspectFit
        iconView.tintColor = .secondaryLabel
        iconView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(iconView)

        nameLabel.font = .systemFont(ofSize: 15)
        nameLabel.textColor = .label
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(nameLabel)

        chevronView.contentMode = .scaleAspectFit
        chevronView.tintColor = .tertiaryLabel
        chevronView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(chevronView)

        leadingConstraint = iconView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: Self.baseLeading)

        NSLayoutConstraint.activate([
            leadingConstraint,
            iconView.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 20),
            iconView.heightAnchor.constraint(equalToConstant: 20),

            nameLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 10),
            nameLabel.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            nameLabel.trailingAnchor.constraint(equalTo: chevronView.leadingAnchor, constant: -8),

            chevronView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            chevronView.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            chevronView.widthAnchor.constraint(equalToConstant: 12),
            chevronView.heightAnchor.constraint(equalToConstant: 12),
        ])
    }

    func configure(with url: URL, isDirectory: Bool, depth: Int, isExpanded: Bool) {
        nameLabel.text = url.lastPathComponent
        leadingConstraint.constant = Self.baseLeading + CGFloat(depth) * Self.indentPerDepth
        if isDirectory {
            iconView.image = UIImage(systemName: isExpanded ? "folder.fill" : "folder")
            iconView.tintColor = .systemBlue
            chevronView.image = UIImage(systemName: isExpanded ? "chevron.down" : "chevron.right")
            chevronView.isHidden = false
        } else {
            iconView.image = UIImage(systemName: "doc")
            iconView.tintColor = .secondaryLabel
            chevronView.isHidden = true
        }
    }
}

// MARK: - Skill cell

/// Single row in the Skills tab. Mirrors `FileTreeCell`'s construction style
/// (programmatic UILabel/UIImageView + activated constraints) but shows a
/// two-line title/subtitle and a leading icon that distinguishes bundled
/// built-ins from user-authored dynamic skills.
private final class SkillCell: UITableViewCell {

    private let iconView = UIImageView()
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        setupUI()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupUI() {
        backgroundColor = .clear
        selectionStyle = .none

        iconView.contentMode = .scaleAspectFit
        iconView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(iconView)

        titleLabel.font = .systemFont(ofSize: 15, weight: .medium)
        titleLabel.textColor = .label
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(titleLabel)

        subtitleLabel.font = .systemFont(ofSize: 12)
        subtitleLabel.textColor = .secondaryLabel
        subtitleLabel.numberOfLines = 1
        subtitleLabel.lineBreakMode = .byTruncatingTail
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(subtitleLabel)

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            iconView.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 22),
            iconView.heightAnchor.constraint(equalToConstant: 22),

            titleLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 12),
            titleLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            titleLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 11),

            subtitleLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            subtitleLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 2),
        ])
    }

    func configure(title: String, subtitle: String, isDynamic: Bool) {
        titleLabel.text = title
        subtitleLabel.text = subtitle
        // Dynamic skills get the "hammer" (authored on device); built-ins get
        // the generic puzzle-piece extension glyph.
        iconView.image = UIImage(systemName: isDynamic ? "hammer.fill" : "puzzlepiece.extension.fill")
        iconView.tintColor = isDynamic ? .systemOrange : .systemBlue
    }
}

// MARK: - Conversation Model
// `Conversation` moved to Structs/Messaging.swift so the macOS target (which
// excludes UIKit-only files) can still see it from SimpleConversationManager.

// MARK: - Conversation Cell

class ConversationCell: UITableViewCell {
    
    private let titleLabel = UILabel()
    private let lastMessageLabel = UILabel()
    private let timestampLabel = UILabel()
    private let separatorView = UIView()
    
    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        setupUI()
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    private func setupUI() {
        backgroundColor = .clear
        selectionStyle = .none
        
        // Setup title label
        titleLabel.font = UIFont.systemFont(ofSize: 16, weight: .medium)
        titleLabel.textColor = .label
        titleLabel.numberOfLines = 1
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(titleLabel)
        
        // Setup last message label
        lastMessageLabel.font = UIFont.systemFont(ofSize: 14)
        lastMessageLabel.textColor = .secondaryLabel
        lastMessageLabel.numberOfLines = 2
        lastMessageLabel.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(lastMessageLabel)
        
        // Setup timestamp label
        timestampLabel.font = UIFont.systemFont(ofSize: 12)
        timestampLabel.textColor = .tertiaryLabel
        timestampLabel.textAlignment = .right
        timestampLabel.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(timestampLabel)
        
        // Setup separator
        separatorView.backgroundColor = UIColor.separator
        separatorView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(separatorView)
        
        // Setup constraints
        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 12),
            titleLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            titleLabel.trailingAnchor.constraint(equalTo: timestampLabel.leadingAnchor, constant: -8),
            
            timestampLabel.topAnchor.constraint(equalTo: titleLabel.topAnchor),
            timestampLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            timestampLabel.widthAnchor.constraint(equalToConstant: 60),
            
            lastMessageLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 4),
            lastMessageLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            lastMessageLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            lastMessageLabel.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -12),
            
            separatorView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            separatorView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            separatorView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            separatorView.heightAnchor.constraint(equalToConstant: 0.5)
        ])
    }
    
    func configure(with conversation: Conversation, isCurrent: Bool = false) {
        titleLabel.text = conversation.title
        lastMessageLabel.text = conversation.lastMessage
        
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        timestampLabel.text = formatter.string(from: conversation.timestamp)
        
        // Highlight current conversation
        if isCurrent {
            backgroundColor = UIColor.systemBlue.withAlphaComponent(0.1)
            titleLabel.textColor = .systemBlue
        } else {
            backgroundColor = .clear
            titleLabel.textColor = .label
        }
    }
}
