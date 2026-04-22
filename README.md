# WenzAgent

Pure Dart library for AI Agent management, LAN communication, and RPC.

## Features

- **Agent System** — Create and manage AI agents (employees) with configurable LLM backends, tool calling, and state management
- **LAN Communication** — Device discovery and messaging over local area network via WebSocket
- **RPC Framework** — Remote procedure call layer for inter-device communication
- **Skill System** — Extensible skill architecture supporting MCP (Model Context Protocol), folder-based prompts, and configuration-driven skills
- **Persistence** — SQLite-backed storage for messages, sessions, and agent state
- **Task Scheduling** — Cron-based task scheduler for automated agent operations

## Architecture

```
wenzagent/
├── lib/src/
│   ├── agent/          # Agent interface, implementation, proxy, processor, LLM adapters
│   ├── device/         # Device connection management and state
│   ├── entity/         # Data models (LanMessage, LanClient, HostRpcRequest)
│   ├── host/           # Host server with session management
│   ├── lan/            # LAN discovery, host/client services, chunk transfer
│   ├── persistence/    # SQLite database, stores, migrations
│   ├── rpc/            # Remote call protocol, server, config
│   ├── scheduler/      # Cron expression parser, task scheduler
│   ├── service/        # Business services (EmployeeManager, SessionManager, etc.)
│   ├── shared/         # ChatMessage, message mappers
│   ├── skill/          # Skill system (MCP, folder, config)
│   └── utils/          # Utilities
├── example/            # Usage examples
├── doc/                # Design documents
└── test/               # Tests
```

## Quick Start

See [QUICKSTART.md](QUICKSTART.md) for environment setup and running tests.

## LAN Server & Client

WenzAgent provides standalone CLI tools for running a LAN server and client.

### Start the Server

```bash
# Use defaults (port 9090, auto-generated device ID)
dart run bin/wenzagent_server.dart

# Specify port and device ID
dart run bin/wenzagent_server.dart --port 8080 --device-id "host-001"

# Use a YAML config file
dart run bin/wenzagent_server.dart --config my_server.yaml

# Print version or help
dart run bin/wenzagent_server.dart --version
dart run bin/wenzagent_server.dart --help
```

### Start the Client

```bash
# Connect to a server (host is required)
dart run bin/wenzagent_client.dart --host 192.168.1.100

# Specify port, device name, and topic
dart run bin/wenzagent_client.dart --host 192.168.1.100 --port 9090 --device-name "My Laptop" --topic team-a

# Use a YAML config file
dart run bin/wenzagent_client.dart --config my_client.yaml
```

### CLI Parameters

| Parameter | Server | Client | Default | Description |
|-----------|--------|--------|---------|-------------|
| `--config` | Yes | Yes | `wenzagent.yaml` / `wenzagent_client.yaml` | YAML config file path |
| `--host` | - | Yes | (required) | Server IP address |
| `--port` | Yes | Yes | 9090 | Port number (1-65535) |
| `--device-id` | Yes | Yes | Auto UUID | Device ID |
| `--host-name` / `--device-name` | Yes | Yes | "WenzAgent Server" / "WenzAgent Client" | Display name |
| `--storage-path` | Yes | Yes | `./data` | Local storage directory |
| `--log-level` | Yes | Yes | info | Log level: debug/info/warn/error/none |
| `--topic` | - | Yes | (none) | Group topic for the client |
| `--version` | Yes | Yes | - | Print version |
| `--help` | Yes | Yes | - | Print help |

### Configuration Priority

CLI arguments > YAML config file > default values

### Example Config Files

See [config/wenzagent_server.yaml.example](config/wenzagent_server.yaml.example) and [config/wenzagent_client.yaml.example](config/wenzagent_client.yaml.example).

### Typical Setup

```bash
# On machine A (server)
dart run bin/wenzagent_server.dart --port 9090

# On machine B, C, ... (clients)
dart run bin/wenzagent_client.dart --host <server-ip>
```

## Documentation

- [Skill System Design](doc/skill_system_design.md)
- [Cached Agent Proxy Guide](doc/cached-agent-proxy-guide.md)
- [Tool Call Status Frontend Guide](doc/tool-call-status-frontend-guide.md)

## Using Ollama

WenzAgent supports [Ollama](https://ollama.ai) as a local LLM provider, enabling fully local AI agents without cloud API keys.

### Prerequisites

1. Install Ollama: see [ollama.ai](https://ollama.ai)
2. Start the service: `ollama serve`
3. Pull a model: `ollama pull llama3`

### Configuration

Set the provider to `ollama` in your agent configuration:

```yaml
provider: ollama
model: llama3
baseUrl: http://localhost:11434   # Optional, this is the default
apiKey: ""                          # Not needed for Ollama
```

### Model Discovery

Use `OllamaClient` to list available models programmatically:

```dart
import 'package:wenzagent/wenzagent.dart';

final client = OllamaClient();

// Check if Ollama is running
final healthy = await client.isHealthy();

// List installed models
final models = await client.listModels();
for (final model in models) {
  print('${model.name} (${model.size} bytes)');
}

// Get model details
final detail = await client.showModel('llama3');
print('Family: ${detail?.family}, Params: ${detail?.parameterSize}');
```

### Supported Providers

| Provider | API Key Required | Default Base URL |
|----------|-----------------|------------------|
| `openai` | Yes | `https://api.openai.com/v1` |
| `anthropic` | Yes | `https://api.anthropic.com` |
| `google` | Yes | `https://generativelanguage.googleapis.com` |
| `ollama` | No | `http://localhost:11434` |

## License

See [LICENSE](LICENSE).
