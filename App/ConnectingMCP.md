# Connecting Agents to Biscotti MCP

You can chat with your Biscotti meeting notes in apps like Claude Desktop or LM Studio. Ask questions like "What did Sarah and I agree to last time we chatted?". It can search meetings and read summaries/notes/transcripts.

It works with any app that speaks [MCP](https://modelcontextprotocol.io), through a local MCP server on your Mac.

## Enabling MCP in Biscotti

MCP is off by default. Enable it in **Settings → General -> MCP**.

## Privacy

The server binds to `127.0.0.1` (local to this machine only). Any app on this Mac can read
your meetings while it is on. Biscotti data doesn't leave your machine, unless another app or agent
you sends it somewhere.

## Instructions for clients

Each client has different connection instructions. Check your agent's docs, or use one of the common ones below:

### VS Code

[![Install in VS Code](https://img.shields.io/badge/VS_Code-Install_Biscotti-0098FF?style=flat-square&logo=visualstudiocode&logoColor=white)](https://vscode.dev/redirect/mcp/install?name=Biscotti&config=%7B%22name%22%3A%22Biscotti%22%2C%22type%22%3A%22http%22%2C%22url%22%3A%22http%3A%2F%2F127.0.0.1%3A8516%2Fmcp%22%7D)

Click the badge and VS Code adds the server for you.

### Cursor

[![Add to Cursor](https://cursor.com/deeplink/mcp-install-dark.svg)](https://cursor.com/install-mcp?name=Biscotti&config=eyJ1cmwiOiJodHRwOi8vMTI3LjAuMC4xOjg1MTYvbWNwIn0=)

### LM Studio

[Add Biscotti to LM Studio](https://lmstudio.ai/install-mcp?name=Biscotti&config=eyJ1cmwiOiJodHRwOi8vMTI3LjAuMC4xOjg1MTYvbWNwIn0=)

### Claude Code (CLI)

```sh
claude mcp add --transport http Biscotti http://127.0.0.1:8516/mcp
```

### Claude Desktop

Claude Desktop cannot reach `localhost` HTTP servers directly, so it needs the
[`mcp-remote`](https://github.com/geelen/mcp-remote) shim (requires Node.js).
Add this to your `claude_desktop_config.json`:

```json
"mcpServers": {
  "biscotti": {
    "command": "npx",
    "args": [
      "-y",
      "mcp-remote",
      "http://127.0.0.1:8516/mcp",
      "--transport",
      "http-only"
    ]
  }
}
```

