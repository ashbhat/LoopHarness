//
//  SceneDelegate.swift
//  Loop
//
//  Created by Ash Bhat on 11/2/24.
//

import UIKit

class SceneDelegate: UIResponder, UIWindowSceneDelegate {

    var window: UIWindow?

    /// Holds the live onboarding modal while the first-run flow is on screen.
    /// Cleared once the user completes step 3. We hang on to it from this side
    /// so the Action Button intent path (handleMicURL) can ask it whether to
    /// consume the press as the "first message" trigger.
    private var onboardingVC: OnboardingViewController?


    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        // Use this method to optionally configure and attach the UIWindow `window` to the provided UIWindowScene `scene`.
        // If using a storyboard, the `window` property will automatically be initialized and attached to the scene.
        // This delegate does not imply the connecting scene or session are new (see `application:configurationForConnectingSceneSession` instead).
        guard let _ = (scene as? UIWindowScene) else { return }

        // Defer onboarding until after the storyboard has finished hooking
        // up the root view controller; presenting from willConnectTo races
        // the storyboard load.
        DispatchQueue.main.async { [weak self] in
            self?.presentOnboardingIfNeeded()
        }
    }

    func sceneDidDisconnect(_ scene: UIScene) {
        // Called as the scene is being released by the system.
        // This occurs shortly after the scene enters the background, or when its session is discarded.
        // Release any resources associated with this scene that can be re-created the next time the scene connects.
        // The scene may re-connect later, as its session was not necessarily discarded (see `application:didDiscardSceneSessions` instead).
    }

    func sceneDidBecomeActive(_ scene: UIScene) {
        // Called when the scene has moved from an inactive state to an active state.
        // Use this method to restart any tasks that were paused (or not yet started) when the scene was inactive.

        // Reconcile placeholders for every saved scheduled job, then run any
        // jobs whose pre-fetch window has opened since we were last in the
        // foreground. This is the daily-user safety net described in the
        // spec — most happy-path deliveries come from this hook, not from
        // BGProcessingTask. Fire-and-forget; the runner manages its own
        // budget and bookkeeping.
        BackgroundScheduler.shared.reconcileAll()
        BackgroundScheduler.shared.runDueJobs()

        // Drain any images the share extension stashed in the App Group
        // inbox. URL-handoff (commandintel://share?file=...) handles the
        // typical case where iOS launches us with the right intent; this
        // foreground pass is a fallback for when the URL handoff fails or
        // the user lands here through some other surface.
        drainSharedInbox()

        // Keep the screen on while Loop is in the foreground. The app is
        // primarily a conversational surface — locking mid-thought breaks
        // the spell. iOS restores the idle timer automatically when the app
        // backgrounds, but we also unset it explicitly in sceneWillResignActive
        // for hygiene.
        UIApplication.shared.isIdleTimerDisabled = true
    }

    func sceneWillResignActive(_ scene: UIScene) {
        // Called when the scene will move from an active state to an inactive state.
        // This may occur due to temporary interruptions (ex. an incoming phone call).
        UIApplication.shared.isIdleTimerDisabled = false
    }

    func sceneWillEnterForeground(_ scene: UIScene) {
        // Called as the scene transitions from the background to the foreground.
        // Use this method to undo the changes made on entering the background.
    }

    func sceneDidEnterBackground(_ scene: UIScene) {
        // Called as the scene transitions from the foreground to the background.
        // Use this method to save data, release shared resources, and store enough scene-specific state information
        // to restore the scene back to its current state.
    }
    
    // MARK: - URL Handling
    
    func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
        guard let url = URLContexts.first?.url else { return }

        print("Received URL: \(url.absoluteString)")

        // Handle intel://mic URL scheme
        if url.scheme == "intel" && url.host == "mic" {
            handleMicURL()
        }
        else if url.scheme == "commandintel" && url.host == "mic" {
            handleMicURL()
        }
        // Share-extension handoff: commandintel://share?file=<uuid>.<ext>
        // means the share extension wrote an image to the App Group inbox
        // and is asking us to stage it on the message bar.
        else if url.scheme == "commandintel" && url.host == "share" {
            handleShareHandoff(url)
        }
        // Files shared into the app via the system share sheet ("Copy to
        // Loop" / "Open in Loop"). iOS hands us a file:// URL that points
        // into the app's Documents/Inbox folder — copy it into the workspace
        // and stage it on the message bar.
        else if url.isFileURL {
            handleSharedFile(url, openInPlace: URLContexts.first?.options.openInPlace ?? false)
        }
    }

    /// URL handoff from the share extension. Reads the named file out of the
    /// App Group inbox, hands it to AttachmentStore so the bytes land in the
    /// workspace, then stages the resulting FileAttachment on MessagingVC.
    private func handleShareHandoff(_ url: URL) {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let filename = components.queryItems?.first(where: { $0.name == "file" })?.value,
              let inboxURL = SharedInbox.urlForFilename(filename),
              FileManager.default.fileExists(atPath: inboxURL.path)
        else {
            // No specific file named (or it's already been picked up) — fall
            // through to a full drain in case there are stragglers.
            drainSharedInbox()
            return
        }

        let attachment: FileAttachment
        do {
            attachment = try AttachmentStore.shared.saveFromFileURL(inboxURL)
        } catch {
            print("Share handoff copy failed: \(error.localizedDescription)")
            return
        }
        SharedInbox.remove(inboxURL)
        stageOrDefer(attachment)
    }

    /// Foreground-pickup fallback. Walks every pending file in the App Group
    /// inbox, copies each into the workspace, and stages it. Used when the
    /// URL handoff didn't fire (e.g. cold start, share extension on iOS that
    /// couldn't reach openURL through the responder chain).
    private func drainSharedInbox() {
        SharedInbox.drain { url in
            do {
                let attachment = try AttachmentStore.shared.saveFromFileURL(url)
                stageOrDefer(attachment)
                return true
            } catch {
                print("Share inbox drain failed for \(url.lastPathComponent): \(error.localizedDescription)")
                return false
            }
        }
    }

    private func stageOrDefer(_ attachment: FileAttachment) {
        guard let messagingVC = findMessagingVC() else {
            // Cold start path — MessagingVC.viewDidLoad checks
            // SharedAttachmentInbox on launch and consumes whatever's there.
            SharedAttachmentInbox.shared.pending = attachment
            return
        }
        messagingVC.stageIncomingAttachment(attachment)
    }

    /// Receive a file URL from the system share sheet. Copies the bytes into
    /// the workspace via AttachmentStore, then stages the resulting
    /// FileAttachment on the active MessageBox so the user can add a prompt
    /// and hit send. Falls back to NotificationCenter if MessagingVC isn't on
    /// screen yet (cold start path).
    func handleSharedFile(_ url: URL, openInPlace: Bool) {
        let needsScope = openInPlace && url.startAccessingSecurityScopedResource()
        defer { if needsScope { url.stopAccessingSecurityScopedResource() } }

        let attachment: FileAttachment
        do {
            attachment = try AttachmentStore.shared.saveFromFileURL(url)
        } catch {
            print("Shared file copy failed: \(error.localizedDescription)")
            return
        }

        // Drop the original inbox copy iOS made — we've got our own in the
        // workspace now. Only safe for openInPlace == false (the system gave
        // us a temporary file in the inbox we own).
        if !openInPlace {
            try? FileManager.default.removeItem(at: url)
        }

        guard let messagingVC = findMessagingVC() else {
            // Cold start: stash on a one-shot pending box that
            // MessagingVC.viewDidLoad consumes once it's wired up.
            SharedAttachmentInbox.shared.pending = attachment
            return
        }
        messagingVC.stageIncomingAttachment(attachment)
    }

    /// Walk the active scene's root view controller tree to find the live
    /// MessagingVC. Returns nil during cold start, before the storyboard's
    /// initial VC has finished loading.
    private func findMessagingVC() -> MessagingVC? {
        guard let windowScene = window?.windowScene,
              let window = windowScene.windows.first,
              let root = window.rootViewController else { return nil }
        if let nav = root as? UINavigationController {
            for vc in nav.viewControllers {
                if let mvc = vc as? MessagingVC { return mvc }
            }
        }
        if let mvc = root as? MessagingVC { return mvc }
        return nil
    }
    
    func handleMicURL() {
        print("Handling intel://mic URL")

        // Onboarding step 3 ("press the Action Button") consumes the first
        // hardware press as its completion signal. The view dismisses itself
        // and we fall through so the press also kicks off voice capture on
        // MessagingVC — the user sees the live recorder UI the moment the
        // onboarding modal cross-dissolves away.
        onboardingVC?.handleActionButtonPressed()

        // Get the root view controller
        guard let windowScene = window?.windowScene,
              let window = windowScene.windows.first,
              let rootViewController = window.rootViewController else {
            print("Could not get root view controller")
            return
        }

        // Find the MessagingVC in the navigation stack
        if let navigationController = rootViewController as? UINavigationController {
            for viewController in navigationController.viewControllers {
                if let messagingVC = viewController as? MessagingVC {
                    print("Found MessagingVC, triggering voice transcription")
                    messagingVC.toggleVoiceTranscription()
                    return
                }
            }
        }

        // If MessagingVC not found, we might be in a cold start scenario
        // The view controller will be loaded by the storyboard, so we need to wait
        print("MessagingVC not found, this might be a cold start")

        // Store the intent to trigger voice transcription after view loads
        NotificationCenter.default.post(name: NSNotification.Name("TriggerVoiceTranscription"), object: nil)
    }

    // MARK: - Onboarding

    /// Presents the iOS onboarding modal on first launch. No-op once the user
    /// has completed (or already-dismissed) the flow. Called from
    /// scene(_:willConnectTo:) after a runloop hop so the storyboard's initial
    /// view controller is on screen first — the onboarding is layered on top
    /// of it rather than replacing it.
    private func presentOnboardingIfNeeded() {
        guard !OnboardingState.isComplete else { return }
        guard let root = window?.rootViewController else { return }
        // Walk to the topmost presented controller so we don't try to present
        // on a view controller that's already presenting something.
        var top = root
        while let presented = top.presentedViewController { top = presented }

        let vc = OnboardingViewController()
        vc.onCompleted = { [weak self] in
            self?.onboardingVC = nil
        }
        self.onboardingVC = vc
        top.present(vc, animated: true)
    }


}

