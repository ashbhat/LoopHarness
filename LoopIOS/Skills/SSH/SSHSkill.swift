//
//  SSHSkill.swift
//  Loop
//
//  Exposes an `ssh_client` tool that reads the persisted SSH configuration
//  from SSHConfigStore and executes a shell command over SSH, returning
//  stdout, stderr, and exit code. Uses NIOSSH (Apple's SwiftNIO SSH) for
//  the underlying connection.
//

import Foundation
import NIOCore
import NIOPosix
import NIOSSH
import Crypto

final class SSHSkill {

    static let shared = SSHSkill()
    private init() {}

    // MARK: - System prompt fragment

    static let systemPromptFragment: String = """
    You can execute shell commands on a remote server via SSH:
    - ssh_client: run a command over SSH on the host configured in Settings → SSH.
      Pass `command` (string, the shell command to execute). Optionally pass
      `timeout` (seconds, default 30). Returns stdout, stderr, and exit_code.
      If no SSH configuration is saved, the tool returns an error asking the
      user to configure it in Settings.
    """

    // MARK: - Tool schemas

    static let tools: [[String: Any]] = [
        [
            "type": "function",
            "function": [
                "name": "ssh_client",
                "description": "Execute a shell command on the remote SSH host configured in Settings → SSH. Returns stdout, stderr, and exit_code.",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "command": [
                            "type": "string",
                            "description": "The shell command to execute on the remote host."
                        ],
                        "timeout": [
                            "type": "number",
                            "description": "Optional timeout in seconds (default 30)."
                        ]
                    ],
                    "required": ["command"]
                ]
            ]
        ]
    ]

    static let toolNames: Set<String> = ["ssh_client"]

    func handles(functionName: String) -> Bool {
        SSHSkill.toolNames.contains(functionName)
    }

    func statusText(for call: FunctionCallStruct) -> String? {
        guard call.name == "ssh_client" else { return nil }
        if let cmd = call.arguments["command"] as? String {
            let short = cmd.prefix(40)
            return "running via SSH: \(short)\(cmd.count > 40 ? "…" : "")"
        }
        return "running SSH command"
    }

    // MARK: - Dispatch

    func handle(functionCall: FunctionCallStruct,
                completion: @escaping (MessageStruct) -> Void) {
        guard functionCall.name == "ssh_client" else {
            completion(Self.result(name: functionCall.name,
                                   payload: ["status": "error", "error": "Unknown SSH tool \(functionCall.name)"]))
            return
        }
        execute(args: functionCall.arguments, completion: completion)
    }

    // MARK: - Execution

    private func execute(args: [String: Any],
                         completion: @escaping (MessageStruct) -> Void) {

        let config = SSHConfigStore.shared.config
        guard config.isConfigured else {
            completion(Self.result(name: "ssh_client", payload: [
                "status": "error",
                "error": "SSH is not configured. Please set host, username, and private key in Settings → SSH."
            ]))
            return
        }

        guard let command = args["command"] as? String, !command.isEmpty else {
            completion(Self.result(name: "ssh_client", payload: [
                "status": "error",
                "error": "The `command` argument is required."
            ]))
            return
        }

        let timeout = (args["timeout"] as? NSNumber)?.doubleValue ?? 30.0

        Task {
            do {
                let result = try await self.runSSHCommand(
                    host: config.host,
                    port: config.port,
                    username: config.username,
                    privateKey: config.privateKey,
                    passphrase: config.passphrase,
                    command: command,
                    timeout: timeout
                )
                completion(Self.result(name: "ssh_client", payload: [
                    "status": "ok",
                    "stdout": result.stdout,
                    "stderr": result.stderr,
                    "exit_code": result.exitCode
                ]))
            } catch {
                completion(Self.result(name: "ssh_client", payload: [
                    "status": "error",
                    "error": error.localizedDescription
                ]))
            }
        }
    }

    // MARK: - NIOSSH connection

    struct CommandResult {
        let stdout: String
        let stderr: String
        let exitCode: Int
    }

    private func runSSHCommand(host: String,
                               port: Int,
                               username: String,
                               privateKey: String,
                               passphrase: String,
                               command: String,
                               timeout: Double) async throws -> CommandResult {

        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { try? group.syncShutdownGracefully() }

        let nioKey = try parsePrivateKey(pem: privateKey, passphrase: passphrase)

        let bootstrap = ClientBootstrap(group: group)
            .channelInitializer { channel in
                channel.pipeline.addHandlers([
                    NIOSSHHandler(
                        role: .client(
                            .init(
                                userAuthDelegate: SSHPrivateKeyAuthDelegate(
                                    username: username,
                                    privateKey: nioKey
                                ),
                                serverAuthDelegate: SSHAcceptAllHostKeysDelegate()
                            )
                        ),
                        allocator: channel.allocator,
                        inboundChildChannelInitializer: nil
                    )
                ])
            }
            .connectTimeout(.seconds(Int64(min(timeout, 10))))

        let channel = try await bootstrap.connect(host: host, port: port).get()

        let result: CommandResult = try await withCheckedThrowingContinuation { continuation in
            channel.pipeline.handler(type: NIOSSHHandler.self).whenSuccess { sshHandler in
                let promise = channel.eventLoop.makePromise(of: Channel.self)

                sshHandler.createChannel(promise, channelType: .session) { childChannel, channelType in
                    guard case .session = channelType else {
                        return childChannel.eventLoop.makeFailedFuture(SSHSkillError.unexpectedChannelType)
                    }
                    let collector = SSHOutputCollector(continuation: continuation)
                    return childChannel.pipeline.addHandlers([
                        SSHExecHandler(command: command, collector: collector)
                    ])
                }

                promise.futureResult.whenFailure { error in
                    continuation.resume(throwing: error)
                }
            }

            channel.pipeline.handler(type: NIOSSHHandler.self).whenFailure { error in
                continuation.resume(throwing: error)
            }

            // Timeout watchdog
            channel.eventLoop.scheduleTask(in: .seconds(Int64(timeout))) {
                continuation.resume(throwing: SSHSkillError.timeout)
                channel.close(promise: nil)
            }
        }

        try? await channel.close()
        return result
    }

    // MARK: - Key parsing

    private func parsePrivateKey(pem: String, passphrase: String) throws -> NIOSSHPrivateKey {
        let trimmed = pem.trimmingCharacters(in: .whitespacesAndNewlines)

        // Try ECDSA P-256 PEM
        if let p256 = try? P256.Signing.PrivateKey(pemRepresentation: trimmed) {
            return NIOSSHPrivateKey(p256Key: p256)
        }

        // Try P-384
        if let p384 = try? P384.Signing.PrivateKey(pemRepresentation: trimmed) {
            return NIOSSHPrivateKey(p384Key: p384)
        }

        // Try P-521
        if let p521 = try? P521.Signing.PrivateKey(pemRepresentation: trimmed) {
            return NIOSSHPrivateKey(p521Key: p521)
        }

        // Try Ed25519 from raw base64
        let base64Body = Self.stripPEMHeaders(trimmed)
        if let rawData = Data(base64Encoded: base64Body) {
            if rawData.count == 32 {
                let ed = try Curve25519.Signing.PrivateKey(rawRepresentation: rawData)
                return NIOSSHPrivateKey(ed25519Key: ed)
            }
            if rawData.count == 64 {
                let ed = try Curve25519.Signing.PrivateKey(rawRepresentation: rawData.prefix(32))
                return NIOSSHPrivateKey(ed25519Key: ed)
            }
        }

        throw SSHSkillError.unsupportedKeyFormat
    }

    private static func stripPEMHeaders(_ pem: String) -> String {
        pem.components(separatedBy: .newlines)
            .filter { !$0.hasPrefix("-----") && !$0.isEmpty }
            .joined()
    }

    // MARK: - Result helper

    static func result(name: String, payload: [String: Any]) -> MessageStruct {
        let json = (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        return MessageStruct(role: "function", content: json, name: name)
    }
}

