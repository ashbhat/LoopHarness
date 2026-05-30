//
//  SSHTerminalSession.swift
//  Loop
//
//  Interactive SSH shell transport over NIOSSH. Where `SSHSkill` opens a
//  one-shot `exec` channel, this opens a PTY + interactive `shell` channel and
//  streams bytes in both directions — the data path behind the in-app terminal
//  (`SSHTerminalViewController` + SwiftTerm).
//
//  It deliberately imports only NIO/Foundation (no UIKit, no SwiftTerm) so it
//  stays platform-neutral and compiles in every target that links NIOSSH. The
//  terminal UI talks to it purely through the `onData` / `onClosed` callbacks
//  and the `send` / `resize` / `disconnect` methods. Both callbacks are
//  delivered on the main queue.
//
//  Authentication and host-key handling reuse the same primitives the
//  `ssh_client` skill uses (`SSHSkill.parsePrivateKey`,
//  `SSHPrivateKeyAuthDelegate`, `SSHAcceptAllHostKeysDelegate`), so a key that
//  works for one-shot commands works here too.
//

import Foundation
import NIOCore
import NIOPosix
import NIOSSH
import os

final class SSHTerminalSession {

    /// Connection parameters, derived from the saved `SSHConfig`.
    struct Config {
        let host: String
        let port: Int
        let username: String
        let privateKey: String
        let passphrase: String
        let term: String

        init(_ config: SSHConfig, term: String = "xterm-256color") {
            host = config.host
            port = config.port == 0 ? 22 : config.port
            username = config.username
            privateKey = config.privateKey
            passphrase = config.passphrase
            self.term = term
        }
    }

    // MARK: - Callbacks (invoked on the main queue)

    /// Bytes received from the remote shell (stdout + stderr), to be fed to the
    /// terminal emulator for display.
    var onData: ((ArraySlice<UInt8>) -> Void)?

    /// The session ended. `reason` is nil for a clean close, otherwise a short
    /// human-readable description (auth failure, connection error, exit signal…).
    var onClosed: ((String?) -> Void)?

    // MARK: - State

    private static let log = Logger(subsystem: "com.bhat.intel", category: "SSHTerminal")

    private let config: Config
    private var group: MultiThreadedEventLoopGroup?
    private var channel: Channel?
    private var sessionChannel: Channel?
    private var closeReason: String?
    private var didClose = false

    init(config: Config) {
        self.config = config
    }

    // MARK: - Lifecycle

