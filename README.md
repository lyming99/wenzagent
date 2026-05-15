

# WenzAgent

<p align="center">
  <strong>纯 Dart 实现的 AI Agent 管理框架 — 局域网通信 · RPC · 技能系统</strong>
</p>
<p align="center">
  <a href="https://github.com/lyming99/wenzagent/blob/main/LICENSE">
    <img src="https://img.shields.io/badge/License-Apache%202.0-blue.svg" alt="License: Apache-2.0">
  </a>
  <img src="https://img.shields.io/badge/Dart-%5E3.11.0-0175C2.svg" alt="Dart SDK">
  <img src="https://img.shields.io/badge/Platform-All%20Platforms-green.svg" alt="Platform">
</p>

---

## 📖 项目简介

**WenzAgent** 是一个纯 Dart 实现的 AI Agent 管理框架，提供完整的 Agent 生命周期管理、局域网设备发现与通信、远程过程调用（RPC）以及可扩展的技能系统。无需原生依赖，可跨平台运行。

### 🎬 演示视频

[![Bilibili](https://img.shields.io/badge/📺_观看演示视频-Bilibili-FB7299?style=for-the-badge&logo=bilibili&logoColor=white)](https://www.bilibili.com/video/BV1PN5i62Ebm)

### 核心特性

- 🤖 **Agent 系统** — 创建和管理 AI Agent，支持多种 LLM 后端、工具调用和状态管理

- 🌐 **局域网通信** — 基于 WebSocket 的设备自动发现、消息收发和文件分片传输

- 🔌 **RPC 框架** — 跨设备远程过程调用，支持请求-响应和通知模式

- 🛠️ **技能系统** — 可扩展的技能架构，支持 MCP（Model Context Protocol）、文件夹提示词和配置驱动技能

- 💾 **持久化存储** — 基于 SQLite 的消息、会话和 Agent 状态存储

- ⏰ **任务调度** — 基于 Cron 表达式的定时任务调度器

## 📦 模块介绍

```
wenzagent/
├── lib/src/
│   ├── agent/          # 🤖 Agent 核心
│   │   ├── adapter/    #     LLM 适配器（OpenAI、Anthropic、Google、Ollama）
│   │   ├── client/     #     LLM 客户端封装
│   │   ├── entity/     #     Agent 数据模型
│   │   ├── impl/       #     Agent 实现
│   │   ├── processor/  #     消息处理器（Tool Call 流处理）
│   │   ├── tool/       #     内置工具集（文件操作、命令执行等）
│   │   ├── rpc/        #     Agent 远程代理
│   │   └── tracker/    #     Agent 状态追踪
│   ├── device/         # 📱 设备连接管理与状态
│   ├── host/           # 🏠 主机服务与 Session 管理
│   ├── lan/            # 🌐 局域网通信
│   │   ├── impl/       #     发现、主机/客户端服务实现
│   │   └── lan_chunk_service.dart  # 大文件分片传输
│   ├── rpc/            # 🔌 RPC 协议与服务
│   │   ├── rpc_protocol.dart       # RPC 协议定义
│   │   ├── remote_call_server.dart # RPC 服务端
│   │   └── remote_call_manager.dart # RPC 调用管理
│   ├── scheduler/      # ⏰ Cron 解析器与任务调度
│   ├── skill/          # 🛠️ 技能系统
│   │   ├── mcp/        #     MCP 协议集成
│   │   ├── folder/     #     文件夹提示词技能
│   │   ├── config/     #     配置驱动技能
│   │   └── skill_manager.dart  # 技能管理器
│   ├── persistence/    # 💾 SQLite 持久化（数据库、存储、迁移）
│   ├── service/        # 📋 业务服务（EmployeeManager、SessionManager 等）
│   ├── shared/         # 💬 通用消息模型
│   ├── sdk/            # 📦 SDK 入口（Builder 模式）
│   └── utils/          # 🔧 工具类
├── example/            # 示例代码
├── doc/                # 设计文档
└── test/               # 测试用例

```

### Agent 核心

Agent 是框架的核心抽象，每个 Agent（员工）绑定一个 LLM 后端，拥有独立的系统提示词、工具集和状态管理。支持：

- **多 LLM 后端**：OpenAI、Anthropic、Google、Ollama

- **工具调用**：内置文件操作、命令执行、Git 操作等工具，支持自定义扩展

- **状态管理**：完整的 Agent 生命周期追踪（创建→运行→暂停→停止）

- **远程代理**：通过 RPC 在其他设备上创建和管理 Agent

### 局域网通信

基于 WebSocket 的局域网通信模块，支持：

- **设备自动发现**：主机广播，客户端自动连接

- **消息收发**：设备间实时消息传递

- **文件传输**：大文件分片传输，支持断点续传

- **Topic 分组**：客户端可加入不同主题频道

### 技能系统

可扩展的技能架构，Agent 可以通过技能获得额外能力：

- **MCP 技能**：集成 Model Context Protocol，连接外部工具服务器

- **文件夹技能**：从指定目录加载提示词文件作为技能

- **配置技能**：通过 YAML 配置定义技能行为

- **自定义技能**：实现 **Skill** 接口即可扩展

### 任务调度

内置 Cron 表达式解析器和任务调度器，支持定时执行 Agent 操作。

## 🚀 快速使用

### 环境要求

- Dart SDK >= 3.11.0

### 安装

在 pubspec.yaml 中添加依赖：

```yaml
dependencies:
  wenzagent:
    git:
      url: https://github.com/lyming99/wenzagent.git

```

### SDK 基础用法

```dart
import 'package:wenzagent/wenzagent.dart';

void main() async {
  // 1. 使用 Builder 创建 SDK 实例
  final sdk = WenzAgentSdk.builder()
      .excludeBuiltinTools(['command_execute', 'bg_command']) // 排除危险工具
      .build();

  // 2. 创建 Agent
  final agent = await sdk.createAgent(AgentConfig(
    employeeId: 'emp-001',
    providerConfig: ProviderConfig(
      provider: LLMProvider.openai,
      model: 'gpt-4o',
      apiKey: 'sk-...',
    ),
    systemPrompt: '你是一个有用的助手。',
  ));

  // 3. 与 Agent 对话
  final response = await agent.chat('你好，请介绍一下你自己');
  print(response);
}

```

### 自定义工具

```dart
final sdk = WenzAgentSdk.builder()
    .onlyBuiltinTools(['file_read', 'file_write']) // 仅保留指定工具
    .registerTool(MyWeatherTool())                  // 注册自定义工具
    .registerSkills([MyEchoSkill()])               // 注册自定义技能
    .build();

```

### 使用 Ollama 本地模型

```dart
final agent = await sdk.createAgent(AgentConfig(
  employeeId: 'local-agent',
  providerConfig: ProviderConfig(
    provider: LLMProvider.ollama,
    model: 'llama3',
    baseUrl: 'http://localhost:11434',
  ),
));

```

### 启动局域网服务

```bash
# 启动服务端（机器 A）
dart run bin/wenzagent_server.dart --port 9090

# 启动客户端（机器 B、C ...）
dart run bin/wenzagent_client.dart --host <服务端IP>

```

### CLI 参数

|参数|服务端|客户端|默认值|说明|
|:---|:---|:---|:---|:---|
--config|✅|✅|wenzagent.yaml|YAML 配置文件路径|
--host|-|✅|（必填）|服务端 IP 地址|
--port|✅|✅|9090|端口号（1-65535）|
--device-id|✅|✅|自动 UUID|设备 ID|
--storage-path|✅|✅|./data|本地存储目录|
--log-level|✅|✅|info|日志级别：debug/info/warn/error/none|
--topic|-|✅|（无）|客户端分组主题|


配置优先级：CLI 参数 > YAML 配置文件 > 默认值

更多示例请参考 [example/](example/) 目录。

## 🔗 相关作品

- wenzflow: 一款集成笔记、文档、AI的智能效率工工具， [https://wenzflow.com](https://wenzflow.com)

## 📬 联系方式

- **交流群**：1102616387

- **QQ**: 44185539

- **微信**：lyming555