# Portable Loop Runner (v0)

A Go-based agent runtime that runs the agent loop + local tools on a remote VM, bridging device-only tools back to an iOS device via APNs push.

## Requirements

- Linux amd64 (or any platform Go supports for development)
- Go 1.22+ (for building from source)
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

**Auth:** All protected endpoints require `Authorization: Bearer <shared_secret>` header.

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