    /// Opens the connection and requests a PTY of the given size plus an
    /// interactive shell. Safe to call once per instance.
    func connect(cols: Int, rows: Int) {
        let initialWindow = (cols: max(cols, 1), rows: max(rows, 1))

        let nioKey: NIOSSHPrivateKey
        do {
            nioKey = try SSHSkill.shared.parsePrivateKey(
                pem: config.privateKey, passphrase: config.passphrase)
        } catch {
            Self.log.error("key parse failed: \(error.localizedDescription, privacy: .public)")
            finish(error.localizedDescription)
            return
        }

        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        self.group = group

        let authDelegate = SSHPrivateKeyAuthDelegate(username: config.username, privateKey: nioKey)
        let hostKeyDelegate = SSHAcceptAllHostKeysDelegate()

        let bootstrap = ClientBootstrap(group: group)
            .channelInitializer { [weak self] channel in
                channel.eventLoop.makeCompletedFuture {
                    let sshHandler = NIOSSHHandler(
                        role: .client(.init(
                            userAuthDelegate: authDelegate,
                            serverAuthDelegate: hostKeyDelegate)),
                        allocator: channel.allocator,
                        inboundChildChannelInitializer: nil)
                    try channel.pipeline.syncOperations.addHandler(sshHandler)
                    try channel.pipeline.syncOperations.addHandler(
                        SSHErrorHandler { [weak self] error in self?.handleError(error) })
                }
            }
            .channelOption(ChannelOptions.socket(SocketOptionLevel(IPPROTO_TCP), TCP_NODELAY), value: 1)
            .connectTimeout(.seconds(15))

        Self.log.info("connecting \(self.config.host, privacy: .public):\(self.config.port, privacy: .public) user=\(self.config.username, privacy: .public)")

        bootstrap.connect(host: config.host, port: config.port).whenComplete { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                Self.log.error("connect failed: \(error.localizedDescription, privacy: .public)")
                self.finish(self.describe(error))
            case .success(let channel):
                self.channel = channel
                channel.closeFuture.whenComplete { [weak self] _ in
                    guard let self else { return }
                    self.finish(self.closeReason)
                }
                self.openSession(on: channel, initialWindow: initialWindow)
            }
        }
    }

    /// Sends user keystrokes / pasted text to the remote shell.
    func send(_ data: Data) {
        guard let sessionChannel else { return }
        sessionChannel.eventLoop.execute {
            var buffer = sessionChannel.allocator.buffer(capacity: data.count)
            buffer.writeBytes(data)
            let payload = SSHChannelData(type: .channel, data: .byteBuffer(buffer))
            sessionChannel.writeAndFlush(payload, promise: nil)
        }
    }

    /// Notifies the remote of a new terminal window size (SSH `window-change`).
    func resize(cols: Int, rows: Int) {
        guard cols > 0, rows > 0, let sessionChannel else { return }
        sessionChannel.eventLoop.execute {
            let event = SSHChannelRequestEvent.WindowChangeRequest(
                terminalCharacterWidth: cols,
                terminalRowHeight: rows,
                terminalPixelWidth: 0,
                terminalPixelHeight: 0)
            sessionChannel.triggerUserOutboundEvent(event, promise: nil)
        }
    }

    /// Tears the connection down. The `onClosed` callback fires once the channel
    /// has finished closing.
    func disconnect() {
        if let channel {
            channel.close(promise: nil)
        } else {
            finish(closeReason)
        }
    }

    // MARK: - Session channel

    private func openSession(on channel: Channel, initialWindow: (cols: Int, rows: Int)) {
        channel.pipeline.handler(type: NIOSSHHandler.self).whenComplete { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                self.handleError(error)
            case .success(let sshHandler):
                let promise = channel.eventLoop.makePromise(of: Channel.self)
                sshHandler.createChannel(promise, channelType: .session) { [weak self] childChannel, channelType in
                    guard let self else {
                        return childChannel.eventLoop.makeFailedFuture(SSHTerminalError.unexpectedChannelType)
                    }
                    guard case .session = channelType else {
                        return childChannel.eventLoop.makeFailedFuture(SSHTerminalError.unexpectedChannelType)
                    }
                    return childChannel.eventLoop.makeCompletedFuture {
                        let handler = SSHTerminalChannelHandler(
                            term: self.config.term,
                            initialWindowSize: initialWindow,
                            onData: { [weak self] bytes in
                                guard let self else { return }
                                DispatchQueue.main.async { self.onData?(bytes) }
                            },
                            onExit: { [weak self] reason in self?.recordCloseReason(reason) })
                        let sync = childChannel.pipeline.syncOperations
                        try sync.addHandler(handler)
                        try sync.addHandler(SSHErrorHandler { [weak self] error in self?.handleError(error) })
                    }
                }

                promise.futureResult.whenComplete { [weak self] result in
                    guard let self else { return }
                    switch result {
                    case .failure(let error):
                        self.handleError(error)
                    case .success(let childChannel):
                        Self.log.info("shell session open")
                        self.sessionChannel = childChannel
                    }
                }
            }
        }
    }

    // MARK: - Teardown helpers

    private func recordCloseReason(_ reason: String?) {
        // Runs on an event-loop thread; the value is read back when closeFuture
        // resolves on the same channel, so no extra synchronization is needed.
        if closeReason == nil { closeReason = reason }
    }

    private func handleError(_ error: Error) {
        Self.log.error("session error: \(error.localizedDescription, privacy: .public)")
        recordCloseReason(describe(error))
        channel?.close(promise: nil)
        if channel == nil { finish(describe(error)) }
    }

    /// Delivers the terminal-closed notification exactly once, on the main queue,
    /// and shuts the event-loop group down off the event-loop thread.
    private func finish(_ reason: String?) {
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.didClose else { return }
            self.didClose = true
            self.onClosed?(reason)
        }
        if let group {
            self.group = nil
            group.shutdownGracefully { _ in }
        }
    }

    private func describe(_ error: Error) -> String {
        if let local = error as? LocalizedError, let desc = local.errorDescription {
            return desc
        }
        return String(describing: error)
    }
}

