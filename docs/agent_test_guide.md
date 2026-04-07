# Agent 功能测试

## 概述

本测试套件用于验证 Agent 的所有核心功能，确保系统在生产环境中稳定可靠。

## 测试环境要求

### 环境变量

测试使用真实的 OpenAI API，需要设置以下环境变量：

#### 必需环境变量

- `OPENAI_API_KEY`: OpenAI API 密钥

#### 可选环境变量

- `OPENAI_API_URL`: API 基础 URL（默认：`https://api.openai.com/v1`）
- `OPENAI_API_MODEL`: 模型名称（默认：`gpt-3.5-turbo`）

## 设置环境变量

### Windows (PowerShell)

```powershell
$env:OPENAI_API_KEY="your-api-key-here"
$env:OPENAI_API_URL="https://api.openai.com/v1"  # 可选
$env:OPENAI_API_MODEL="gpt-3.5-turbo"  # 可选
```

### Linux / macOS

```bash
export OPENAI_API_KEY="your-api-key-here"
export OPENAI_API_URL="https://api.openai.com/v1"  # 可选
export OPENAI_API_MODEL="gpt-3.5-turbo"  # 可选
```

## 运行测试

### 方法 1: 使用测试脚本（推荐）

```bash
dart run_test.dart
```

该脚本会自动检查环境变量并运行测试。

### 方法 2: 直接运行测试

```bash
# 运行基础功能测试
dart test test/agent_basic_test.dart --reporter=expanded

# 运行完整功能测试
dart test test/agent_functional_test.dart --reporter=expanded
```

## 测试套件说明

### 基础功能测试 (`agent_basic_test.dart`)

测试核心功能：

- ✅ 发送消息并收到回复
- ✅ 消息ID一致性（客户端生成的ID不被修改）
- ✅ 消息不重复原则
- ✅ 状态监听（思考中、回复中）
- ✅ 删除消息功能
- ✅ 清空消息功能

**预计运行时间**: 约 2-3 分钟

### 完整功能测试 (`agent_functional_test.dart`)

测试所有功能点：

#### 基础消息功能
- 发送消息，远程端收到回复
- 客户端消息ID不被修改
- 客户端消息不重复原则

#### 状态监听测试
- 思考中状态监听
- 回复中状态监听

#### 技能调用测试
- 技能调用状态监听

#### 权限管理测试
- 权限申请状态监听
- 权限申请状态打断机制

#### 消息管理测试
- 删除消息功能
- 删除处理中的消息（打断后删除）
- 清空消息功能
- 清空处理中的消息（打断后清空）

#### 消息接收状态测试
- 消息已接收状态
- 消息状态更新后，已接收状态移除

#### 重发机制测试
- 发送失败后支持重发
- 重发时消息已被处理

#### 打断机制测试
- 打断正在执行的任务

#### 会话状态查询测试
- 会话状态查询（非监听）
- 离线后重连查询状态

#### 完整流程测试
- 完整对话流程（上下文保持）

**预计运行时间**: 约 10-15 分钟

## 测试架构

### 组件关系

```
┌─────────────────────────────────────────┐
│          测试环境                         │
│  - 真实 OpenAI API                        │
│  - Hive 本地存储                          │
└─────────────────────────────────────────┘
                    │
        ┌───────────┴───────────┐
        │                       │
┌───────▼────────┐     ┌────────▼──────┐
│  AgentImpl     │     │  AgentProxy   │
│  (服务端)      │◄────│  (客户端)     │
│  - 消息处理    │     │  - 本地模式   │
│  - 状态管理    │     │  - 消息缓存   │
└───────┬────────┘     └────────┬──────┘
        │                       │
        │              ┌────────▼──────────┐
        │              │ CachedAgentProxy  │
        │              │ - 本地缓存        │
        │              │ - 离线支持        │
        │              └────────┬──────────┘
        │                       │
┌───────▼────────────────────────▼──────┐
│      PersistentChatAdapter             │
│  - 会话持久化                          │
│  - 消息持久化                          │
└───────────────────────────────────────┘
```

### 数据流

1. **发送消息**:
   ```
   Client → CachedAgentProxy → AgentProxy → AgentImpl → ChatAdapter → OpenAI API
   ```

2. **接收回复**:
   ```
   OpenAI API → ChatAdapter → AgentImpl → AgentProxy → CachedAgentProxy → Client
   ```

3. **状态监听**:
   ```
   AgentImpl → AgentProxy → CachedAgentProxy → Client
   ```

4. **消息缓存**:
   ```
   CachedAgentProxy ↔ MessageStoreService ↔ Hive
   ```

## 测试策略

### 使用真实配置

测试使用真实的 OpenAI API 而不是模拟，原因：

1. **真实性**: 测试真实的网络请求、响应和错误处理
2. **完整性**: 验证整个请求链路（从客户端到API）
3. **可靠性**: 发现潜在的集成问题
4. **实用性**: 确保系统在生产环境中可用

### 测试覆盖

- **功能测试**: 验证每个功能点是否按预期工作
- **集成测试**: 验证组件之间的协作
- **状态测试**: 验证状态转换的正确性
- **错误处理**: 验证异常情况的处理
- **并发测试**: 验证多消息处理的正确性

## 常见问题

### Q: 测试失败怎么办？

**A**: 检查以下几点：

1. 环境变量是否正确设置
2. API 密钥是否有效
3. 网络连接是否正常
4. API 配额是否充足

### Q: 测试超时怎么办？

**A**: 可能原因：

1. API 响应慢 - 增加超时时间
2. 网络问题 - 检查网络连接
3. 模型过载 - 尝试使用其他模型

### Q: 如何只运行特定测试？

**A**: 使用 `--name` 参数：

```bash
dart test test/agent_basic_test.dart --name="发送消息"
```

### Q: 如何查看详细日志？

**A**: 使用 `--reporter=expanded` 参数：

```bash
dart test test/agent_basic_test.dart --reporter=expanded
```

## 持续集成

可以将测试集成到 CI/CD 流程中：

```yaml
# GitHub Actions 示例
name: Agent Tests

on: [push, pull_request]

jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v2
      - uses: dart-lang/setup-dart@v1
      
      - name: Install dependencies
        run: dart pub get
      
      - name: Run tests
        env:
          OPENAI_API_KEY: ${{ secrets.OPENAI_API_KEY }}
          OPENAI_API_URL: ${{ secrets.OPENAI_API_URL }}
          OPENAI_API_MODEL: ${{ secrets.OPENAI_API_MODEL }}
        run: dart test test/agent_basic_test.dart --reporter=expanded
```

## 性能基准

在标准测试环境下（OpenAI API，gpt-3.5-turbo）：

- 单次消息发送到接收回复: 2-5秒
- 完整基础测试套件: 2-3分钟
- 完整功能测试套件: 10-15分钟

## 贡献指南

添加新测试时：

1. 遵循现有测试结构
2. 使用真实配置而非模拟
3. 添加清晰的测试说明
4. 确保测试可重复运行
5. 处理好资源清理（tearDown）

## 许可证

MIT License
