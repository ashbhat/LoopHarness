//
//  JSRuntime.swift
//  Loop
//
//  Built from LoopIOS/Specs/2. Loop Local Runtime Spec.md.
//
//  Secure on-device runtime for hot-loadable user skills. Wraps JavaScriptCore
//  (Apple's built-in JS engine — no JIT on iOS, so it runs in interpreter mode,
//  which is what makes it App Store legal for user-supplied code) and exposes a
//  small host surface:
//
//      host.log(msg)          → forwards to the chat UI as shimmer text
//      host.http(opts)        → returns a Promise<{status, headers, body}>
//      host.notify(title,body)→ schedules a local push notification
//      host.sleep(ms)         → Promise<void> for pacing
//      host.callTool(name,args)→ invoke a built-in native tool (e.g.
//                               ssh_client) and await its JSON result
//
//  Skills are .js files with a top-level exported `run(args, host)` function.
//  See Workspace/Skills/<name>/skill.js for the contract.
//

import Foundation
import JavaScriptCore
import UserNotifications

/// Errors surfaced to callers when a skill execution can't complete. Each maps
/// to a json-serializable result the model can reason about.
enum JSRuntimeError: Error, LocalizedError {
    case missingEntryPoint
    case scriptError(String)
    case timedOut
    case invalidResult
    case maxCallDepthExceeded
    case skillNotFound(String)

    var errorDescription: String? {
        switch self {
        case .missingEntryPoint: return "Skill is missing a top-level `run(args, host)` function."
        case .scriptError(let m): return "JS error: \(m)"
        case .timedOut:           return "Skill exceeded its execution time budget."
        case .invalidResult:      return "Skill returned a value that couldn't be serialized to JSON."
        case .maxCallDepthExceeded: return "Skill call depth exceeded maximum (skills calling skills too deeply)."
        case .skillNotFound(let n): return "Skill '\(n)' not found. Check installed skills."
        }
    }
}

/// Wall-clock timeout per skill invocation. Skills can do as much I/O as they
/// want within this window, but won't be allowed to spin forever.
private let defaultTimeoutSeconds: TimeInterval = 30

/// Maximum nesting depth for skill-to-skill calls via `host.callSkill`.
private let maxCallDepth: Int = 5

final class JSRuntime {

    /// Live progress callback fired whenever the skill calls `host.log(...)`.
    /// The registry forwards these to the chat UI's shimmer label.
    typealias LogHandler = (String) -> Void

    /// Closure provided by DynamicSkillRegistry to resolve a skill by name and
    /// execute it, enabling `host.callSkill(name, args)`. The closure receives
    /// (skillName, args, currentDepth, completion).
    typealias SkillCompositionDispatcher = (String, [String: Any], Int, @escaping (Result<Any, Error>) -> Void) -> Void

    private let queue = DispatchQueue(label: "loop.jsruntime", qos: .userInitiated)

