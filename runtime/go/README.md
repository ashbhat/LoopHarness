# Portable Loop Runner (v0)

A Go-based agent runtime that runs the agent loop + local tools on a remote VM. The iOS app learns about completed turns/jobs by **polling** (`GET /turns`, `GET /jobs`) — see [Polling](#polling).

> **v0 status — what works vs. scaffolding**
>
> - **Working:** the agent turn loop, local tools (`echo`, `web_fetch`), SQLite persistence, and the polling endpoints. This is the supported path the iOS client uses.
> - **Scaffolding (non-functional):** the APNs device bridge (`bridge/`, `tools/device/`). `bridge.SendPush` returns an error until a real `.p8` key + JWT signing land, so device-only tools like `read_calendar` will time out. The types are kept in place as the seam for future VM→device tool calls — they are intentionally not wired up in v0.

## Requirements

- Linux amd64 (or any platform Go supports for development)
- Go 1.25+ (for building from source; required by `modernc.org/sqlite`)
- No Docker, Node, or Python needed at runtime

## Quick Start

```bash
# Build
make build

# Or cross-compile for Linux
make build-linux

# Run
cp config.example.json config.json
# Edit config.json with your values
./loop-runner -config config.json
```

## Bootstrap on a VM

```bash
# From your local machine:
scp loop-runner config.json user@vm:/opt/loop-runner/

# On the VM:
chmod +x /opt/loop-runner/loop-runner
/opt/loop-runner/loop-runner -config /opt/loop-runner/config.json

# Optional: install systemd service
sudo cp systemd/loop-runner.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now loop-runner
```

## Configuration

| Field | Type | Description |
|-------|------|-------------|
| `apns_key_path` | string | Path to the APNs .p8 key file. If empty, push is stubbed (binary still runs). |
| `apns_key_id` | string | 10-character Key ID from Apple Developer portal. |
| `apns_team_id` | string | 10-character Team ID from Apple Developer portal. |
| `apns_bundle_id` | string | Bundle identifier of the iOS app (e.g., `com.example.loop`). |
| `device_push_token` | string | The APNs device token for the target iOS device. |
| `model_api_key` | string | OpenAI API key (`sk-...`). |
| `shared_secret` | string | HMAC shared secret used as Bearer token for endpoint auth. |
| `listen_port` | int | HTTP listen port (default: 8080). |

## Endpoints

| Method | Path | Auth | Description |
|--------|------|------|-------------|
| `GET` | `/health` | No | Returns `{ok, version, uptime_seconds}`. |
| `POST` | `/turn` | Yes | Run a full agent turn. Streams response via SSE. Body: `{messages, conversation_id?}`. |
| `POST` | `/result` | Yes | Device → VM result delivery. Body: `{job_id, result?, error?}`. |
| `GET` | `/turn/:id` | Yes | Fetch a past turn from storage. |
| `GET` | `/job/:job_id` | Yes | Fetch a job's status + result. |
| `GET` | `/turns` | Yes | Poll turns. Query params: `since`, `status`, `limit`. |
| `GET` | `/jobs` | Yes | Poll jobs. Query params: `since`, `status`, `limit`. |

**Auth:** All protected endpoints require `Authorization: Bearer <shared_secret>` header.

## Polling

The `GET /turns` and `GET /jobs` endpoints let iOS clients pull completed turns and jobs without needing APNs push. The pattern:

1. First request — call `GET /turns` with no `since` param to get the most recent turns.
2. Store `server_time` from the response.
3. Next request — pass the stored value as `?since=<server_time>` to get only turns updated since the last poll.
4. Repeat.

### Query parameters

| Param | Type | Default | Description |
|-------|------|---------|-------------|
| `since` | RFC 3339 timestamp | *(none)* | Only return items with `updated_at` after this time. |
| `status` | string | *(none)* | Filter by status (`running`, `completed`, `error` for turns; `pending`, `completed`, `error`, `timed_out` for jobs). |
| `limit` | int | 20 | Max items to return (capped at 100). |

### Response shape

```jsonc
// GET /turns?since=2025-01-01T00:00:00Z&status=completed&limit=10
{
  "turns": [
    {
      "id": "turn_abc",
      "created_at": "2025-01-01T00:00:01Z",
      "updated_at": "2025-01-01T00:00:02Z",
      "status": "completed",
      "final_response": "Hello!",
      "error": ""
    }
  ],
  "server_time": "2025-01-01T00:00:05.123456789Z"
}
```

`GET /jobs` returns the same envelope shape with a `"jobs"` array instead of `"turns"`.

### Example polling loop (Swift)

```swift
var cursor: String? = nil

func poll() async throws {
    var url = baseURL.appendingPathComponent("turns")
    if let since = cursor {
        url.append(queryItems: [URLQueryItem(name: "since", value: since)])
    }
    let (data, _) = try await session.data(from: url)
    let response = try JSONDecoder().decode(PollResponse.self, from: data)
    cursor = response.serverTime  // store for next poll
    process(response.turns)
}
```

## Architecture

```
main.go          HTTP server + config loading
agent/           Turn loop: LLM calls, tool dispatch, streaming
registry/        Tool router (Local vs Device tags)
bridge/          APNs push sender + result fan-in (job_id → chan)
storage/         SQLite persistence (turns + jobs)
tools/local/     Local tool implementations (echo, web_fetch)
tools/device/    Device tool registry (read_calendar)
```

## Testing

```bash
make test
```

Tests cover:
- Registry routing (Local vs Device tag dispatch)
- Bridge timeout and result fan-in (with fake APNs client)
- Integration: mock LLM → echo tool call → round-trip → persisted turn
- Polling: `since` filter, `status` filter, `limit` cap, `server_time` monotonicity, auth rejection

## What's in v0

- Full agent turn loop with OpenAI streaming
- Tool registry with Local/Device routing + parallel dispatch
- APNs bridge with 30s timeout and result fan-in
- SQLite persistence for turns and jobs (survives restart)
- Two local tools: `echo`, `web_fetch`
- One device tool stub: `read_calendar`
- Auth middleware on all data endpoints
- SSE streaming of tokens to the caller
- Graceful shutdown
- Single static binary (`CGO_ENABLED=0`)

## What's deferred (coming next)

- Real APNs JWT signing and HTTP/2 push delivery
- Fallback-to-device-local execution
- Multi-tenant support
- Conversation threading / multi-turn memory beyond single turn
- Rate limiting and request validation
- TLS termination (use a reverse proxy for now)
- Structured logging (currently uses stdlib `log`)
