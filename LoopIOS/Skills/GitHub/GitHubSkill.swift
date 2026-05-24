//
//  GitHubSkill.swift
//  Loop
//
//  Personal-only GitHub integration. Reads the user's PAT from KeyStore
//  (Settings → Keys → GitHub Personal Access Token) and talks directly to the
//  REST API at api.github.com (or a GHE host if `GITHUB_BASE_URL` is set) — no
//  Loop backend in the path, no OAuth dance.
//
//  Mirrors SlackSkill's shape (and Notion's) so SkillDispatcher routes calls
//  the same way. Side-effecting tools — review_pull_request, comment_pull_request,
//  merge_pull_request, create_pull_request, create_issue, comment_issue,
//  close_issue, mark_notification_read — route through GitHubSkillHost so the
//  iOS / Mac / vision chat surface can present a confirmation alert before the
//  call fires. Reads never confirm.
//
//  Repo cloning is delegated to GitSkill (clone_github_repo is a thin glue
//  that pulls the PAT out of KeyStore so the user never pastes it into chat).
//  Working-tree git operations stay in GitSkill / SwiftGitX.
//

import Foundation

/// Host plumbing that lets the skill ask the UI layer to confirm a destructive
/// or visible action before it hits the GitHub API. MessagingVC (iOS),
/// ConversationWindowController (macOS), and VisionSession (visionOS) conform.
protocol GitHubSkillHost: AnyObject {
    /// One generic confirmation hook for every write tool. The skill builds a
    /// human-readable title + detail message and the host shows whatever modal
    /// is native to the surface. Returning true sends; false cancels.
    func githubSkill(requestConfirmation title: String,
                     detail: String,
                     destructive: Bool,
                     completion: @escaping (Bool) -> Void)
}

final class GitHubSkill {

    static let shared = GitHubSkill()

    /// Set by the chat-surface host on launch so write tools can request a
    /// confirmation alert. Nil in headless contexts (BackgroundScheduler,
    /// SubAgentRuntime) — write tools refuse rather than fire silently.
    weak var host: GitHubSkillHost?

    private init() {}

    // MARK: - System prompt

    static let systemPromptFragment: String = """
You can read and act on the user's GitHub through these tools. Authentication is a personal access token stored in Settings → Keys → GitHub Personal Access Token; if a call returns `github_not_connected`, tell the user to paste one.

Reads (no confirmation):
- github_whoami: verify the token and return the connected login. Call this first if you're unsure whether GitHub is configured.
- list_github_repos: list the user's repositories, newest-updated first. `affiliation` defaults to "owner,collaborator,organization_member".
- get_github_repo: full repo metadata including default branch.
- list_pull_requests: PRs in a repo. `state` is open|closed|all (default open).
- get_pull_request: full PR details including mergeable state.
- pull_request_diff: raw unified diff. Use this to actually read what's being changed before reviewing.
- pull_request_files: list of changed files with per-file patches.
- pull_request_reviews: existing reviews + review-level comments on a PR.
- pull_request_checks: CI status (check-runs + commit statuses) for the PR's head sha.
- list_issues / get_issue: same shape for issues. (GitHub treats PRs as a subclass of issues — issue endpoints work on PR numbers for comment threads.)
- list_branches: branches in a repo.
- github_file_contents: read a file at any ref (branch/tag/sha) without cloning.
- search_repos / search_issues / search_code: GitHub search syntax (qualifiers like `repo:owner/name`, `is:pr is:open author:me`, etc).
- list_notifications: the user's notifications inbox.

Writes (each pops a confirmation alert on the user's device — the user's tap IS the checkpoint, do not ask again in chat; if the tool returns `cancelled`, drop the action):
- create_pull_request: open a new PR. Requires `owner`, `repo`, `title`, `head` (the source branch, e.g. "feature/foo" or "user:branch" for forks), `base` (target branch, usually the default). Optional `body`, `draft`, `maintainer_can_modify`.
- review_pull_request: submit a review. `event` is APPROVE | REQUEST_CHANGES | COMMENT. Body is required for REQUEST_CHANGES/COMMENT. For inline comments pass `comments`: an array of `{path, line, body, side?, start_line?}` — `side` is "RIGHT" (default, comment on the new version) or "LEFT" (the old version). For multi-line, set `start_line` to the first line and `line` to the last.
- comment_pull_request: a top-level (issue-style) comment on a PR.
- merge_pull_request: `method` is merge | squash | rebase. Optional `commit_title` / `commit_message` / `sha` (require the PR head to match this sha). Honors GitHub's required-checks settings — will return an error if the PR isn't mergeable.
- create_issue / comment_issue / close_issue.
- mark_notification_read: clear a notification thread.

Cloning:
- clone_github_repo: clone a repo into the workspace using the stored PAT — no need to paste it inline. Pass `owner` and `repo` (and optional `dest`). Internally delegates to git_clone.

Workflow tips:
- Before reviewing, call pull_request_diff (and optionally pull_request_files for paths). Don't review blind.
- For merge: most repos want `squash`. Ask the user only if there's no obvious convention; otherwise pick squash by default and let the confirmation alert be the checkpoint.
- For approving your own PRs: GitHub rejects that with `unprocessable_entity`. Suggest the user request a review or use comment_pull_request instead.
- If a tool returns `github_not_connected`, the user has no PAT set. If it returns `forbidden` with a hint about missing scopes, name the scopes the PAT needs.
- This is a single-account personal integration — there's one PAT, one connected user.
"""

    // MARK: - Tool schemas

