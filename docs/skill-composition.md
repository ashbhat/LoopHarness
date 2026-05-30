# Skill Composition

> One user-authored skill can invoke another installed skill from within the
> JavaScript runtime via `host.callSkill(name, args)`.

## API

```js
// Inside any skill's run(args, host) function:
const result = await host.callSkill("other_skill_name", { key: "value" });
```

### Parameters

| Param  | Type     | Description                                      |
|--------|----------|--------------------------------------------------|
| `name` | `string` | The name of an installed skill (folder name).    |
| `args` | `object` | Arguments passed to the invoked skill's `run()`. |

### Return value

Returns whatever the invoked skill's `run()` function resolves to — typically
a JSON object with `status`, `result`/`summary`, etc.

### Error handling

If the called skill throws or rejects, `host.callSkill` rejects with the
error message. Wrap calls in try/catch:

```js
try {
    const res = await host.callSkill("run_ssh_command", { command: "ls" });
} catch (e) {
    host.log("SSH failed: " + e);
    return { status: "error", error: String(e) };
}
```

## Recursion protection

Skills can call other skills, but the runtime enforces a maximum call depth
of **5** to prevent infinite recursion. If a skill exceeds this depth, the
call rejects with `"Max skill call depth (5) exceeded"`.

## Timeout

Each skill invocation (including nested calls) is still subject to the
per-invocation wall-clock timeout (default 30 seconds). Deeply nested
chains share the outer timeout window.

## Runtime config: `host.getConfig(key)`

Skills can read shared, non-secret configuration via:

```js
const relayHost = host.getConfig("ssh_relay_host");
```

This reads from `SkillConfigStore` — a safe allowlist of keys that map to
values the user has configured in Settings → SSH. Only explicitly-allowed
keys are readable; arbitrary Keychain entries are never exposed.

### Allowed config keys

| Key                | Source                         |
|--------------------|-------------------------------|
| `ssh_relay_host`   | Settings → SSH → Host         |
| `ssh_relay_port`   | Settings → SSH → Port         |
| `ssh_relay_user`   | Settings → SSH → Username     |

Additional keys can be added by extending `SkillConfigStore.ConfigKey`.

## Example: Claude Code over SSH relay

The bundled `claude_code` skill uses composition to avoid duplicating relay
logic:

```js
// claude_code/skill.js (simplified)
async function run(args, host) {
    const prompt = args.prompt;
    const command = "claude --print '" + prompt.replace(/'/g, "'\\''") + "'";

    const result = await host.callSkill("run_ssh_command", {
        command: command,
        session_id: args.session_id || "claude-" + Date.now(),
        timeout_ms: args.timeout_ms || 60000
    });

    return {
        status: result.status,
        summary: (result.stdout || "").slice(0, 2000),
        stdout: result.stdout,
        stderr: result.stderr,
        exit_code: result.exit_code
    };
}
```

### Configuration

1. Go to **Settings → SSH** and configure:
   - **Host**: your SSH relay hostname (e.g. `relay.example.com`)
   - **Port**: relay port (default 22)
   - **Username**: relay username
   - **Private key**: your SSH private key (stored in Keychain)

2. The relay host/port/username are automatically synced to the skill config
   store so `run_ssh_command` can read them via `host.getConfig(...)`.

3. The `claude_code` skill calls `run_ssh_command` which reads these values —
   no duplicate configuration needed.

## Security notes

- `host.getConfig` only exposes explicitly-allowed keys. Secrets (private
  keys, API tokens) are **never** exposed to the JS runtime through this API.
- `host.callSkill` cannot invoke arbitrary code — only installed skills that
  have a valid `skill.json` + `skill.js` in the Workspace/Skills folder.
- The recursion depth limit prevents runaway execution.
- Each JSContext is sandboxed: no filesystem access, no process spawning,
  no global state leakage between invocations.