// MARK: - Errors

enum SSHSkillError: LocalizedError {
    case timeout
    case unsupportedKeyFormat
    case unexpectedChannelType
    case connectionFailed(String)

    var errorDescription: String? {
        switch self {
        case .timeout:
            return "SSH command timed out."
        case .unsupportedKeyFormat:
            return "Unsupported private key format. Please use an Ed25519 or ECDSA (P-256/P-384/P-521) key in PEM format."
        case .unexpectedChannelType:
            return "Unexpected SSH channel type."
        case .connectionFailed(let msg):
            return "SSH connection failed: \(msg)"
        }
    }
}

// MARK: - NIOSSH delegates

private final class SSHPrivateKeyAuthDelegate: NIOSSHClientUserAuthenticationDelegate {
    private let username: String
    private let privateKey: NIOSSHPrivateKey

    init(username: String, privateKey: NIOSSHPrivateKey) {
        self.username = username
        self.privateKey = privateKey
    }

    func nextAuthenticationType(
        availableMethods: NIOSSHAvailableUserAuthenticationMethods,
        nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
    ) {
        if availableMethods.contains(.publicKey) {
            nextChallengePromise.succeed(.init(
                username: username,
                serviceName: "ssh-connection",
                offer: .privateKey(.init(privateKey: privateKey))
            ))
        } else {
            nextChallengePromise.succeed(nil)
        }
    }
}