    /// Run a skill's source code with a JSON-encodable `args` payload and
    /// return whatever the skill resolves to. The runtime stands up a fresh
    /// `JSContext` per invocation — cheap, and means skills can't bleed
    /// globals into each other. `logHandler` receives every `host.log(...)`
    /// the skill emits while running.
    ///
    /// - Parameters:
    ///   - callDepth: Current nesting depth for skill-to-skill calls.
    ///   - skillDispatcher: Optional closure to resolve `host.callSkill`.
    func run(source: String,
             args: [String: Any],
             logHandler: @escaping LogHandler,
             timeout: TimeInterval = defaultTimeoutSeconds,
             callDepth: Int = 0,
             skillDispatcher: SkillCompositionDispatcher? = nil,
             completion: @escaping (Result<Any, Error>) -> Void) {

        queue.async {
            guard let context = JSContext() else {
                completion(.failure(JSRuntimeError.scriptError("Failed to create JSContext")))
                return
            }

            // Surface uncaught JS exceptions as Swift errors. Without this they
            // print to stderr and the skill silently returns `undefined`.
            var capturedException: String?
            context.exceptionHandler = { _, exception in
                capturedException = exception?.toString() ?? "unknown exception"
            }

            self.installHostBridge(in: context,
                                   logHandler: logHandler,
                                   callDepth: callDepth,
                                   skillDispatcher: skillDispatcher)

            // Evaluate the skill source and prelude. The prelude wires the
            // callback-style host functions exposed from Swift into Promise-
            // returning JS, so skills can use `await host.http(...)`.
            context.evaluateScript(Self.preludeSource)
            if let ex = capturedException {
                completion(.failure(JSRuntimeError.scriptError("prelude: \(ex)")))
                return
            }

            context.evaluateScript(source)
            if let ex = capturedException {
                completion(.failure(JSRuntimeError.scriptError(ex)))
                return
            }

            guard let runFn = context.objectForKeyedSubscript("run"),
                  !runFn.isUndefined, runFn.isObject else {
                completion(.failure(JSRuntimeError.missingEntryPoint))
                return
            }

            // Encode args into a JS object via JSON, the lowest-common-denominator
            // shape. Avoids `JSValue.init(object:)` quirks with NSDictionary type
            // coercion.
            let argsJSON: String = {
                if let data = try? JSONSerialization.data(withJSONObject: args, options: []),
                   let s = String(data: data, encoding: .utf8) { return s }
                return "{}"
            }()
            let parsedArgs = context.evaluateScript("(\(argsJSON))")
            let hostObj = context.objectForKeyedSubscript("host")
            let result = runFn.call(withArguments: [parsedArgs as Any, hostObj as Any])

            if let ex = capturedException {
                completion(.failure(JSRuntimeError.scriptError(ex)))
                return
            }

            // The skill probably returned a Promise. Resolve it with a deadline.
            self.resolve(result, context: context, timeout: timeout) { resolved, error in
                if let error = error {
                    completion(.failure(error))
                    return
                }
                guard let jsValue = resolved else {
                    completion(.success(NSNull()))
                    return
                }
                let raw = jsValue.toObject() ?? NSNull()
                // Force the result through JSONSerialization so the caller
                // gets a clean plist-ish structure; non-serializable values
                // (functions, regexes, etc.) come back as a stringified form.
                if JSONSerialization.isValidJSONObject(raw) {
                    completion(.success(raw))
                } else if let s = jsValue.toString() {
                    completion(.success(s))
                } else {
                    completion(.failure(JSRuntimeError.invalidResult))
                }
            }
        }
    }

    // MARK: - Host bridge

    private func installHostBridge(in context: JSContext,
                                   logHandler: @escaping LogHandler,
                                   callDepth: Int,
                                   skillDispatcher: SkillCompositionDispatcher?) {

        // host.__log(str) — synchronous, just forwards to Swift.
        let log: @convention(block) (String) -> Void = { msg in
            logHandler(msg)
        }

        // host.__http(optsJSON, resolve, reject) — issues a real URLSession
        // request off the JS thread and resolves the JS Promise back on the
        // runtime's queue. opts: { url, method?, headers?, body?, json? }.
        let http: @convention(block) (String, JSValue, JSValue) -> Void = { [weak self] optsJSON, resolveFn, rejectFn in
            self?.performHTTP(optsJSON: optsJSON,
                              resolve: resolveFn,
                              reject: rejectFn)
        }

        // host.notify(title, body) — fire a local push notification immediately.
        // The skill calls this when it has results worth waking the user for.
        let notify: @convention(block) (String, String) -> Void = { title, body in
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            let request = UNNotificationRequest(
                identifier: "skill.notify.\(UUID().uuidString)",
                content: content,
                trigger: nil
            )
            UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
        }

        // host.__sleep(ms, resolve) — Promise-friendly sleep. Hop back onto
        // the runtime queue before invoking the JS callback so all JSValue
        // touches stay on a single serial thread.
        let sleep: @convention(block) (Double, JSValue) -> Void = { [weak self] ms, resolveFn in
            guard let self = self else { return }
            let deadline = DispatchTime.now() + .milliseconds(Int(ms))
            DispatchQueue.global().asyncAfter(deadline: deadline) {
                self.queue.async { resolveFn.call(withArguments: []) }
            }
        }

        // host.__callTool(name, argsJSON, resolve, reject) — invoke a built-in
        // native tool (the same ones the model can call: ssh_client, git_*,
        // github_*, …) through the shared dispatcher and resolve the JS Promise
        // with the tool's parsed JSON result.
        let callTool: @convention(block) (String, String, JSValue, JSValue) -> Void = { [weak self] name, argsJSON, resolveFn, rejectFn in
            self?.performToolCall(name: name,
                                  argsJSON: argsJSON,
                                  resolve: resolveFn,
                                  reject: rejectFn)
        }

        // host.__callSkill(name, argsJSON, resolve, reject) — invoke another
        // skill by name. Enforces max call depth to prevent infinite recursion.
        let callSkill: @convention(block) (String, String, JSValue, JSValue) -> Void = { [weak self] name, argsJSON, resolveFn, rejectFn in
            guard let self = self else { return }

            guard callDepth < maxCallDepth else {
                self.queue.async {
                    rejectFn.call(withArguments: ["Max skill call depth (\(maxCallDepth)) exceeded"])
                }
                return
            }

            guard let dispatcher = skillDispatcher else {
                self.queue.async {
                    rejectFn.call(withArguments: ["Skill composition is not available in this context"])
                }
                return
            }

            let args: [String: Any] = {
                guard let data = argsJSON.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    return [:]
                }
                return obj
            }()

            dispatcher(name, args, callDepth + 1) { result in
                self.queue.async {
                    switch result {
                    case .success(let value):
                        // Serialize to JSON and parse in context for clean hand-off
                        if JSONSerialization.isValidJSONObject(value),
                           let data = try? JSONSerialization.data(withJSONObject: value),
                           let json = String(data: data, encoding: .utf8) {
                            let parsed = context.evaluateScript("(\(json))")
                            resolveFn.call(withArguments: [parsed as Any])
                        } else if let str = value as? String {
                            resolveFn.call(withArguments: [str])
                        } else {
                            resolveFn.call(withArguments: [NSNull()])
                        }
                    case .failure(let error):
                        rejectFn.call(withArguments: [error.localizedDescription])
                    }
                }
            }
        }

