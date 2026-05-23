//
//  ImageSkill.swift
//  Loop
//
//  Built from intel/Specs/image_spec.md.
//

import Foundation

/// Side-effect surface ImageGenerationService uses to inject placeholder
/// and final image messages into the chat UI. The host (MessagingVC) owns
/// the messages array; the service lives outside UIKit and only signals
/// state changes.
///
/// Protocol methods are dispatched from the service on the main thread.
/// Retry is handled by the cell delegate calling
/// ImageGenerationService.retry(_:prompt:) directly — no protocol method
/// needed because the placeholder message is already in the host's chat.
protocol ImageSkillHost: AnyObject {
    /// A new generation has started. Insert a synthetic assistant message
    /// carrying `attachment` (in .generating state) so the user immediately
    /// sees a placeholder spinner inline.
    func imageSkillDidStartGenerating(_ attachment: ImageAttachment)
    /// Generation completed (success or failure). Find the placeholder by
    /// `attachment.id` and update it in place — same row, no scroll jump.
    func imageSkillDidFinishGenerating(_ attachment: ImageAttachment)
}

/// Lets Loop generate an image inline in chat through OpenAI's image
/// endpoint (gpt-image-2). The model uses `generate_image` to express
/// intent; ImageSkill makes the HTTP call, saves the PNG to Workspace, and
/// signals the host to render the bubble inline.
///
/// Iteration ("make it darker", "remove the background", etc.) is handled
/// at the LLM layer: the model sees prior turns + the previous prompt and
/// rewrites a new prompt to call the tool again. No img2img dependency.
final class ImageSkill {
    static let shared = ImageSkill()

    static let systemPromptFragment: String = """
You can generate images inline in chat using the generate_image tool.

When to call:
- The user describes an image idea ("draw me…", "show me…", "mockup of…", "moodboard…").
- The user asks to iterate on a previously-generated image ("make it darker", "same scene but cinematic", "remove the background"). In that case, look at the prior generate_image call's prompt and write a new full prompt that incorporates the change — do not pass a delta, the tool always takes a full prompt.

Rules:
- One image per call. The tool currently supports a single image at a time; if the user asks for several variants, call it once and offer to iterate.
- The prompt is what gets sent verbatim to the image model. Be vivid and specific (subject, composition, style, mood, lighting, color palette).
- After the image renders, write a short conversational reply — don't repeat the prompt back at the user, just acknowledge briefly so they can keep iterating.
"""

    static let tools: [[String: Any]] = [
        [
            "type": "function",
            "function": [
                "name": "generate_image",
                "description": "Generate one image inline in chat from a natural-language prompt. The image renders inline in the conversation; the user can download or regenerate it. Use this whenever the user asks for an image, mockup, moodboard, or visual idea — including iterations on a previously-generated image (rewrite the full prompt incorporating the requested change).",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "prompt": [
                            "type": "string",
                            "description": "Full image prompt. Be specific: subject, composition, style, mood, lighting, color palette."
                        ]
                    ],
                    "required": ["prompt"]
                ]
            ]
        ]
    ]

    static let toolNames: Set<String> = [
        "generate_image"
    ]

    func handles(functionName: String) -> Bool {
        return ImageSkill.toolNames.contains(functionName)
    }

    func statusText(for call: FunctionCallStruct) -> String? {
        switch call.name {
        case "generate_image":
            if let p = (call.arguments["prompt"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !p.isEmpty {
                let preview = ImageSkill.truncate(p, to: 60)
                return "drawing \(preview)"
            }
            return "generating image"
        default:
            return nil
        }
    }

    // MARK: - Dispatch

    func handle(functionCall: FunctionCallStruct,
                completion: @escaping (MessageStruct) -> Void) {
        switch functionCall.name {
        case "generate_image":
            guard let prompt = (functionCall.arguments["prompt"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                  !prompt.isEmpty else {
                completion(MessageStruct(
                    role: "function",
                    content: "I need a `prompt` to call generate_image.",
                    name: "generate_image"
                ))
                return
            }
            generateImage(prompt: prompt, completion: completion)
        default:
            completion(MessageStruct(
                role: "assistant",
                content: "I don't know how to handle the Image tool '\(functionCall.name)'."
            ))
        }
    }

    // MARK: - Tool handler

    /// Submit-and-return: hand the request to ImageGenerationService and
    /// reply to the LLM immediately so it can write a short acknowledgment
    /// while the image is still cooking. The image bubble fills in via the
    /// host's didFinishGenerating callback whenever the network completes —
    /// the function result here is just to unblock the chat turn.
    private func generateImage(prompt: String,
                               completion: @escaping (MessageStruct) -> Void) {
        // Pin this generation to whichever conversation is currently active
        // *now*, not whichever one happens to be foreground when the network
        // call finishes. Without this, the user can open a new tab while an
        // image is in flight and the bubble would race into the wrong tab on
        // Mac. The service carries the id through to the host callbacks.
        let convId = SimpleConversationManager.shared.currentConversation?.id
        let attachment = ImageGenerationService.shared.submit(prompt: prompt,
                                                               conversationId: convId)
        let summary = "Image generation queued (id: \(attachment.id)). Image will appear inline in the chat shortly. Acknowledge briefly to the user; do not wait for the image."
        completion(MessageStruct(
            role: "function",
            content: summary,
            name: "generate_image"
        ))
    }

    // MARK: - Helpers

    private static func truncate(_ s: String, to max: Int) -> String {
        if s.count <= max { return s }
        let idx = s.index(s.startIndex, offsetBy: max)
        return String(s[..<idx]) + "…"
    }
}