    static let tools: [[String: Any]] = [
        // ─── Reads ──────────────────────────────────────────────────────
        [
            "type": "function",
            "function": [
                "name": "github_whoami",
                "description": "Verify the GitHub PAT and return the connected user (login, name, plan).",
                "parameters": ["type": "object", "properties": [:], "required": []]
            ]
        ],
        [
            "type": "function",
            "function": [
                "name": "list_github_repos",
                "description": "List repositories the connected user can see. Returns the most-recently-updated first.",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "affiliation": [
                            "type": "string",
                            "description": "Comma-separated GitHub affiliations: owner, collaborator, organization_member. Default 'owner,collaborator,organization_member'."
                        ],
                        "limit": [
                            "type": "integer",
                            "description": "Max repos to return. Default 30, max 100."
                        ],
                        "visibility": [
                            "type": "string",
                            "description": "Optional. 'all' (default), 'public', or 'private'."
                        ]
                    ],
                    "required": []
                ]
            ]
        ],
        [
            "type": "function",
            "function": [
                "name": "get_github_repo",
                "description": "Full metadata for one repository, including default branch and topics.",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "owner": ["type": "string", "description": "Repo owner (user or org)."],
                        "repo":  ["type": "string", "description": "Repo name."]
                    ],
                    "required": ["owner", "repo"]
                ]
            ]
        ],
        [
            "type": "function",
            "function": [
                "name": "list_pull_requests",
                "description": "List pull requests in a repository.",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "owner": ["type": "string"],
                        "repo":  ["type": "string"],
                        "state": ["type": "string", "description": "open | closed | all. Default open."],
                        "limit": ["type": "integer", "description": "Default 30, max 100."]
                    ],
                    "required": ["owner", "repo"]
                ]
            ]
        ],
        [
            "type": "function",
            "function": [
                "name": "get_pull_request",
                "description": "Full details for a single PR — title, body, head/base, mergeable state, requested reviewers.",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "owner":  ["type": "string"],
                        "repo":   ["type": "string"],
                        "number": ["type": "integer", "description": "PR number (not the node id)."]
                    ],
                    "required": ["owner", "repo", "number"]
                ]
            ]
        ],
        [
            "type": "function",
            "function": [
                "name": "pull_request_diff",
                "description": "Raw unified diff text for a PR. Truncated to a reasonable size; use pull_request_files if you only need paths.",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "owner":  ["type": "string"],
                        "repo":   ["type": "string"],
                        "number": ["type": "integer"]
                    ],
                    "required": ["owner", "repo", "number"]
                ]
            ]
        ],
        [
            "type": "function",
            "function": [
                "name": "pull_request_files",
                "description": "List files changed in a PR with per-file patches and add/del counts.",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "owner":  ["type": "string"],
                        "repo":   ["type": "string"],
                        "number": ["type": "integer"],
                        "limit":  ["type": "integer", "description": "Default 30, max 100."]
                    ],
                    "required": ["owner", "repo", "number"]
                ]
            ]
        ],
        [
            "type": "function",
            "function": [
                "name": "pull_request_reviews",
                "description": "Existing reviews on a PR + their inline comments.",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "owner":  ["type": "string"],
                        "repo":   ["type": "string"],
                        "number": ["type": "integer"]
                    ],
                    "required": ["owner", "repo", "number"]
                ]
            ]
        ],
        [
            "type": "function",
            "function": [
                "name": "pull_request_checks",
                "description": "CI check-runs and commit statuses for the PR's head sha. Rolls up to a simple state per check.",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "owner":  ["type": "string"],
                        "repo":   ["type": "string"],
                        "number": ["type": "integer"]
                    ],
                    "required": ["owner", "repo", "number"]
                ]
            ]
        ],
        [
            "type": "function",
            "function": [
                "name": "list_issues",
                "description": "List issues in a repository. Use `is:pr` in search_issues if you want PRs filtered.",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "owner":    ["type": "string"],
                        "repo":     ["type": "string"],
                        "state":    ["type": "string", "description": "open | closed | all. Default open."],
                        "assignee": ["type": "string", "description": "Optional. '*' = any, 'none' = unassigned, otherwise a login."],
                        "limit":    ["type": "integer", "description": "Default 30, max 100."]
                    ],
                    "required": ["owner", "repo"]
                ]
            ]
        ],
        [
            "type": "function",
            "function": [
                "name": "get_issue",
                "description": "Full details for a single issue (or PR — the issue endpoints work for PR numbers too).",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "owner":  ["type": "string"],
                        "repo":   ["type": "string"],
                        "number": ["type": "integer"]
                    ],
                    "required": ["owner", "repo", "number"]
                ]
            ]
        ],
        [
            "type": "function",
            "function": [
                "name": "list_branches",
                "description": "List branches in a repository.",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "owner": ["type": "string"],
                        "repo":  ["type": "string"],
                        "limit": ["type": "integer", "description": "Default 30, max 100."]
                    ],
                    "required": ["owner", "repo"]
                ]
            ]
        ],
        [
            "type": "function",
            "function": [
                "name": "github_file_contents",
                "description": "Read a file at any ref without cloning. Returns decoded UTF-8 text (or a base64 hint if the blob isn't text).",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "owner": ["type": "string"],
                        "repo":  ["type": "string"],
                        "path":  ["type": "string", "description": "File path relative to the repo root."],
                        "ref":   ["type": "string", "description": "Optional branch/tag/sha. Defaults to the repo's default branch."]
                    ],
                    "required": ["owner", "repo", "path"]
                ]
            ]
        ],
        [
            "type": "function",
            "function": [
                "name": "search_repos",
                "description": "Search repositories with GitHub search syntax (e.g. 'language:swift stars:>500 my keyword').",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "query": ["type": "string"],
                        "limit": ["type": "integer", "description": "Default 20, max 100."]
                    ],
                    "required": ["query"]
                ]
            ]
        ],
        [
            "type": "function",
            "function": [
                "name": "search_issues",
                "description": "Search issues and PRs with GitHub search syntax (e.g. 'is:pr is:open author:@me', 'repo:owner/name label:bug').",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "query": ["type": "string"],
                        "limit": ["type": "integer", "description": "Default 20, max 100."]
                    ],
                    "required": ["query"]
                ]
            ]
        ],
        [
            "type": "function",
            "function": [
                "name": "search_code",
                "description": "Search code with GitHub search syntax (e.g. 'addEventListener repo:owner/name language:js').",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "query": ["type": "string"],
                        "limit": ["type": "integer", "description": "Default 20, max 100."]
                    ],
                    "required": ["query"]
                ]
            ]
        ],
        [
            "type": "function",
            "function": [
                "name": "list_notifications",
                "description": "The connected user's notifications inbox. Returns the threads with their `id`, `reason`, repo, subject (title/type/url).",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "all":           ["type": "boolean", "description": "Include already-read notifications. Default false."],
                        "participating": ["type": "boolean", "description": "Only notifications the user was directly mentioned in or assigned to. Default false."],
                        "limit":         ["type": "integer", "description": "Default 30, max 50."]
                    ],
                    "required": []
                ]
            ]
        ],

        // ─── Writes (host-confirmed) ────────────────────────────────────
        [
            "type": "function",
            "function": [
                "name": "create_pull_request",
                "description": "Open a new pull request. Pops a confirmation alert before POSTing. Use `draft: true` to open as draft.",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "owner":  ["type": "string"],
                        "repo":   ["type": "string"],
                        "title":  ["type": "string"],
                        "head":   ["type": "string", "description": "Source branch. For cross-fork PRs, prefix with 'user:' (e.g. 'octocat:feature-x')."],
                        "base":   ["type": "string", "description": "Target branch — usually the repo's default branch."],
                        "body":   ["type": "string", "description": "Markdown body of the PR description."],
                        "draft":  ["type": "boolean", "description": "Open as draft. Default false."],
                        "maintainer_can_modify": ["type": "boolean", "description": "Allow upstream maintainers to push to the PR branch. Default true."]
                    ],
                    "required": ["owner", "repo", "title", "head", "base"]
                ]
            ]
        ],
        [
            "type": "function",
            "function": [
                "name": "review_pull_request",
                "description": "Submit a review on a PR. `event` is APPROVE | REQUEST_CHANGES | COMMENT. Pops a confirmation alert before submitting. Inline `comments` are optional.",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "owner":  ["type": "string"],
                        "repo":   ["type": "string"],
                        "number": ["type": "integer"],
                        "event":  ["type": "string", "description": "APPROVE | REQUEST_CHANGES | COMMENT. Body is required unless event is APPROVE."],
                        "body":   ["type": "string", "description": "Review summary. Required for REQUEST_CHANGES and COMMENT."],
                        "comments": [
                            "type": "array",
                            "description": "Optional inline comments to file alongside the review.",
                            "items": [
                                "type": "object",
                                "properties": [
                                    "path":       ["type": "string", "description": "File path within the PR diff."],
                                    "line":       ["type": "integer", "description": "Line number in the file the comment anchors to (last line for multi-line)."],
                                    "side":       ["type": "string", "description": "'RIGHT' (default, the new version) or 'LEFT' (the old version)."],
                                    "start_line": ["type": "integer", "description": "For multi-line comments, the first line of the range."],
                                    "body":       ["type": "string", "description": "Comment text."]
                                ],
                                "required": ["path", "line", "body"]
                            ]
                        ]
                    ],
                    "required": ["owner", "repo", "number", "event"]
                ]
            ]
        ],
        [
            "type": "function",
            "function": [
                "name": "comment_pull_request",
                "description": "Top-level (issue-style) comment on a PR. Pops a confirmation alert before posting. For inline review comments, use review_pull_request.",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "owner":  ["type": "string"],
                        "repo":   ["type": "string"],
                        "number": ["type": "integer"],
                        "body":   ["type": "string"]
                    ],
                    "required": ["owner", "repo", "number", "body"]
                ]
            ]
        ],
        [
            "type": "function",
            "function": [
                "name": "merge_pull_request",
                "description": "Merge a PR. Pops a confirmation alert with the method. `method` is merge | squash | rebase (default squash). Optional `commit_title` and `commit_message`; optional `sha` to require the PR head to match.",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "owner":          ["type": "string"],
                        "repo":           ["type": "string"],
                        "number":         ["type": "integer"],
                        "method":         ["type": "string", "description": "merge | squash | rebase. Default squash."],
                        "commit_title":   ["type": "string"],
                        "commit_message": ["type": "string"],
                        "sha":            ["type": "string", "description": "Require the PR head to match this sha. Optional but recommended for unattended merges."]
                    ],
                    "required": ["owner", "repo", "number"]
                ]
            ]
        ],
        [
            "type": "function",
            "function": [
                "name": "create_issue",
                "description": "Open a new issue. Pops a confirmation alert before POSTing.",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "owner":     ["type": "string"],
                        "repo":      ["type": "string"],
                        "title":     ["type": "string"],
                        "body":      ["type": "string"],
                        "labels":    ["type": "array",  "items": ["type": "string"]],
                        "assignees": ["type": "array",  "items": ["type": "string"]]
                    ],
                    "required": ["owner", "repo", "title"]
                ]
            ]
        ],
        [
            "type": "function",
            "function": [
                "name": "comment_issue",
                "description": "Add a comment to an issue. Pops a confirmation alert.",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "owner":  ["type": "string"],
                        "repo":   ["type": "string"],
                        "number": ["type": "integer"],
                        "body":   ["type": "string"]
                    ],
                    "required": ["owner", "repo", "number", "body"]
                ]
            ]
        ],
        [
            "type": "function",
            "function": [
                "name": "close_issue",
                "description": "Close an issue. Pops a confirmation alert. `reason` is optional ('completed' | 'not_planned').",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "owner":  ["type": "string"],
                        "repo":   ["type": "string"],
                        "number": ["type": "integer"],
                        "reason": ["type": "string", "description": "'completed' (default) or 'not_planned'."]
                    ],
                    "required": ["owner", "repo", "number"]
                ]
            ]
        ],
        [
            "type": "function",
            "function": [
                "name": "mark_notification_read",
                "description": "Mark a notification thread as read. Pops a confirmation alert (since this changes inbox state silently).",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "thread_id": ["type": "string", "description": "Notification thread id from list_notifications."]
                    ],
                    "required": ["thread_id"]
                ]
            ]
        ],

        // ─── Clone glue ─────────────────────────────────────────────────
        [
            "type": "function",
            "function": [
                "name": "clone_github_repo",
                "description": "Clone a GitHub repo into the workspace using the stored PAT — the user never has to paste it. Returns the workspace path.",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "owner": ["type": "string"],
                        "repo":  ["type": "string"],
                        "dest":  ["type": "string", "description": "Optional destination folder under repos/. Defaults to the repo name."]
                    ],
                    "required": ["owner", "repo"]
                ]
            ]
        ]
    ]

    static let toolNames: Set<String> = [
        "github_whoami",
        "list_github_repos",
        "get_github_repo",
        "list_pull_requests",
        "get_pull_request",
        "pull_request_diff",
        "pull_request_files",
        "pull_request_reviews",
        "pull_request_checks",
        "list_issues",
        "get_issue",
        "list_branches",
        "github_file_contents",
        "search_repos",
        "search_issues",
        "search_code",
        "list_notifications",
        "create_pull_request",
        "review_pull_request",
        "comment_pull_request",
        "merge_pull_request",
        "create_issue",
        "comment_issue",
        "close_issue",
        "mark_notification_read",
        "clone_github_repo"
    ]

    func handles(functionName: String) -> Bool {
        return GitHubSkill.toolNames.contains(functionName)
    }

    /// Shimmer label shown while a tool runs.
    func statusText(for call: FunctionCallStruct) -> String? {
        switch call.name {
        case "github_whoami":          return "checking GitHub"
        case "list_github_repos":      return "listing GitHub repos"
        case "get_github_repo":        return "reading repo info"
        case "list_pull_requests":     return "listing pull requests"
        case "get_pull_request":       return "reading PR"
        case "pull_request_diff":      return "reading PR diff"
        case "pull_request_files":     return "listing PR files"
        case "pull_request_reviews":   return "reading PR reviews"
        case "pull_request_checks":    return "checking CI status"
        case "list_issues":            return "listing issues"
        case "get_issue":              return "reading issue"
        case "list_branches":          return "listing branches"
        case "github_file_contents":   return "reading file from GitHub"
        case "search_repos":           return "searching GitHub repos"
        case "search_issues":          return "searching GitHub issues"
        case "search_code":            return "searching GitHub code"
        case "list_notifications":     return "checking GitHub notifications"
        case "create_pull_request":    return "opening pull request"
        case "review_pull_request":    return "submitting PR review"
        case "comment_pull_request":   return "commenting on PR"
        case "merge_pull_request":     return "merging pull request"
        case "create_issue":           return "opening issue"
        case "comment_issue":          return "commenting on issue"
        case "close_issue":            return "closing issue"
        case "mark_notification_read": return "marking notification read"
        case "clone_github_repo":      return "cloning repo"
        default:                       return nil
        }
    }

    // MARK: - Dispatch

    func handle(functionCall: FunctionCallStruct,
                completion: @escaping (MessageStruct) -> Void) {
        let args = functionCall.arguments
        switch functionCall.name {

        // ─── Reads ──────────────────────────────────────────────────────
        case "github_whoami":
            githubRequest(.get, path: "/user") { [weak self] result in
                self?.respond(functionCall.name, result: result, completion: completion) { dict -> [String: Any] in
                    let plan = (dict["plan"] as? [String: Any])?["name"] as? String ?? ""
                    return [
                        "login": dict["login"] as? String ?? "",
                        "name":  dict["name"]  as? String ?? "",
                        "id":    dict["id"]    as? Int    ?? 0,
                        "plan":  plan
                    ]
                }
            }

        case "list_github_repos":
            let limit = Self.clamp(Self.intArg(args["limit"]) ?? 30, 1, 100)
            var query: [String: String] = [
                "affiliation": (args["affiliation"] as? String) ?? "owner,collaborator,organization_member",
                "sort": "updated",
                "per_page": String(limit)
            ]
            if let visibility = args["visibility"] as? String, !visibility.isEmpty {
                query["visibility"] = visibility
            }
            githubRequest(.get, path: "/user/repos", query: query) { [weak self] result in
                self?.respondList(functionCall.name, result: result, completion: completion) { repo in
                    Self.trimRepo(repo)
                }
            }

        case "get_github_repo":
            guard let (owner, repo) = Self.ownerRepo(args, name: functionCall.name, completion: completion) else { return }
            githubRequest(.get, path: "/repos/\(owner)/\(repo)") { [weak self] result in
                self?.respond(functionCall.name, result: result, completion: completion) { Self.trimRepo($0) }
            }

        case "list_pull_requests":
            guard let (owner, repo) = Self.ownerRepo(args, name: functionCall.name, completion: completion) else { return }
            let limit = Self.clamp(Self.intArg(args["limit"]) ?? 30, 1, 100)
            let state = (args["state"] as? String) ?? "open"
            let query = ["state": state, "per_page": String(limit), "sort": "updated", "direction": "desc"]
            githubRequest(.get, path: "/repos/\(owner)/\(repo)/pulls", query: query) { [weak self] result in
                self?.respondList(functionCall.name, result: result, completion: completion) { pr in
                    Self.trimPR(pr)
                }
            }

        case "get_pull_request":
            guard let (owner, repo, number) = Self.ownerRepoNumber(args, name: functionCall.name, completion: completion) else { return }
            githubRequest(.get, path: "/repos/\(owner)/\(repo)/pulls/\(number)") { [weak self] result in
                self?.respond(functionCall.name, result: result, completion: completion) { Self.trimPR($0, full: true) }
            }

        case "pull_request_diff":
            guard let (owner, repo, number) = Self.ownerRepoNumber(args, name: functionCall.name, completion: completion) else { return }
            githubRawRequest(.get, path: "/repos/\(owner)/\(repo)/pulls/\(number)",
                             accept: "application/vnd.github.v3.diff") { [weak self] result in
                guard let self else { return }
                switch result {
                case .failure(let err):
                    completion(self.errorMessage(for: functionCall.name, error: err))
                case .success(let text):
                    // Truncate aggressively. A multi-thousand-line diff would
                    // crush the model's context for marginal benefit.
                    let maxBytes = 32_000
                    let payload: [String: Any]
                    if text.utf8.count > maxBytes {
                        let truncated = String(text.prefix(maxBytes))
                        payload = [
                            "diff": truncated,
                            "truncated": true,
                            "original_bytes": text.utf8.count,
                            "hint": "Diff truncated at \(maxBytes) bytes. Use pull_request_files to inspect specific paths."
                        ]
                    } else {
                        payload = ["diff": text, "truncated": false]
                    }
                    completion(Self.functionMessage(name: functionCall.name, payload: payload))
                }
            }

        case "pull_request_files":
            guard let (owner, repo, number) = Self.ownerRepoNumber(args, name: functionCall.name, completion: completion) else { return }
            let limit = Self.clamp(Self.intArg(args["limit"]) ?? 30, 1, 100)
            githubRequest(.get,
                          path: "/repos/\(owner)/\(repo)/pulls/\(number)/files",
                          query: ["per_page": String(limit)]) { [weak self] result in
                self?.respondList(functionCall.name, result: result, completion: completion) { file -> [String: Any] in
                    return [
                        "filename":  file["filename"]  as? String ?? "",
                        "status":    file["status"]    as? String ?? "",
                        "additions": file["additions"] as? Int    ?? 0,
                        "deletions": file["deletions"] as? Int    ?? 0,
                        "changes":   file["changes"]   as? Int    ?? 0,
                        "patch":     file["patch"]     as? String ?? ""
                    ]
                }
            }

        case "pull_request_reviews":
            guard let (owner, repo, number) = Self.ownerRepoNumber(args, name: functionCall.name, completion: completion) else { return }
            githubRequest(.get, path: "/repos/\(owner)/\(repo)/pulls/\(number)/reviews") { [weak self] reviewsResult in
                guard let self else { return }
                switch reviewsResult {
                case .failure(let err):
                    completion(self.errorMessage(for: functionCall.name, error: err))
                case .success(let json):
                    let reviews = (json as? [[String: Any]] ?? []).map { r -> [String: Any] in
                        [
                            "id":     r["id"] as? Int ?? 0,
                            "state":  r["state"] as? String ?? "",
                            "user":   (r["user"] as? [String: Any])?["login"] as? String ?? "",
                            "body":   r["body"] as? String ?? "",
                            "submitted_at": r["submitted_at"] as? String ?? ""
                        ]
                    }
                    // Also fetch review-level comments so the agent sees inline notes.
                    self.githubRequest(.get,
                                       path: "/repos/\(owner)/\(repo)/pulls/\(number)/comments",
                                       query: ["per_page": "100"]) { commentsResult in
                        let comments: [[String: Any]]
                        if case let .success(c) = commentsResult, let arr = c as? [[String: Any]] {
                            comments = arr.map { com in
                                [
                                    "user":     (com["user"] as? [String: Any])?["login"] as? String ?? "",
                                    "path":     com["path"]      as? String ?? "",
                                    "line":     com["line"]      as? Int    ?? (com["original_line"] as? Int ?? 0),
                                    "side":     com["side"]      as? String ?? "RIGHT",
                                    "body":     com["body"]      as? String ?? "",
                                    "in_reply_to_id": com["in_reply_to_id"] as? Int ?? 0,
                                    "created_at": com["created_at"] as? String ?? ""
                                ]
                            }
                        } else {
                            comments = []
                        }
                        completion(Self.functionMessage(name: functionCall.name, payload: [
                            "reviews": reviews,
                            "inline_comments": comments
                        ]))
                    }
                }
            }

        case "pull_request_checks":
            guard let (owner, repo, number) = Self.ownerRepoNumber(args, name: functionCall.name, completion: completion) else { return }
            // Need the head sha first — get the PR, then ask for checks on its sha.
            githubRequest(.get, path: "/repos/\(owner)/\(repo)/pulls/\(number)") { [weak self] prResult in
                guard let self else { return }
                switch prResult {
                case .failure(let err):
                    completion(self.errorMessage(for: functionCall.name, error: err))
                case .success(let json):
                    let sha = ((json as? [String: Any])?["head"] as? [String: Any])?["sha"] as? String ?? ""
                    guard !sha.isEmpty else {
                        completion(Self.functionMessage(name: functionCall.name, payload: [
                            "error": "no_head_sha",
                            "hint": "PR has no head sha — possibly already closed."
                        ]))
                        return
                    }
                    self.githubRequest(.get,
                                       path: "/repos/\(owner)/\(repo)/commits/\(sha)/check-runs") { checksResult in
                        let runs: [[String: Any]]
                        if case let .success(c) = checksResult,
                           let dict = c as? [String: Any],
                           let arr = dict["check_runs"] as? [[String: Any]] {
                            runs = arr.map { run in
                                [
                                    "name":       run["name"]       as? String ?? "",
                                    "status":     run["status"]     as? String ?? "",
                                    "conclusion": run["conclusion"] as? String ?? "",
                                    "html_url":   run["html_url"]   as? String ?? ""
                                ]
                            }
                        } else {
                            runs = []
                        }
                        completion(Self.functionMessage(name: functionCall.name, payload: [
                            "head_sha":   sha,
                            "check_runs": runs
                        ]))
                    }
                }
            }

        case "list_issues":
            guard let (owner, repo) = Self.ownerRepo(args, name: functionCall.name, completion: completion) else { return }
            let limit = Self.clamp(Self.intArg(args["limit"]) ?? 30, 1, 100)
            var query: [String: String] = [
                "state":    (args["state"] as? String) ?? "open",
                "per_page": String(limit)
            ]
            if let assignee = args["assignee"] as? String, !assignee.isEmpty {
                query["assignee"] = assignee
            }
            githubRequest(.get, path: "/repos/\(owner)/\(repo)/issues", query: query) { [weak self] result in
                self?.respondList(functionCall.name, result: result, completion: completion) { issue in
                    // Filter out PRs unless the model asked via search_issues —
                    // /issues returns both. Keep PRs but flag them.
                    Self.trimIssue(issue)
                }
            }

        case "get_issue":
            guard let (owner, repo, number) = Self.ownerRepoNumber(args, name: functionCall.name, completion: completion) else { return }
            githubRequest(.get, path: "/repos/\(owner)/\(repo)/issues/\(number)") { [weak self] result in
                self?.respond(functionCall.name, result: result, completion: completion) { Self.trimIssue($0) }
            }

        case "list_branches":
            guard let (owner, repo) = Self.ownerRepo(args, name: functionCall.name, completion: completion) else { return }
            let limit = Self.clamp(Self.intArg(args["limit"]) ?? 30, 1, 100)
            githubRequest(.get,
                          path: "/repos/\(owner)/\(repo)/branches",
                          query: ["per_page": String(limit)]) { [weak self] result in
                self?.respondList(functionCall.name, result: result, completion: completion) { b in
                    [
                        "name":      b["name"] as? String ?? "",
                        "protected": b["protected"] as? Bool ?? false,
                        "sha":       (b["commit"] as? [String: Any])?["sha"] as? String ?? ""
                    ]
                }
            }

        case "github_file_contents":
            guard let (owner, repo) = Self.ownerRepo(args, name: functionCall.name, completion: completion),
                  let path = (args["path"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !path.isEmpty else {
                completion(missingArgs(for: functionCall.name, expected: "owner, repo, path")); return
            }
            var query: [String: String] = [:]
            if let ref = args["ref"] as? String, !ref.isEmpty { query["ref"] = ref }
            let escapedPath = path
                .split(separator: "/")
                .map { String($0).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0) }
                .joined(separator: "/")
            githubRequest(.get,
                          path: "/repos/\(owner)/\(repo)/contents/\(escapedPath)",
                          query: query) { [weak self] result in
                guard let self else { return }
                switch result {
                case .failure(let err):
                    completion(self.errorMessage(for: functionCall.name, error: err))
                case .success(let json):
                    guard let dict = json as? [String: Any] else {
                        completion(Self.functionMessage(name: functionCall.name, payload: ["error": "not_a_file"]))
                        return
                    }
                    // GitHub returns base64 with newlines every 60 chars.
                    let encoding = dict["encoding"] as? String ?? ""
                    let raw = (dict["content"] as? String ?? "").replacingOccurrences(of: "\n", with: "")
                    if encoding == "base64",
                       let data = Data(base64Encoded: raw),
                       let text = String(data: data, encoding: .utf8) {
                        let maxBytes = 32_000
                        if text.utf8.count > maxBytes {
                            completion(Self.functionMessage(name: functionCall.name, payload: [
                                "path":      dict["path"] as? String ?? path,
                                "sha":       dict["sha"]  as? String ?? "",
                                "size":      dict["size"] as? Int    ?? 0,
                                "content":   String(text.prefix(maxBytes)),
                                "truncated": true,
                                "hint":      "Truncated at \(maxBytes) bytes."
                            ]))
                        } else {
                            completion(Self.functionMessage(name: functionCall.name, payload: [
                                "path":      dict["path"] as? String ?? path,
                                "sha":       dict["sha"]  as? String ?? "",
                                "size":      dict["size"] as? Int    ?? 0,
                                "content":   text,
                                "truncated": false
                            ]))
                        }
                    } else {
                        completion(Self.functionMessage(name: functionCall.name, payload: [
                            "path": dict["path"] as? String ?? path,
                            "sha":  dict["sha"]  as? String ?? "",
                            "size": dict["size"] as? Int    ?? 0,
                            "error": "binary_or_unsupported_encoding",
                            "hint":  "File isn't UTF-8 text; clone with clone_github_repo to inspect locally."
                        ]))
                    }
                }
            }

        case "search_repos":
            guard let query = (args["query"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !query.isEmpty else {
                completion(missingArgs(for: functionCall.name, expected: "query")); return
            }
            let limit = Self.clamp(Self.intArg(args["limit"]) ?? 20, 1, 100)
            githubRequest(.get, path: "/search/repositories",
                          query: ["q": query, "per_page": String(limit)]) { [weak self] result in
                self?.respondSearch(functionCall.name, result: result, completion: completion) { Self.trimRepo($0) }
            }

        case "search_issues":
            guard let query = (args["query"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !query.isEmpty else {
                completion(missingArgs(for: functionCall.name, expected: "query")); return
            }
            let limit = Self.clamp(Self.intArg(args["limit"]) ?? 20, 1, 100)
            githubRequest(.get, path: "/search/issues",
                          query: ["q": query, "per_page": String(limit)]) { [weak self] result in
                self?.respondSearch(functionCall.name, result: result, completion: completion) { Self.trimIssue($0) }
            }

        case "search_code":
            guard let query = (args["query"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !query.isEmpty else {
                completion(missingArgs(for: functionCall.name, expected: "query")); return
            }
            let limit = Self.clamp(Self.intArg(args["limit"]) ?? 20, 1, 100)
            githubRequest(.get, path: "/search/code",
                          query: ["q": query, "per_page": String(limit)]) { [weak self] result in
                self?.respondSearch(functionCall.name, result: result, completion: completion) { item -> [String: Any] in
                    let repoFull = (item["repository"] as? [String: Any])?["full_name"] as? String ?? ""
                    return [
                        "name":       item["name"]     as? String ?? "",
                        "path":       item["path"]     as? String ?? "",
                        "html_url":   item["html_url"] as? String ?? "",
                        "repository": repoFull
                    ]
                }
            }

        case "list_notifications":
            let limit = Self.clamp(Self.intArg(args["limit"]) ?? 30, 1, 50)
            var query: [String: String] = ["per_page": String(limit)]
            if args["all"] as? Bool == true { query["all"] = "true" }
            if args["participating"] as? Bool == true { query["participating"] = "true" }
            githubRequest(.get, path: "/notifications", query: query) { [weak self] result in
                self?.respondList(functionCall.name, result: result, completion: completion) { n in
                    let subject = n["subject"] as? [String: Any] ?? [:]
                    return [
                        "thread_id": n["id"] as? String ?? "",
                        "reason":    n["reason"] as? String ?? "",
                        "repo":      (n["repository"] as? [String: Any])?["full_name"] as? String ?? "",
                        "title":     subject["title"] as? String ?? "",
                        "type":      subject["type"]  as? String ?? "",
                        "url":       Self.htmlURL(fromAPIURL: subject["url"] as? String ?? "")
                    ]
                }
            }

        // ─── Writes ─────────────────────────────────────────────────────
        case "create_pull_request":
            guard let (owner, repo) = Self.ownerRepo(args, name: functionCall.name, completion: completion),
                  let title = (args["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty,
                  let head  = (args["head"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),  !head.isEmpty,
                  let base  = (args["base"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),  !base.isEmpty else {
                completion(missingArgs(for: functionCall.name, expected: "owner, repo, title, head, base")); return
            }
            let body = args["body"] as? String ?? ""
            let draft = args["draft"] as? Bool ?? false
            let modify = args["maintainer_can_modify"] as? Bool ?? true
            let detail = """
            \(owner)/\(repo)
            \(head) → \(base)\(draft ? "  (draft)" : "")

            \(body.isEmpty ? "(no description)" : body)
            """
            confirm(title: "Open PR: \(title)?", detail: detail, destructive: false,
                    tool: functionCall.name, completion: completion) { [weak self] in
                guard let self else { return }
                var payload: [String: Any] = [
                    "title": title,
                    "head":  head,
                    "base":  base,
                    "draft": draft,
                    "maintainer_can_modify": modify
                ]
                if !body.isEmpty { payload["body"] = body }
                self.githubRequest(.post,
                                   path: "/repos/\(owner)/\(repo)/pulls",
                                   body: payload) { result in
                    self.respond(functionCall.name, result: result, completion: completion) { dict in
                        ["status": "opened",
                         "number": dict["number"] as? Int ?? 0,
                         "html_url": dict["html_url"] as? String ?? ""]
                    }
                }
            }

        case "review_pull_request":
            guard let (owner, repo, number) = Self.ownerRepoNumber(args, name: functionCall.name, completion: completion),
                  let event = (args["event"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines).uppercased(),
                  ["APPROVE", "REQUEST_CHANGES", "COMMENT"].contains(event) else {
                completion(missingArgs(for: functionCall.name,
                                       expected: "owner, repo, number, event (APPROVE|REQUEST_CHANGES|COMMENT)"))
                return
            }
            let body = args["body"] as? String ?? ""
            if event != "APPROVE", body.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines).isEmpty {
                completion(Self.functionMessage(name: functionCall.name, payload: [
                    "error": "body_required",
                    "hint":  "GitHub requires a body for \(event) reviews."
                ]))
                return
            }
            let inlineComments = args["comments"] as? [[String: Any]] ?? []
            let inlineSummary: String
            if inlineComments.isEmpty {
                inlineSummary = ""
            } else {
                let bullets = inlineComments.prefix(5).map { c -> String in
                    let path = c["path"] as? String ?? "?"
                    let line = Self.intArg(c["line"]) ?? 0
                    return "  · \(path):\(line)"
                }.joined(separator: "\n")
                let more = inlineComments.count > 5 ? "\n  …+\(inlineComments.count - 5) more" : ""
                inlineSummary = "\nInline comments (\(inlineComments.count)):\n\(bullets)\(more)"
            }
            let detail = """
            \(owner)/\(repo) #\(number)
            \(event)

            \(body.isEmpty ? "(no summary body)" : body)\(inlineSummary)
            """
            let destructive = (event == "REQUEST_CHANGES")
            confirm(title: "Submit \(Self.eventLabel(event)) review?", detail: detail,
                    destructive: destructive, tool: functionCall.name, completion: completion) { [weak self] in
                guard let self else { return }
                var payload: [String: Any] = ["event": event]
                if !body.isEmpty { payload["body"] = body }
                if !inlineComments.isEmpty {
                    payload["comments"] = inlineComments.map(Self.normalizeReviewComment)
                }
                self.githubRequest(.post,
                                   path: "/repos/\(owner)/\(repo)/pulls/\(number)/reviews",
                                   body: payload) { result in
                    self.respond(functionCall.name, result: result, completion: completion) { dict in
                        ["status": "submitted",
                         "review_id": dict["id"] as? Int ?? 0,
                         "state": dict["state"] as? String ?? "",
                         "html_url": dict["html_url"] as? String ?? ""]
                    }
                }
            }

        case "comment_pull_request":
            guard let (owner, repo, number) = Self.ownerRepoNumber(args, name: functionCall.name, completion: completion),
                  let body = (args["body"] as? String), !body.isEmpty else {
                completion(missingArgs(for: functionCall.name, expected: "owner, repo, number, body")); return
            }
            confirm(title: "Comment on \(owner)/\(repo) #\(number)?",
                    detail: body, destructive: false,
                    tool: functionCall.name, completion: completion) { [weak self] in
                guard let self else { return }
                self.githubRequest(.post,
                                   path: "/repos/\(owner)/\(repo)/issues/\(number)/comments",
                                   body: ["body": body]) { result in
                    self.respond(functionCall.name, result: result, completion: completion) { dict in
                        ["status": "posted",
                         "id": dict["id"] as? Int ?? 0,
                         "html_url": dict["html_url"] as? String ?? ""]
                    }
                }
            }

        case "merge_pull_request":
            guard let (owner, repo, number) = Self.ownerRepoNumber(args, name: functionCall.name, completion: completion) else { return }
            let methodRaw = (args["method"] as? String)?.lowercased() ?? "squash"
            let method = ["merge", "squash", "rebase"].contains(methodRaw) ? methodRaw : "squash"
            var payload: [String: Any] = ["merge_method": method]
            if let t = args["commit_title"]   as? String, !t.isEmpty { payload["commit_title"] = t }
            if let m = args["commit_message"] as? String, !m.isEmpty { payload["commit_message"] = m }
            if let s = args["sha"]            as? String, !s.isEmpty { payload["sha"] = s }
            let detail = "\(owner)/\(repo) #\(number)\nMethod: \(method)"
            confirm(title: "Merge PR #\(number)?", detail: detail, destructive: true,
                    tool: functionCall.name, completion: completion) { [weak self] in
                guard let self else { return }
                self.githubRequest(.put,
                                   path: "/repos/\(owner)/\(repo)/pulls/\(number)/merge",
                                   body: payload) { result in
                    self.respond(functionCall.name, result: result, completion: completion) { dict in
                        ["status": "merged",
                         "sha": dict["sha"] as? String ?? "",
                         "merged": dict["merged"] as? Bool ?? true,
                         "message": dict["message"] as? String ?? ""]
                    }
                }
            }

        case "create_issue":
            guard let (owner, repo) = Self.ownerRepo(args, name: functionCall.name, completion: completion),
                  let title = (args["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else {
                completion(missingArgs(for: functionCall.name, expected: "owner, repo, title")); return
            }
            let body = args["body"] as? String ?? ""
            let labels = args["labels"]    as? [String] ?? []
            let assignees = args["assignees"] as? [String] ?? []
            let detail = """
            \(owner)/\(repo)
            \(labels.isEmpty ? "" : "Labels: \(labels.joined(separator: ", "))\n")\
            \(assignees.isEmpty ? "" : "Assignees: \(assignees.joined(separator: ", "))\n")
            \(body.isEmpty ? "(no body)" : body)
            """
            confirm(title: "Open issue: \(title)?", detail: detail, destructive: false,
                    tool: functionCall.name, completion: completion) { [weak self] in
                guard let self else { return }
                var payload: [String: Any] = ["title": title]
                if !body.isEmpty       { payload["body"] = body }
                if !labels.isEmpty     { payload["labels"] = labels }
                if !assignees.isEmpty  { payload["assignees"] = assignees }
                self.githubRequest(.post,
                                   path: "/repos/\(owner)/\(repo)/issues",
                                   body: payload) { result in
                    self.respond(functionCall.name, result: result, completion: completion) { dict in
                        ["status": "opened",
                         "number": dict["number"] as? Int ?? 0,
                         "html_url": dict["html_url"] as? String ?? ""]
                    }
                }
            }

        case "comment_issue":
            guard let (owner, repo, number) = Self.ownerRepoNumber(args, name: functionCall.name, completion: completion),
                  let body = (args["body"] as? String), !body.isEmpty else {
                completion(missingArgs(for: functionCall.name, expected: "owner, repo, number, body")); return
            }
            confirm(title: "Comment on \(owner)/\(repo) #\(number)?",
                    detail: body, destructive: false,
                    tool: functionCall.name, completion: completion) { [weak self] in
                guard let self else { return }
                self.githubRequest(.post,
                                   path: "/repos/\(owner)/\(repo)/issues/\(number)/comments",
                                   body: ["body": body]) { result in
                    self.respond(functionCall.name, result: result, completion: completion) { dict in
                        ["status": "posted",
                         "id": dict["id"] as? Int ?? 0,
                         "html_url": dict["html_url"] as? String ?? ""]
                    }
                }
            }

        case "close_issue":
            guard let (owner, repo, number) = Self.ownerRepoNumber(args, name: functionCall.name, completion: completion) else { return }
            let reason = (args["reason"] as? String) ?? "completed"
            confirm(title: "Close \(owner)/\(repo) #\(number)?",
                    detail: "Reason: \(reason)", destructive: true,
                    tool: functionCall.name, completion: completion) { [weak self] in
                guard let self else { return }
                self.githubRequest(.patch,
                                   path: "/repos/\(owner)/\(repo)/issues/\(number)",
                                   body: ["state": "closed", "state_reason": reason]) { result in
                    self.respond(functionCall.name, result: result, completion: completion) { dict in
                        ["status": "closed", "number": dict["number"] as? Int ?? number]
                    }
                }
            }

        case "mark_notification_read":
            guard let threadId = (args["thread_id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !threadId.isEmpty else {
                completion(missingArgs(for: functionCall.name, expected: "thread_id")); return
            }
            confirm(title: "Mark notification \(threadId) read?",
                    detail: "", destructive: false,
                    tool: functionCall.name, completion: completion) { [weak self] in
                guard let self else { return }
                self.githubRequest(.patch,
                                   path: "/notifications/threads/\(threadId)",
                                   body: [:]) { result in
                    switch result {
                    case .failure(let err):
                        completion(self.errorMessage(for: functionCall.name, error: err))
                    case .success:
                        completion(Self.functionMessage(name: functionCall.name,
                                                        payload: ["status": "read", "thread_id": threadId]))
                    }
                }
            }

        // ─── Clone glue ─────────────────────────────────────────────────
        case "clone_github_repo":
            guard let (owner, repo) = Self.ownerRepo(args, name: functionCall.name, completion: completion) else { return }
            let dest = (args["dest"] as? String) ?? repo
            let base = (KeyStore.shared.value(for: .githubBaseURL) ?? "https://api.github.com")
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            // Convert api.github.com → github.com for the git host. GHE keeps
            // its own host either way.
            let gitHost: String = {
                if base.hasPrefix("https://api.github.com") { return "https://github.com" }
                if let host = URL(string: base)?.host { return "https://\(host)" }
                return "https://github.com"
            }()
            let cloneURL = "\(gitHost)/\(owner)/\(repo).git"
            guard let pat = KeyStore.shared.value(for: .githubPAT), !pat.isEmpty else {
                completion(Self.functionMessage(name: functionCall.name, payload: [
                    "error": "github_not_connected",
                    "hint": "Paste a PAT in Settings → Keys → GitHub Personal Access Token before cloning private repos."
                ]))
                return
            }
            // Hand off to the existing GitSkill rather than re-implement clone.
            // We slip the PAT through the `token` arg so it's used once and
            // never echoed back.
            let cloneCall = FunctionCallStruct(
                name: "git_clone",
                arguments: ["url": cloneURL, "dest": dest, "token": pat],
                callId: functionCall.callId,
                conversationId: functionCall.conversationId
            )
            GitSkill.shared.handle(functionCall: cloneCall) { msg in
                // Re-tag the result message under clone_github_repo so the wire
                // payload matches the tool the model actually called.
                completion(MessageStruct(role: "function",
                                         content: msg.content,
                                         name: "clone_github_repo",
                                         callId: functionCall.callId))
            }

        default:
            completion(MessageStruct(
                role: "assistant",
                content: "I don't know how to handle the GitHub tool '\(functionCall.name)'."
            ))
        }
    }

    // MARK: - Confirmation plumbing

    /// Ask the host to confirm a write. Returns `cancelled` if the host says
    /// no, `no_confirmation_host` if there's no host attached (headless run).
    private func confirm(title: String,
                         detail: String,
                         destructive: Bool,
                         tool: String,
                         completion: @escaping (MessageStruct) -> Void,
                         onApproved: @escaping () -> Void) {
        guard let host else {
            completion(Self.functionMessage(name: tool, payload: [
                "status": "blocked",
                "reason": "no_confirmation_host",
                "hint": "Writes are blocked in headless / scheduled contexts because no UI is available to confirm."
            ]))
            return
        }
        DispatchQueue.main.async {
            host.githubSkill(requestConfirmation: title, detail: detail,
                             destructive: destructive) { approved in
                guard approved else {
                    completion(Self.functionMessage(name: tool, payload: ["status": "cancelled"]))
                    return
                }
                onApproved()
            }
        }
    }

    // MARK: - Network

    private enum HTTPMethod: String { case get = "GET", post = "POST", patch = "PATCH", put = "PUT", delete = "DELETE" }

    enum GitHubError: Error {
        case notConnected
        case transport
        case malformedResponse
        case http(status: Int, message: String, docURL: String?)
    }

    /// Standard JSON request — body is encoded as JSON when present, response
    /// is parsed as JSON (either a dict or an array, depending on endpoint).
    private func githubRequest(_ method: HTTPMethod,
                               path: String,
                               query: [String: String] = [:],
                               body: [String: Any]? = nil,
                               completion: @escaping (Result<Any, GitHubError>) -> Void) {
        rawRequest(method, path: path, query: query, body: body,
                   accept: "application/vnd.github+json") { result in
            switch result {
            case .failure(let err): completion(.failure(err))
            case .success((let data, _)):
                if data.isEmpty {
                    // A 204-shaped success (mark_notification_read, etc).
                    completion(.success([:] as [String: Any]))
                    return
                }
                if let json = try? JSONSerialization.jsonObject(with: data, options: []) {
                    completion(.success(json))
                } else {
                    completion(.failure(.malformedResponse))
                }
            }
        }
    }

    /// Raw request that returns the response body as a UTF-8 string. Used by
    /// pull_request_diff where the `accept` header asks GitHub for diff text.
    private func githubRawRequest(_ method: HTTPMethod,
                                  path: String,
                                  query: [String: String] = [:],
                                  accept: String,
                                  completion: @escaping (Result<String, GitHubError>) -> Void) {
        rawRequest(method, path: path, query: query, body: nil, accept: accept) { result in
            switch result {
            case .failure(let err): completion(.failure(err))
            case .success((let data, _)):
                completion(.success(String(data: data, encoding: .utf8) ?? ""))
            }
        }
    }

    /// Underlying URLSession call. Pulls the PAT from KeyStore, sets the
    /// Bearer + Accept + UA + X-GitHub-Api-Version headers, and surfaces HTTP
    /// errors with GitHub's `message` + `documentation_url` for legible
    /// diagnostics.
    private func rawRequest(_ method: HTTPMethod,
                            path: String,
                            query: [String: String],
                            body: [String: Any]?,
                            accept: String,
                            completion: @escaping (Result<(Data, HTTPURLResponse), GitHubError>) -> Void) {
        guard let token = KeyStore.shared.value(for: .githubPAT), !token.isEmpty else {
            DispatchQueue.main.async { completion(.failure(.notConnected)) }
            return
        }
        let base = (KeyStore.shared.value(for: .githubBaseURL) ?? "https://api.github.com")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard var comps = URLComponents(string: "\(base)\(path)") else {
            DispatchQueue.main.async { completion(.failure(.transport)) }
            return
        }
        if !query.isEmpty {
            comps.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        guard let url = comps.url else {
            DispatchQueue.main.async { completion(.failure(.transport)) }
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = method.rawValue
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(accept, forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("Loop-iOS/1.0", forHTTPHeaderField: "User-Agent")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONSerialization.data(withJSONObject: body, options: [])
        }
        URLSession.shared.dataTask(with: request) { data, response, error in
            DispatchQueue.main.async {
                if error != nil {
                    completion(.failure(.transport)); return
                }
                guard let http = response as? HTTPURLResponse, let data else {
                    completion(.failure(.malformedResponse)); return
                }
                if (200..<300).contains(http.statusCode) {
                    completion(.success((data, http)))
                } else {
                    let parsed = (try? JSONSerialization.jsonObject(with: data, options: [])) as? [String: Any]
                    let message = parsed?["message"] as? String ?? "HTTP \(http.statusCode)"
                    let doc = parsed?["documentation_url"] as? String
                    completion(.failure(.http(status: http.statusCode, message: message, docURL: doc)))
                }
            }
        }.resume()
    }

    // MARK: - Response shaping helpers

    /// Tool returned a JSON object (dict). Apply `transform` and emit the
    /// function-result message.
    private func respond(_ tool: String,
                         result: Result<Any, GitHubError>,
                         completion: @escaping (MessageStruct) -> Void,
                         transform: @escaping ([String: Any]) -> [String: Any]) {
        switch result {
        case .failure(let err):
            completion(errorMessage(for: tool, error: err))
        case .success(let json):
            guard let dict = json as? [String: Any] else {
                completion(Self.functionMessage(name: tool, payload: ["error": "unexpected_response_shape"]))
                return
            }
            completion(Self.functionMessage(name: tool, payload: transform(dict)))
        }
    }

    /// Tool returned a JSON array (list endpoints). Apply `transform` per item
    /// and emit `{items: [...]}`.
    private func respondList(_ tool: String,
                             result: Result<Any, GitHubError>,
                             completion: @escaping (MessageStruct) -> Void,
                             transform: @escaping ([String: Any]) -> [String: Any]) {
        switch result {
        case .failure(let err):
            completion(errorMessage(for: tool, error: err))
        case .success(let json):
            let items = (json as? [[String: Any]] ?? []).map(transform)
            completion(Self.functionMessage(name: tool, payload: ["items": items, "count": items.count]))
        }
    }

    /// Search endpoints return `{items: [...], total_count: N}`. Same shape as
    /// `respondList` but reads from the inner `items` field.
    private func respondSearch(_ tool: String,
                               result: Result<Any, GitHubError>,
                               completion: @escaping (MessageStruct) -> Void,
                               transform: @escaping ([String: Any]) -> [String: Any]) {
        switch result {
        case .failure(let err):
            completion(errorMessage(for: tool, error: err))
        case .success(let json):
            let dict = json as? [String: Any] ?? [:]
            let raw = dict["items"] as? [[String: Any]] ?? []
            let items = raw.map(transform)
            completion(Self.functionMessage(name: tool, payload: [
                "items": items,
                "count": items.count,
                "total_count": dict["total_count"] as? Int ?? items.count
            ]))
        }
    }

    // MARK: - Trimmers (keep responses model-context-friendly)

    private static func trimRepo(_ r: [String: Any]) -> [String: Any] {
        return [
            "full_name":     r["full_name"]     as? String ?? "",
            "name":          r["name"]          as? String ?? "",
            "owner":         (r["owner"] as? [String: Any])?["login"] as? String ?? "",
            "private":       r["private"]       as? Bool   ?? false,
            "description":   r["description"]   as? String ?? "",
            "default_branch": r["default_branch"] as? String ?? "",
            "open_issues":   r["open_issues_count"] as? Int ?? 0,
            "stargazers":    r["stargazers_count"]  as? Int ?? 0,
            "updated_at":    r["updated_at"]    as? String ?? "",
            "html_url":      r["html_url"]      as? String ?? "",
            "language":      r["language"]      as? String ?? ""
        ]
    }

    private static func trimPR(_ p: [String: Any], full: Bool = false) -> [String: Any] {
        var out: [String: Any] = [
            "number":   p["number"]   as? Int    ?? 0,
            "title":    p["title"]    as? String ?? "",
            "state":    p["state"]    as? String ?? "",
            "draft":    p["draft"]    as? Bool   ?? false,
            "user":     (p["user"] as? [String: Any])?["login"] as? String ?? "",
            "html_url": p["html_url"] as? String ?? "",
            "head":     (p["head"] as? [String: Any])?["ref"] as? String ?? "",
            "base":     (p["base"] as? [String: Any])?["ref"] as? String ?? "",
            "updated_at": p["updated_at"] as? String ?? ""
        ]
        if full {
            out["body"]      = p["body"] as? String ?? ""
            out["mergeable"] = p["mergeable"]      as? Bool   ?? false
            out["mergeable_state"] = p["mergeable_state"] as? String ?? ""
            out["additions"] = p["additions"]      as? Int    ?? 0
            out["deletions"] = p["deletions"]      as? Int    ?? 0
            out["changed_files"] = p["changed_files"] as? Int ?? 0
            out["head_sha"]  = (p["head"] as? [String: Any])?["sha"] as? String ?? ""
            out["requested_reviewers"] = (p["requested_reviewers"] as? [[String: Any]] ?? [])
                .compactMap { $0["login"] as? String }
        }
        return out
    }

    private static func trimIssue(_ i: [String: Any]) -> [String: Any] {
        return [
            "number":     i["number"]     as? Int    ?? 0,
            "title":      i["title"]      as? String ?? "",
            "state":      i["state"]      as? String ?? "",
            "user":       (i["user"] as? [String: Any])?["login"] as? String ?? "",
            "body":       i["body"]       as? String ?? "",
            "html_url":   i["html_url"]   as? String ?? "",
            "is_pr":      i["pull_request"] != nil,
            "labels":     (i["labels"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String },
            "comments":   i["comments"]   as? Int    ?? 0,
            "updated_at": i["updated_at"] as? String ?? ""
        ]
    }

    private static func normalizeReviewComment(_ c: [String: Any]) -> [String: Any] {
        var out: [String: Any] = [
            "path": c["path"] as? String ?? "",
            "body": c["body"] as? String ?? ""
        ]
        if let line = intArg(c["line"])       { out["line"] = line }
        if let start = intArg(c["start_line"]) { out["start_line"] = start }
        let side = (c["side"] as? String)?.uppercased()
        out["side"] = (side == "LEFT") ? "LEFT" : "RIGHT"
        return out
    }

    private static func htmlURL(fromAPIURL api: String) -> String {
        // /repos/x/y/pulls/123  →  https://github.com/x/y/pull/123
        guard let url = URL(string: api),
              let host = url.host else { return api }
        let path = url.path
            .replacingOccurrences(of: "/repos/", with: "/")
            .replacingOccurrences(of: "/pulls/", with: "/pull/")
        let webHost = host.hasPrefix("api.") ? String(host.dropFirst(4)) : host
        return "https://\(webHost)\(path)"
    }

    // MARK: - Arg / error helpers

    private static func ownerRepo(_ args: [String: Any],
                                  name: String,
                                  completion: @escaping (MessageStruct) -> Void) -> (String, String)? {
        guard let owner = (args["owner"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !owner.isEmpty,
              let repo  = (args["repo"]  as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !repo.isEmpty else {
            completion(Self.functionMessage(name: name, payload: [
                "error": "missing_args",
                "hint":  "owner and repo are required."
            ]))
            return nil
        }
        return (owner, repo)
    }

    private static func ownerRepoNumber(_ args: [String: Any],
                                        name: String,
                                        completion: @escaping (MessageStruct) -> Void) -> (String, String, Int)? {
        guard let (owner, repo) = ownerRepo(args, name: name, completion: completion) else { return nil }
        guard let number = intArg(args["number"]), number > 0 else {
            completion(Self.functionMessage(name: name, payload: [
                "error": "missing_args",
                "hint":  "number (PR/issue number) is required."
            ]))
            return nil
        }
        return (owner, repo, number)
    }

    private static func intArg(_ value: Any?) -> Int? {
        if let i = value as? Int { return i }
        if let d = value as? Double { return Int(d) }
        if let s = value as? String { return Int(s) }
        return nil
    }

    private static func clamp(_ v: Int, _ lo: Int, _ hi: Int) -> Int {
        return max(lo, min(hi, v))
    }

    private static func eventLabel(_ event: String) -> String {
        switch event {
        case "APPROVE":         return "approval"
        case "REQUEST_CHANGES": return "request-changes"
        case "COMMENT":         return "comment"
        default:                return event.lowercased()
        }
    }

    private func errorMessage(for tool: String, error: GitHubError) -> MessageStruct {
        let payload: [String: Any]
        switch error {
        case .notConnected:
            payload = [
                "error": "github_not_connected",
                "hint":  "Ask the user to paste a PAT in Settings → Keys → GitHub Personal Access Token."
            ]
        case .transport:
            payload = ["error": "github_transport_failed",
                       "hint":  "Network error talking to GitHub. Suggest retrying."]
        case .malformedResponse:
            payload = ["error": "github_malformed_response"]
        case .http(let status, let message, let doc):
            var p: [String: Any] = [
                "error":   Self.errorCode(forStatus: status),
                "status":  status,
                "message": message,
                "hint":    Self.recoveryHint(forStatus: status, message: message)
            ]
            if let doc { p["documentation_url"] = doc }
            payload = p
        }
        return Self.functionMessage(name: tool, payload: payload)
    }

    private static func errorCode(forStatus status: Int) -> String {
        switch status {
        case 401: return "unauthorized"
        case 403: return "forbidden"
        case 404: return "not_found"
        case 409: return "conflict"
        case 410: return "gone"
        case 422: return "unprocessable_entity"
        case 429: return "rate_limited"
        default:  return "http_\(status)"
        }
    }

    private static func recoveryHint(forStatus status: Int, message: String) -> String {
        switch status {
        case 401:
            return "Token is invalid or expired. Ask the user to mint a fresh PAT and paste it in Settings → Keys → GitHub Personal Access Token."
        case 403:
            if message.lowercased().contains("rate limit") {
                return "GitHub rate-limited the call. Wait a moment, then retry."
            }
            return "Token is missing a required scope or doesn't have access to this resource. For PR review/merge the PAT needs `pull_requests:write` and `contents:read`; for issues, `issues:write`; for notifications, the `notifications` user scope."
        case 404:
            return "Either the resource doesn't exist or the PAT can't see it (private repo without `contents:read`). Confirm owner/repo/number, then verify the PAT's repo access."
        case 409:
            return "Conflict — for a merge this typically means the PR isn't mergeable yet (failing required checks, unresolved review threads, or stale base). Read pull_request_checks / get_pull_request first."
        case 422:
            return "GitHub rejected the request shape. For review_pull_request this often means the author tried to approve their own PR — switch to comment_pull_request. For create_pull_request, check that head/base exist."
        case 429:
            return "Rate-limited. Wait and retry."
        default:
            return "See https://docs.github.com/en/rest for this status."
        }
    }

    private func missingArgs(for name: String, expected: String) -> MessageStruct {
        return MessageStruct(
            role: "assistant",
            content: "I need \(expected) to call \(name). Please provide them."
        )
    }

    private static func functionMessage(name: String, payload: Any) -> MessageStruct {
        let json: String
        if let data = try? JSONSerialization.data(withJSONObject: payload, options: []),
           let str = String(data: data, encoding: .utf8) {
            json = str
        } else {
            json = "{}"
        }
        return MessageStruct(role: "function", content: json, name: name)
    }
}
