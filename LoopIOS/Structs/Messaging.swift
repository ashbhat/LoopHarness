//
//  Messaging.swift
//  Loop
//
//  Created by Ash Bhat on 11/2/24.
//

import Foundation
import CoreLocation

enum MesssageActions {
    case upload_driver_id
}

/// Lightweight projection of a SimpleConversation for sidebar/list rendering.
/// Lives here (not in SideDrawerViewController.swift) so the macOS target can
/// see it without pulling in UIKit.
struct Conversation {
    let id: String
    let title: String
    let lastMessage: String
    let timestamp: Date
}

struct FunctionCallStruct {
    var name: String
    var arguments: [String: Any]
    /// Provider-issued id for this call. Anthropic returns it as `tool_use.id`;
    /// OpenAI returns it as `tool_calls[].id`. Carried so the matching tool
    /// result can pair back to this call via `MessageStruct.callId`. Nil for
    /// legacy messages that pre-date structured tool blocks.
    var callId: String? = nil
    /// Conversation the call originated from. Stamped by the dispatching
    /// coordinator (Mac per-tab, iOS single-thread) BEFORE handing the
    /// call to a skill, so the skill never has to fall back on the
    /// global `SimpleConversationManager.currentConversation` — that
    /// global tracks the user's active tab and is unsafe to read from
    /// async tool dispatch on multi-tab Mac (user can switch tabs between
    /// the model emitting the tool call and the skill handling it).
    /// Skills that need conversation context (SubAgentSkill,
    /// TerminalSkill) read this first, fall back to the global, and only
    /// then give up.
    var conversationId: String? = nil
}

struct MessageStruct {
    var id: String = UUID().uuidString
    var role: String
    var content: String
    var model: String = "GPT 5.5 Instant"
    var name: String? = nil
    /// All function calls emitted in this assistant turn. Anthropic and OpenAI
    /// can return multiple `tool_use` / `tool_calls` entries in a single
    /// response — keeping them in one MessageStruct preserves the "one
    /// assistant turn, many calls" shape the providers expect on replay.
    var functions: [FunctionCallStruct] = []
    /// Back-compat shim — most call sites still read `.function` as a single
    /// optional. Reading returns the first call; writing replaces the array
    /// with one entry (or clears it on nil).
    var function: FunctionCallStruct? {
        get { functions.first }
        set {
            if let v = newValue { functions = [v] }
            else { functions = [] }
        }
    }
    /// Set on a `role:"function"` tool-result message — matches the `callId`
    /// of the originating `FunctionCallStruct` so the wire payload can pair
    /// `tool_use` with `tool_result` (Anthropic) or `tool_calls[].id` with
    /// `role:"tool"` (OpenAI).
    var callId: String? = nil
    var actions: [MesssageActions] = []
    var polling_locations: [PollLocationStruct] = []
    /// Attached generated image, if any. Set by ImageSkill via the host
    /// protocol so the cell can render it inline. Mutable so the cell can
    /// flip status from .generating → .ready/.failed without rebuilding the
    /// whole message.
    var imageAttachment: ImageAttachment? = nil
    /// User-uploaded image or PDF attached to this turn. Kept separate from
    /// `imageAttachment` so the ImageSkill output flow and the user-upload
    /// input flow can coexist on the same message in the future.
    var fileAttachment: FileAttachment? = nil

    /// Explicit init that still accepts `function:` as a singular optional —
    /// keeps existing call sites compiling now that `function` is a computed
    /// view over the underlying `functions` array.
    init(id: String = UUID().uuidString,
         role: String,
         content: String,
         model: String = "GPT 5.5 Instant",
         name: String? = nil,
         function: FunctionCallStruct? = nil,
         functions: [FunctionCallStruct] = [],
         callId: String? = nil,
         actions: [MesssageActions] = [],
         polling_locations: [PollLocationStruct] = [],
         imageAttachment: ImageAttachment? = nil,
         fileAttachment: FileAttachment? = nil) {
        self.id = id
        self.role = role
        self.content = content
        self.model = model
        self.name = name
        // If a caller passes the singular `function`, prefer it; otherwise
        // use the plural array as-is. Callers don't pass both.
        if let function = function {
            self.functions = [function]
        } else {
            self.functions = functions
        }
        self.callId = callId
        self.actions = actions
        self.polling_locations = polling_locations
        self.imageAttachment = imageAttachment
        self.fileAttachment = fileAttachment
    }

    /// Generic JSON representation of the message. Provider-specific chat
    /// clients (`AnthropicChat`, `OpenAIChat`) build their own per-request
    /// payloads from `MessageStruct` fields directly and ignore the
    /// `attachment`/`attachment_type` keys produced here.
    var dict: [String: Any] {
        var out: [String: Any] = ["role": role, "content": content]
        if let name = name { out["name"] = name }
        if let f = fileAttachment,
           f.status == .ready,
           let data = try? Data(contentsOf: f.fileURL) {
            out["attachment"] = data.base64EncodedString()
            out["attachment_type"] = (f.kind == .pdf) ? "PDF" : "JPEG"
        }
        return out
    }
}