// MARK: - Errors

enum SSHTerminalError: LocalizedError {
    case unexpectedChannelType

    var errorDescription: String? {
        switch self {
        case .unexpectedChannelType: return "Unexpected SSH channel type."
        }
    }
}

// MARK: - Channel handlers

/// Catches pipeline errors and forwards them, then closes the channel.
private final class SSHErrorHandler: ChannelInboundHandler {
    typealias InboundIn = Any

    private let onError: (Error) -> Void

    init(onError: @escaping (Error) -> Void) {
        self.onError = onError
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        onError(error)
        context.close(promise: nil)
    }
}

/// Requests a PTY + interactive shell on `channelActive`, streams inbound
/// stdout/stderr to `onData`, and reports exit status/signal via `onExit`.
private final class SSHTerminalChannelHandler: ChannelInboundHandler {
    typealias InboundIn = SSHChannelData

    private let term: String
    private let initialWindowSize: (cols: Int, rows: Int)
    private let onData: (ArraySlice<UInt8>) -> Void
    private let onExit: (String?) -> Void

    init(term: String,
         initialWindowSize: (cols: Int, rows: Int),
         onData: @escaping (ArraySlice<UInt8>) -> Void,
         onExit: @escaping (String?) -> Void) {
        self.term = term
        self.initialWindowSize = initialWindowSize
        self.onData = onData
        self.onExit = onExit
    }

    func handlerAdded(context: ChannelHandlerContext) {
        context.channel.setOption(ChannelOptions.allowRemoteHalfClosure, value: true).whenFailure { error in
            context.fireErrorCaught(error)
        }
    }

    func channelActive(context: ChannelHandlerContext) {
        let pty = SSHChannelRequestEvent.PseudoTerminalRequest(
            wantReply: true,
            term: term,
            terminalCharacterWidth: initialWindowSize.cols,
            terminalRowHeight: initialWindowSize.rows,
            terminalPixelWidth: 0,
            terminalPixelHeight: 0,
            terminalModes: SSHTerminalModes([:]))
        context.triggerUserOutboundEvent(pty, promise: nil)
        context.triggerUserOutboundEvent(SSHChannelRequestEvent.ShellRequest(wantReply: true), promise: nil)
        context.fireChannelActive()
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let payload = unwrapInboundIn(data)
        guard case .byteBuffer(var buffer) = payload.data,
              let bytes = buffer.readBytes(length: buffer.readableBytes),
              !bytes.isEmpty else { return }

        // Chunk large reads so the UI can interleave display updates.
        let chunkSize = 4096
        var next = 0
        while next < bytes.count {
            let end = min(next + chunkSize, bytes.count)
            onData(bytes[next..<end])
            next = end
        }
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if let status = event as? SSHChannelRequestEvent.ExitStatus {
            onExit(status.exitStatus == 0 ? nil : "Session exited with status \(status.exitStatus).")
        } else if let signal = event as? SSHChannelRequestEvent.ExitSignal {
            onExit("Session terminated by signal \(signal.signalName).")
        }
        context.fireUserInboundEventTriggered(event)
    }
}