private final class SSHAcceptAllHostKeysDelegate: NIOSSHClientServerAuthenticationDelegate {
    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        validationCompletePromise.succeed(())
    }
}

// MARK: - Channel handler

/// Combined exec + output collection handler. Sends the exec request on
/// channelActive, collects stdout/stderr, and resolves the continuation
/// on channel close or exit status.
private final class SSHExecHandler: ChannelDuplexHandler {
    typealias InboundIn = SSHChannelData
    typealias InboundOut = ByteBuffer
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = SSHChannelData

    private let command: String
    private weak var collector: SSHOutputCollector?

    init(command: String, collector: SSHOutputCollector) {
        self.command = command
        self.collector = collector
    }

    func channelActive(context: ChannelHandlerContext) {
        let execRequest = SSHChannelRequestEvent.ExecRequest(command: command, wantReply: true)
        context.triggerUserOutboundEvent(execRequest, promise: nil)
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let channelData = unwrapInboundIn(data)
        guard case .byteBuffer(let bytes) = channelData.data else { return }

        switch channelData.type {
        case .channel:
            collector?.appendStdout(bytes)
        case .stdErr:
            collector?.appendStderr(bytes)
        default:
            break
        }
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if let status = event as? SSHChannelRequestEvent.ExitStatus {
            collector?.setExitCode(status.exitStatus)
        }
        context.fireUserInboundEventTriggered(event)
    }

    func channelInactive(context: ChannelHandlerContext) {
        collector?.complete()
        context.fireChannelInactive()
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        collector?.complete()
    }
}

/// Collects output from the SSH exec channel and resolves the async
/// continuation when complete.
private final class SSHOutputCollector {
    private var stdoutData = Data()
    private var stderrData = Data()
    private var exitCode: Int?
    private var continuation: CheckedContinuation<SSHSkill.CommandResult, Error>?
    private var completed = false

    init(continuation: CheckedContinuation<SSHSkill.CommandResult, Error>) {
        self.continuation = continuation
    }

    func appendStdout(_ buffer: ByteBuffer) {
        var buf = buffer
        if let bytes = buf.readBytes(length: buf.readableBytes) {
            stdoutData.append(contentsOf: bytes)
        }
    }

    func appendStderr(_ buffer: ByteBuffer) {
        var buf = buffer
        if let bytes = buf.readBytes(length: buf.readableBytes) {
            stderrData.append(contentsOf: bytes)
        }
    }

    func setExitCode(_ code: Int) {
        exitCode = code
    }

    func complete() {
        guard !completed else { return }
        completed = true
        let result = SSHSkill.CommandResult(
            stdout: String(data: stdoutData, encoding: .utf8) ?? "",
            stderr: String(data: stderrData, encoding: .utf8) ?? "",
            exitCode: exitCode ?? -1
        )
        continuation?.resume(returning: result)
        continuation = nil
    }
}