/// User-uploaded file attached to an outgoing message. Persisted in the
/// workspace's `attachments/` folder so the URL survives app restarts and
/// CloudKit sync. Status starts at `.pending` while we're copying the bytes
/// off the picker's security-scoped URL and flips to `.ready` once the file
/// is durable in the workspace.
struct FileAttachment: Codable {
    enum Kind: String, Codable, Equatable {
        case image
        case pdf
    }

    enum Status: String, Codable, Equatable {
        case pending
        case ready
        case failed
    }

    let id: String
    /// Absolute URL to the file inside `Workspace.shared.rootURL`. Persisting
    /// the resolved URL keeps the storage iCloud-synced; downstream code can
    /// re-derive a workspace-relative path via `Workspace.shared.relativePath`.
    var fileURL: URL
    let fileName: String
    let kind: Kind
    let mimeType: String
    var status: Status
    var failureReason: String?
    /// For PDFs: text extracted from the document at save time so the model
    /// can read the contents inline. Truncated to a fixed cap (see
    /// `MessageStruct.dict`) to keep the chat payload reasonable. Nil for
    /// images — those need vision support on the backend to be useful.
    var extractedText: String?

    init(id: String = UUID().uuidString,
         fileURL: URL,
         fileName: String,
         kind: Kind,
         mimeType: String,
         status: Status = .ready,
         failureReason: String? = nil,
         extractedText: String? = nil) {
        self.id = id
        self.fileURL = fileURL
        self.fileName = fileName
        self.kind = kind
        self.mimeType = mimeType
        self.status = status
        self.failureReason = failureReason
        self.extractedText = extractedText
    }

    /// Maximum number of characters from `extractedText` to inline in a
    /// chat message body. Roughly 40KB at one byte per char — enough for
    /// most short-to-medium PDFs without blowing past sensible token limits.
    static let extractedTextCharCap = 40_000

    /// Compact human-and-model-readable tag that gets appended to the chat
    /// message's `content` so the assistant knows a file is attached. The
    /// path uses a `workspace://` prefix so it's unambiguous about where to
    /// look. For PDFs we additionally inline the extracted text between
    /// fenced markers so the model can answer questions about the file
    /// without needing a tool call.
    var assistantHint: String {
        let kindLabel = (kind == .pdf) ? "PDF" : "image"
        let workspaceRelative = fileURL.lastPathComponent
        let header = "[Attached file: \(fileName) (\(kindLabel)) at workspace://attachments/\(workspaceRelative)]"

        guard let text = extractedText, !text.isEmpty else {
            return header
        }
        let truncated: String
        if text.count > Self.extractedTextCharCap {
            let endIndex = text.index(text.startIndex, offsetBy: Self.extractedTextCharCap)
            truncated = String(text[..<endIndex]) + "\n\n[...truncated, full file in workspace...]"
        } else {
            truncated = text
        }
        return """
        \(header)
        [File content begin]
        \(truncated)
        [File content end]
        """
    }
}

/// Inline image attached to a chat message. Created in the .generating state
/// when an image-generation tool call kicks off, then mutated in place to
/// .ready (with fileURL) or .failed (with reason) when the call completes.
struct ImageAttachment {
    enum Status: Equatable {
        case generating
        case ready
        case failed
    }

    let id: String
    let prompt: String
    var fileURL: URL?
    var status: Status
    var failureReason: String?
    /// Conversation the generation belongs to. Captured at submit time so the
    /// host can route the bubble to the right tab on multi-tab Mac, even if
    /// the user switches tabs between "tool call fired" and "image ready".
    /// Optional for backward compatibility with callers (iOS / older paths)
    /// that don't supply it — those clients render whatever conversation is
    /// currently visible, which is the right behavior for single-tab UIs.
    let conversationId: String?

    init(id: String = UUID().uuidString,
         prompt: String,
         fileURL: URL? = nil,
         status: Status = .generating,
         failureReason: String? = nil,
         conversationId: String? = nil) {
        self.id = id
        self.prompt = prompt
        self.fileURL = fileURL
        self.status = status
        self.failureReason = failureReason
        self.conversationId = conversationId
    }
}

struct PollLocationStruct {
    var name: String
    var full_address: String
    var polling_hours: String
    var location: CLLocationCoordinate2D
    var startDate: String
    var endDate: String
    
    var stringRepresentation: String {
        return "{address: \(full_address), polling_hours: \(polling_hours), location_lat: \(location.latitude), location_lon: \(location.longitude), startDate: \(startDate), endDate: \(endDate) }"
    }
}


var tools: [[String: Any]] = {
    var all: [[String: Any]] = []
    all += NotionSkill.tools
    all += SlackSkill.tools
    all += SchedulerSkill.tools
    all += ExaSkill.tools
    all += URLFetchSkill.tools
    all += GitSkill.tools
    all += GitHubSkill.tools
    all += SelfImprovementSkill.tools
    all += FileSystemSkill.tools
    all += SpecBuilderSkill.tools
    all += LocationSkill.tools
    all += ImageSkill.tools
    all += ObsidianSkill.tools
    all += CalendarSkill.tools
    all += MusicSkill.tools
    all += SkillBuilderSkill.tools
    all += SubAgentSkill.tools
    all += IntegrationSkill.tools
    all += CursorSkill.tools
    all += DevinSkill.tools
    // Dynamic, user-authored skills get appended in AgentHarness at every
    // chat turn so newly hot-loaded skills become visible without restart.
    return all
}()
