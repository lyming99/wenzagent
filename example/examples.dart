/// WenzAgent 示例集合
///
/// 运行方式：
/// - 文件上传下载: dart run example/file_transfer_example.dart
/// - RPC 同步调用: dart run example/rpc_call_example.dart
/// - RPC 流式调用: dart run example/rpc_stream_example.dart
/// - 综合示例: dart run example/full_example.dart
///
/// 架构说明：
/// ```
/// ┌─────────────┐         ┌─────────────┐         ┌─────────────┐
/// │   Client A  │ ◄─────► │    Host     │ ◄─────► │   Client B  │
/// │  (Caller)   │  RPC    │  (中转站)    │  RPC    │  (Server)   │
/// └─────────────┘         └─────────────┘         └─────────────┘
/// ```
///
/// 核心概念：
/// 1. **Host**: 中转服务器，负责消息转发、文件存储
/// 2. **Client**: 连接到 Host 的客户端，通过 spaceId 标识
/// 3. **RPC**: 远程过程调用，支持同步和流式两种模式
/// 4. **Agent**: AI Agent 实例，可通过 RPC 远程操作
library;

// 注意：每个示例文件都有独立的 main 函数，请单独运行
// 不要同时导入所有示例文件