        // host.getConfig(key) — synchronous read from the allowed-key config
        // store. Returns the value or null if not set / not an allowed key.
        let getConfig: @convention(block) (String) -> String? = { key in
            return SkillConfigStore.shared.get(rawKey: key)
        }

        let host = JSValue(newObjectIn: context)
        host?.setObject(log,       forKeyedSubscript: "__log"       as NSString)
        host?.setObject(http,      forKeyedSubscript: "__http"      as NSString)
        host?.setObject(notify,    forKeyedSubscript: "notify"      as NSString)
        host?.setObject(sleep,     forKeyedSubscript: "__sleep"     as NSString)
        host?.setObject(callTool,  forKeyedSubscript: "__callTool"  as NSString)
        host?.setObject(callSkill, forKeyedSubscript: "__callSkill" as NSString)
        host?.setObject(getConfig, forKeyedSubscript: "getConfig"   as NSString)
        context.setObject(host, forKeyedSubscript: "host" as NSString)
    }

    /// JS shim that wraps the callback-style host functions into Promise- and
    /// async/await-friendly equivalents. Also installs a `console.log` alias
    /// that flows to `host.log`, since plenty of generated code reaches for
    /// console.log by reflex.
    private static let preludeSource: String = """
    host.log = function(msg) {
        try { host.__log(typeof msg === 'string' ? msg : JSON.stringify(msg)); } catch (e) {}
    };
    host.http = function(opts) {
        return new Promise(function(resolve, reject) {
            try {
                host.__http(JSON.stringify(opts || {}), resolve, reject);
            } catch (e) { reject(e); }
        });
    };
    host.sleep = function(ms) {
        return new Promise(function(resolve) { host.__sleep(ms, resolve); });
    };
    host.callTool = function(name, args) {
        return new Promise(function(resolve, reject) {
            try {
                host.__callTool(String(name), JSON.stringify(args || {}), resolve, reject);
            } catch (e) { reject(e); }
        });
    };
    host.callSkill = function(name, args) {
        return new Promise(function(resolve, reject) {
            try {
                host.__callSkill(name, JSON.stringify(args || {}), resolve, reject);
            } catch (e) { reject(e); }
        });
    };
    var console = {
        log:   function() { host.log(Array.from(arguments).map(String).join(' ')); },
        error: function() { host.log('ERROR: ' + Array.from(arguments).map(String).join(' ')); },
        warn:  function() { host.log('WARN: '  + Array.from(arguments).map(String).join(' ')); }
    };
    """

    // MARK: - Promise resolution

    /// Wait on a value that might be a Promise, with a deadline. Resolves to
    /// the underlying JS value (or an error) so the caller can extract it.
    private func resolve(_ value: JSValue?,
                         context: JSContext,
                         timeout: TimeInterval,
                         completion: @escaping (JSValue?, Error?) -> Void) {

        guard let value = value, !value.isUndefined else {
            completion(nil, nil)
            return
        }

        // If it's not a Promise, just return it directly.
        let isPromise = value.hasProperty("then")
        if !isPromise {
            completion(value, nil)
            return
        }

        var done = false
        let onResolve: @convention(block) (JSValue?) -> Void = { resolved in
            if done { return }
            done = true
            completion(resolved, nil)
        }
        let onReject: @convention(block) (JSValue?) -> Void = { rejected in
            if done { return }
            done = true
            let msg = rejected?.toString() ?? "Promise rejected without a value"
            completion(nil, JSRuntimeError.scriptError(msg))
        }

        let resolveFn = JSValue(object: onResolve, in: context)
        let rejectFn  = JSValue(object: onReject, in: context)
        value.invokeMethod("then", withArguments: [resolveFn as Any, rejectFn as Any])

        // Hard deadline: if the Promise never settles, fail loudly so a
        // misbehaving skill can't pin the runtime.
        queue.asyncAfter(deadline: .now() + timeout) {
            if done { return }
            done = true
            completion(nil, JSRuntimeError.timedOut)
        }
    }

    // MARK: - HTTP

    /// Carry out the URLSession request described by `optsJSON` and resolve
    /// the JS Promise with a `{status, headers, body}` shape. Body is decoded
    /// as UTF-8 text and additionally parsed into `json` when the response
    /// content-type advertises JSON, which is the 99% case for skills hitting
    /// public APIs.
    private func performHTTP(optsJSON: String, resolve: JSValue, reject: JSValue) {
        guard let data = optsJSON.data(using: .utf8),
              let opts = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let urlString = opts["url"] as? String,
              let url = URL(string: urlString) else {
            reject.call(withArguments: ["http: missing or invalid `url`"])
            return
        }

        var request = URLRequest(url: url, timeoutInterval: 25)
        request.httpMethod = (opts["method"] as? String)?.uppercased() ?? "GET"
        if let headers = opts["headers"] as? [String: String] {
            for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
        }
        if let json = opts["json"] {
            if let data = try? JSONSerialization.data(withJSONObject: json, options: []) {
                request.httpBody = data
                if request.value(forHTTPHeaderField: "Content-Type") == nil {
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                }
            }
        } else if let body = opts["body"] as? String {
            request.httpBody = body.data(using: .utf8)
        }

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self = self else { return }
            self.queue.async {
                if let error = error {
                    reject.call(withArguments: [error.localizedDescription])
                    return
                }
                let http = response as? HTTPURLResponse
                let bodyText = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                var result: [String: Any] = [
                    "status":  http?.statusCode ?? 0,
                    "headers": (http?.allHeaderFields as? [String: Any]) ?? [:],
                    "body":    bodyText
                ]
                // Best-effort JSON parsing for convenience.
                let ct = (http?.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
                if ct.contains("json") || ct.isEmpty,
                   let raw = data,
                   let parsed = try? JSONSerialization.jsonObject(with: raw, options: []) {
                    result["json"] = parsed
                }
                resolve.call(withArguments: [result])
            }
        }.resume()
    }

    // MARK: - Native tool calls

    /// Route a `host.callTool(name, args)` through the shared SkillDispatcher —
    /// the same headless router the background scheduler uses — and resolve the
    /// JS Promise with the tool's result. The tool's result message carries a
    /// JSON string in `content`; we parse it back into an object so the skill
    /// gets `{status, …}` rather than a string it has to re-parse.
    ///
    /// Dynamic (user-authored JS) skills are intentionally NOT reachable here:
    /// letting one skill call another would open the door to unbounded
    /// skill→skill recursion, and `callTool` exists to reach the *built-in*
    /// surface. The dispatcher is invoked on the main queue to match the
    /// chat-UI path (some skills touch main-thread state); the JS callback is
    /// hopped back onto the runtime queue so all JSValue touches stay serial.
    private func performToolCall(name: String, argsJSON: String, resolve: JSValue, reject: JSValue) {
        let toolName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !toolName.isEmpty else {
            reject.call(withArguments: ["callTool: a tool `name` is required"])
            return
        }

        // Block re-entry into the dynamic registry — see the doc comment.
        if DynamicSkillRegistry.shared.handles(functionName: toolName) {
            reject.call(withArguments: [
                "callTool can't invoke another user skill ('\(toolName)') — it's limited to built-in tools."
            ])
            return
        }

        let arguments: [String: Any] = {
            guard let data = argsJSON.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return [:] }
            return obj
        }()

        let call = FunctionCallStruct(name: toolName, arguments: arguments)
        DispatchQueue.main.async {
            SkillDispatcher.shared.dispatch(call) { [weak self] message in
                guard let self = self else { return }
                self.queue.async {
                    // `message.content` is the tool's JSON payload. Parse it so
                    // the skill receives a structured object; fall back to the
                    // raw string if it isn't JSON.
                    if let data = message.content.data(using: .utf8),
                       let parsed = try? JSONSerialization.jsonObject(with: data),
                       JSONSerialization.isValidJSONObject(parsed) {
                        resolve.call(withArguments: [parsed])
                    } else {
                        resolve.call(withArguments: [message.content])
                    }
                }
            }
        }
    }
}
