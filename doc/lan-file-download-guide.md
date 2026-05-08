# 局域网文件传输流程文档

本文档详细说明 WenzAgent 在局域网环境下，设备之间文件传输的完整流程，包括**文件下载**和**文件上传**两种操作。

---

## 目录

- [概述](#概述)
- [核心概念：文件不需要预先上传](#核心概念文件不需要预先上传)
- [架构角色](#架构角色)
- [核心组件](#核心组件)
- [文件传输全景图](#文件传输全景图)
- [文件下载流程](#文件下载流程)
  - [方式一：通过文件元信息下载（推荐）](#方式一通过文件元信息下载推荐)
  - [方式二：通过已知路径直接下载](#方式二通过已知路径直接下载)
  - [方式三：通过服务器中转下载（ fileId ）](#方式三通过服务器中转下载-fileid)
- [文件上传流程](#文件上传流程)
  - [方式一：推送到目标设备（RPC + HTTP Token）](#方式一推送到目标设备rpc--http-token)
  - [方式二：上传到服务器中转缓存](#方式二上传到服务器中转缓存)
- [RPC 协议定义](#rpc-协议定义)
  - [下载请求：DownloadFileRequest](#下载请求downloadfilerequest)
  - [上传请求：UploadFileRequest](#上传请求uploadfilerequest)
  - [RPC 响应格式](#rpc-响应格式)
  - [客户端封装](#客户端封装)
- [Token 安全机制](#token-安全机制)
- [HTTP 端点规范](#http-端点规范)
  - [文件下载端点 GET /file-download](#文件下载端点-get-file-download)
  - [文件上传端点 POST /file-upload](#文件上传端点-post-file-upload)
  - [服务器中转端点](#服务器中转端点)
- [SHA256 完整性校验](#sha256-完整性校验)
- [API 参考](#api-参考)
  - [DeviceClient API](#deviceclient-api)
  - [AgentProxyRemoteOps API](#agentproxyremoteops-api)
- [错误处理](#错误处理)
- [完整时序图](#完整时序图)
- [常见问题](#常见问题)

---

## 概述

WenzAgent 支持在局域网内进行设备间文件传输。文件下载和上传均采用 **RPC 信令 + HTTP 直传** 的两阶段设计：

1. **RPC 阶段**：请求方通过 RPC 通道（经 Server 中转的 WebSocket）向目标设备请求一个临时 Token。
2. **HTTP 阶段**：请求方使用 Token 通过 HTTP 直接与目标设备传输文件内容。

这种设计的优势：
- **控制通道与数据通道分离**：RPC 走 WebSocket（可靠有序），文件数据走 HTTP（高效流式）。
- **安全性**：Token 一次性使用、5 分钟过期、绑定文件路径。
- **性能**：HTTP 流式传输，下载支持 Range 断点续传。

---

## 核心概念：文件不需要预先上传

> **关键理解**：设备间文件传输是**按需直传**，文件始终保留在原设备的磁盘上，不需要先上传到服务器。

WenzAgent 的文件传输有两套完全不同的机制，适用于不同场景：

### 机制 A：设备间直传（RPC Token + HTTP 直连）

```
设备A ←──── HTTP 直连 ────→ 设备B
         （不经过 Server）
```

- **文件始终在原设备磁盘上**，不会预先上传到任何地方。
- 发送方仅发送**文件元信息**（`FileMetaMessage`：文件名、大小、SHA256、路径），不传输文件本身。
- 接收方决定下载时，才通过 RPC → Token → HTTP 链路直接从发送方设备拉取。
- **适用于**：设备间点对点传输大文件。

### 机制 B：服务器中转缓存（fileId）

```
设备A ──上传──→ Server ──下载──→ 设备C
              （文件缓存）
```

- 文件先上传到 Server 的缓存目录，获得 `fileId`。
- 其他设备通过 `fileId` 从 Server 下载。
- **适用于**：群发文件、文件需要被多个设备下载、发送方可能离线的场景。

### 何时使用哪种机制？

| 场景 | 推荐机制 | 原因 |
|------|----------|------|
| A 发送文件给 B | 机制 A（直传） | 高效，不经服务器 |
| A 广播文件给所有人 | 机制 A（元信息广播） | 接收方按需下载 |
| 文件需要被多次下载 | 机制 B（服务器中转） | 文件持久缓存 |
| 发送方即将离线 | 机制 B（服务器中转） | 文件已缓存，不受发送方离线影响 |
| Agent 读写远程设备文件 | 机制 A（直传） | 直接操作目标设备磁盘 |

---

## 架构角色

```
┌─────────────────┐     WebSocket (RPC)     ┌─────────────────┐
│   设备 A (Client)│◄──────────────────────►│  Server (中转)   │
│   请求下载文件    │                         │  转发 RPC 消息    │
└────────┬────────┘                         └────────▲────────┘
         │                                           │
         │ HTTP GET                                  │ WebSocket (RPC)
         │ http://B_IP:B_PORT/file-download?token=xxx│
         │                                           │
         ▼                                           │
┌─────────────────┐                                 │
│   设备 B (Client)│◄────────────────────────────────┘
│   文件所在设备    │   RPC: agentDownloadFile
│   提供 HTTP 下载  │   → 生成 Token + 返回 IP:Port
└─────────────────┘
```

- **Server**：局域网中心节点，负责 WebSocket 连接管理和 RPC 消息路由。
- **设备 A（请求方）**：发起下载请求的客户端设备。
- **设备 B（文件方）**：拥有目标文件的客户端设备，运行 HTTP 服务提供文件下载。

---

## 核心组件

| 组件 | 文件路径 | 职责 |
|------|----------|------|
| `AgentRpcConfig` | `lib/src/agent/rpc/agent_rpc_config.dart` | RPC 方法名常量定义，`methodDownloadFile = 'agentDownloadFile'` |
| `AgentRpcUtil` | `lib/src/agent/rpc/agent_rpc_util.dart` | RPC 调用底层工具，`downloadFile()` 发送 RPC 请求 |
| `DeviceClient` | `lib/src/device/device_client.dart` | 设备客户端统一 API，`requestRemoteDownloadToken()` 和 `downloadFileByMeta()` |
| `DeviceRpcHandler` | `lib/src/device/impl/device_rpc_handler.dart` | RPC 服务端处理器，注册 `agentDownloadFile` 方法，生成下载 Token |
| `FileTransferTokenManager` | `lib/src/device/impl/file_transfer_token_manager.dart` | Token 生命周期管理（生成、验证、过期清理） |
| `LanHostServiceImpl` | `lib/src/lan/impl/lan_host_service_impl.dart` | HTTP 服务器，处理 `/file-download?token=xxx` 请求 |
| `LanChunkService` | `lib/src/lan/lan_chunk_service.dart` | 文件分块传输服务，处理 HTTP 流式读写 |
| `AgentProxyRemoteOps` | `lib/src/agent/client/agent_proxy_remote_ops.dart` | Agent 代理远程操作封装，`requestDownloadToken()` |
| `DownloadFileRequest` | `lib/src/agent/entity/rpc_request_agent.dart` | RPC 请求实体 |
| `FileDownloadUrlResult` | `lib/src/agent/entity/file_transfer_url_result.dart` | 下载结果实体 |

---

## 文件传输全景图

```
┌─────────────────────────────────────────────────────────────────────────┐
│                        文件传输全景图                                     │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                         │
│  机制 A：设备间直传（不经过服务器存储）                                    │
│  ═════════════════════════════════════                                   │
│                                                                         │
│  设备A (发送方)                  Server                   设备B (接收方)  │
│       │                            │                          │          │
│       │ ① sendFileMeta()           │                          │          │
│       │   (仅发元信息，不发文件)     │                          │          │
│       │───────────────────────────►│ ② 转发元信息              │          │
│       │                            │─────────────────────────►│          │
│       │                            │                          │          │
│       │                            │           ③ 接收方决定下载  │          │
│       │                            │           downloadFileByMeta()       │
│       │                            │                          │          │
│       │     ④ RPC: agentDownloadFile (请求Token)               │          │
│       │◄─────────────────────────────────────────────────────  │          │
│       │     ⑤ 返回 {token, hostIp, hostPort}                  │          │
│       │─────────────────────────────────────────────────────►  │          │
│       │                            │                          │          │
│       │     ⑥ HTTP GET /file-download?token=xxx               │          │
│       │◄══════════════════════════════════════════════════════  │          │
│       │     ⑦ 流式返回文件内容（直连，不经服务器）               │          │
│       │                            │                          │          │
│       │     文件始终在A的磁盘上      │              保存到B的磁盘  │          │
│                                                                         │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                         │
│  机制 B：服务器中转缓存                                                  │
│  ═══════════════════                                                    │
│                                                                         │
│  设备A                          Server                    设备C          │
│       │                            │                          │          │
│       │ ① uploadFile(path)         │                          │          │
│       │   HTTP POST /upload        │                          │          │
│       │───────────────────────────►│                          │          │
│       │   返回 fileId              │                          │          │
│       │◄───────────────────────────│                          │          │
│       │                            │                          │          │
│       │                            │   ② downloadFile(fileId) │          │
│       │                            │   HTTP GET /download?fileId=xxx      │
│       │                            │◄─────────────────────────│          │
│       │                            │   返回文件内容            │          │
│       │                            │─────────────────────────►│          │
│       │                            │                          │          │
│       │                   文件缓存在Server磁盘上               │          │
│                                                                         │
└─────────────────────────────────────────────────────────────────────────┘
```

---

## 文件下载流程

### 方式一：通过文件元信息下载（推荐）

当设备 B 通过 `sendFileMeta()` 发送了文件元信息（`FileMetaMessage`），设备 A 可使用 `downloadFileByMeta()` 一键下载。

**适用场景**：设备间主动推送文件，接收方根据元信息自动拉取。

```dart
// 设备 B：发送文件元信息
await deviceClientB.sendFileMeta(
  filePath: '/home/user/report.pdf',
  toDeviceId: 'device-a-id',  // 指定接收方，null 则广播
  employeeId: 'session-001',  // 关联会话
);

// 设备 A：收到 FileMetaMessage 后下载
final savePath = await deviceClientA.downloadFileByMeta(
  fileMeta,                    // FileMetaMessage 实例
  saveDir: '/home/user/downloads',
  onProgress: (progress) {
    print('下载进度: ${(progress * 100).toStringAsFixed(1)}%');
  },
);
```

**内部执行步骤**：

1. **RPC 请求 Token**：调用 `requestRemoteDownloadToken(toDeviceId: meta.fromDeviceId, path: meta.filePath)`。
2. **拼接 URL**：从 RPC 响应中提取 `hostIp`、`hostPort`、`token`，拼接为 `http://{hostIp}:{hostPort}/file-download?token={token}`。
3. **HTTP 下载**：使用 `HttpClient` 流式下载到本地。
4. **SHA256 校验**：下载完成后对比 `meta.sha256` 与实际文件哈希，不匹配则删除并抛出异常。

---

### 方式二：通过已知路径直接下载

当你知道目标设备 ID 和文件绝对路径时，可直接请求下载。

```dart
// 步骤 1：请求下载 Token
final result = await deviceClientA.requestRemoteDownloadToken(
  toDeviceId: 'device-b-id',
  path: '/home/user/document.zip',
);

if (result.error != null || result.url.isEmpty) {
  throw Exception('获取下载 Token 失败: ${result.error}');
}

print('文件名: ${result.fileName}');
print('文件大小: ${result.fileSize} bytes');
print('下载 URL: ${result.url}');
print('Token 有效期: ${result.expiresIn} 秒');

// 步骤 2：通过 HTTP URL 下载（可使用任意 HTTP 客户端）
// URL 格式: http://192.168.1.100:9090/file-download?token=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
```

---

### 方式三：通过服务器中转下载（fileId）

此方式用于下载已上传到 Server 文件缓存中的文件，通过 `fileId` 标识，不使用 Token 机制。

```dart
// 下载已缓存在 Server 的文件
await deviceClientA.downloadFile(
  'file-id-from-upload',
  '/home/user/downloads/file.txt',
);
```

**内部流程**：

1. 通过 `DeviceConnectionManager` → `LanClientServiceImpl` → `LanChunkService`。
2. HTTP GET `http://{hostIp}:{hostPort}/download?fileId={fileId}`。
3. Server 端从文件缓存中读取并流式返回。

> **注意**：此方式下载的是 Server 缓存中的文件，不是设备间直传。适用于已通过 `uploadFile()` 上传到 Server 的文件。

---

---

## 文件上传流程

### 方式一：推送到目标设备（RPC + HTTP Token）

与下载流程对称，上传到目标设备也采用 RPC Token + HTTP 直传机制。文件**不需要预先上传**，而是在需要写入目标设备时按需执行。

**适用场景**：Agent 远程写入文件到目标设备、设备间推送文件。

```dart
// 步骤 1：请求上传 Token
final result = await deviceClientA.requestRemoteUploadToken(
  toDeviceId: 'device-b-id',
  path: '/home/user/new-file.txt',
  overwrite: true,  // 是否覆盖已存在文件
);

if (result.error != null || result.url.isEmpty) {
  throw Exception('获取上传 Token 失败: ${result.error}');
}

print('上传 URL: ${result.url}');
// URL 格式: http://192.168.1.100:9090/file-upload?token=xxxxxxxx

// 步骤 2：通过 HTTP POST 上传文件到目标设备
// 使用任意 HTTP 客户端发送 POST 请求
```

**内部执行步骤**：

1. **RPC 请求 Token**：调用 `invokeFileRpc(method: 'agentUploadFile', params: {path, overwrite})`，经 Server 转发到目标设备。
2. **目标设备生成 Token**：`FileTransferTokenManager.generateUploadToken()` 生成一次性上传 Token，绑定目标路径和覆盖策略。
3. **拼接 URL**：`http://{hostIp}:{hostPort}/file-upload?token={token}`。
4. **HTTP POST 上传**：将文件内容通过 HTTP POST 发送到目标设备。
5. **目标设备写入**：验证 Token 后，流式写入到指定路径（自动创建父目录）。

**流程图**：

```
设备A (上传方)                    Server                   设备B (目标方)
     │                              │                           │
     │ ① RPC: agentUploadFile       │                           │
     │   {path: "/docs/new.txt"}    │                           │
     │─────────────────────────────►│ ② 转发 RPC                 │
     │                              │──────────────────────────►│
     │                              │                  ③ 生成上传 Token
     │                              │                  ④ 返回 {token, hostIp, hostPort}
     │                              │ ⑤ 转发响应                 │
     │◄─────────────────────────────│◄──────────────────────────│
     │                              │                           │
     │ ⑥ HTTP POST /file-upload?token=xxx                       │
     │   (文件内容作为请求体)          │                           │
     │═══════════════════════════════════════════════════════════►│
     │                              │                  ⑦ 验证 Token
     │                              │                  ⑧ 流式写入文件
     │                              │                  ⑨ 返回 HTTP 200
     │◄═══════════════════════════════════════════════════════════│
     │                              │                           │
```

---

### 方式二：上传到服务器中转缓存

将文件上传到 Server 的缓存目录，获得 `fileId`，其他设备可通过 `fileId` 下载。

**适用场景**：群发文件、文件需要被多次下载、发送方可能离线。

```dart
// 上传文件到服务器缓存
final fileId = await deviceClientA.uploadFile('/home/user/report.pdf');
print('文件已上传，fileId: $fileId');

// 其他设备通过 fileId 下载
await deviceClientC.downloadFile(fileId, '/home/user/downloads/report.pdf');
```

**内部执行步骤**：

1. 通过 `LanChunkService.uploadFile()` 发送 HTTP POST 到 `http://{hostIp}:{hostPort}/upload`。
2. Server 将文件保存到缓存目录（`{storagePath}/cache/`），生成唯一 `fileId`。
3. 返回 `{status: 'ok', fileId: 'xxx'}`。

> **注意**：此方式文件存储在 Server 磁盘上，占用 Server 存储空间。

---

## RPC 协议定义

### 下载请求：DownloadFileRequest

| 字段 | 类型 | 必填 | 说明 |
|------|------|------|------|
| `path` | String | ✅ | 目标设备上的文件绝对路径 |

```dart
// 定义位置: lib/src/agent/entity/rpc_request_agent.dart
class DownloadFileRequest {
  final String path;
  const DownloadFileRequest({required this.path});
  Map<String, dynamic> toMap() => {'path': path};
}
```

### 上传请求：UploadFileRequest

| 字段 | 类型 | 必填 | 默认值 | 说明 |
|------|------|------|--------|------|
| `path` | String | ✅ | - | 目标设备上的文件绝对路径 |
| `overwrite` | bool | ❌ | `true` | 是否覆盖已存在文件 |

```dart
// 定义位置: lib/src/agent/entity/rpc_request_agent.dart
class UploadFileRequest {
  final String path;
  final bool overwrite;
  const UploadFileRequest({required this.path, this.overwrite = true});
}
```

### RPC 响应格式

RPC 方法名：`agentDownloadFile` / `agentUploadFile`

**成功响应**：

```json
{
  "success": true,
  "token": "a1b2c3d4-e5f6-7890-abcd-ef1234567890",
  "expiresIn": 300,
  "fileSize": 10485760,
  "fileName": "report.pdf",
  "hostIp": "192.168.1.100",
  "hostPort": 9090
}
```

| 字段 | 类型 | 说明 |
|------|------|------|
| `success` | bool | 是否成功 |
| `token` | String | 一次性 Token（UUID v4） |
| `expiresIn` | int | Token 有效期（秒），固定 300（5 分钟） |
| `fileSize` | int | 文件大小（字节，仅下载响应） |
| `fileName` | String | 文件名（仅下载响应） |
| `hostIp` | String | 目标设备的局域网 IP |
| `hostPort` | int | 目标设备的 HTTP 服务端口 |

**失败响应**：

```json
{
  "success": false,
  "error": "文件不存在: /path/to/file"
}
```

### 客户端封装

请求方收到 RPC 响应后，自动拼接完整 URL：

```dart
// 下载 URL
result['url'] = 'http://$hostIp:$hostPort/file-download?token=$token';

// 上传 URL
result['url'] = 'http://$hostIp:$hostPort/file-upload?token=$token';
```

**FileDownloadUrlResult**（下载）：

```dart
// 定义位置: lib/src/agent/entity/file_transfer_url_result.dart
class FileDownloadUrlResult {
  final String url;        // 完整下载 URL
  final String token;      // 临时 Token
  final int expiresIn;     // 有效期（秒）
  final int fileSize;      // 文件大小
  final String fileName;   // 文件名
  final String? error;     // 错误信息
}
```

**FileUploadUrlResult**（上传）：

```dart
class FileUploadUrlResult {
  final String url;        // 完整上传 URL
  final String token;      // 临时 Token
  final int expiresIn;     // 有效期（秒）
  final String? error;     // 错误信息
}
```

---

## Token 安全机制

`FileTransferTokenManager` 管理临时 Token 的完整生命周期。

### Token 属性

| 属性 | 说明 |
|------|------|
| 格式 | UUID v4 |
| 有效期 | 5 分钟（`Duration(minutes: 5)`） |
| 使用次数 | **一次性**：验证后立即从存储中移除 |
| 绑定信息 | `deviceId` + `filePath` + `operation`（download 或 upload） |

### Token 生命周期

```
生成 ──► 存储 ──► 验证并消费 ──► 销毁
 │                  │
 │    5分钟过期 ─────┤
 │                  ▼
 └──► 定时清理 ◄── null（失效）
```

### 关键方法

```dart
// 生成下载 Token（文件方调用）
FileTransferTokenManager.generateDownloadToken(
  deviceId: 'device-b-id',
  filePath: '/path/to/file',
);

// 验证并消费 Token（HTTP 端点调用，一次性）
FileTransferTokenManager.validateAndConsume(token, 'download');

// 仅验证不消费（用于预检查）
FileTransferTokenManager.validate(token, 'download');
```

### 过期清理

- 每 60 秒自动清理过期 Token。
- `dispose()` 可手动清除所有 Token 和定时器。

---

## HTTP 端点规范

### 文件下载端点 GET /file-download

#### 请求格式

```
GET /file-download?token={token} HTTP/1.1
Host: {hostIp}:{hostPort}
```

**参数说明**：

| 参数 | 位置 | 必填 | 说明 |
|------|------|------|------|
| `token` | Query | ✅ | 一次性下载 Token |

#### 断点续传（Range 支持）

HTTP 端点支持 `Range` 请求头实现断点续传：

```
GET /file-download?token={token} HTTP/1.1
Range: bytes=1048576-
```

**Range 响应**（HTTP 206）：

```
HTTP/1.1 206 Partial Content
Content-Type: application/octet-stream
Content-Disposition: attachment; filename="report.pdf"
Content-Range: bytes 1048576-10485759/10485760
Content-Length: 9437184
Accept-Ranges: bytes
```

**Range 无效**（HTTP 416）：

```
HTTP/1.1 416 Range Not Satisfiable
Content-Range: bytes */10485760
```

### 响应格式

**成功（全量下载，HTTP 200）**：

```
HTTP/1.1 200 OK
Content-Type: application/octet-stream
Content-Disposition: attachment; filename="report.pdf"
Content-Length: 10485760
Accept-Ranges: bytes

<文件二进制流>
```

**Token 缺失（HTTP 400）**：

```
HTTP/1.1 400 Bad Request
Missing token
```

**Token 无效或过期（HTTP 403）**：

```
HTTP/1.1 403 Forbidden
Invalid or expired token
```

**文件不存在（HTTP 404）**：

```
HTTP/1.1 404 Not Found
File not found
```

### 文件上传端点 POST /file-upload

#### 请求格式

```
POST /file-upload?token={token} HTTP/1.1
Host: {hostIp}:{hostPort}
Content-Type: application/octet-stream
Content-Length: {fileSize}

<文件二进制内容>
```

**参数说明**：

| 参数 | 位置 | 必填 | 说明 |
|------|------|------|------|
| `token` | Query | ✅ | 一次性上传 Token |

#### 响应格式

**成功（HTTP 200）**：

```json
{"status": "ok", "bytesWritten": 1048576}
```

**Token 无效或过期（HTTP 403）**：

```
HTTP/1.1 403 Forbidden
Invalid or expired token
```

**文件已存在且 overwrite=false（HTTP 409）**：

```
HTTP/1.1 409 Conflict
File already exists
```

### 服务器中转端点

#### 上传到服务器缓存 POST /upload

```
POST /upload HTTP/1.1
Host: {serverIp}:{serverPort}
Content-Type: application/octet-stream
X-File-Name: {fileName}

<文件二进制内容>
```

**成功响应**：

```json
{"status": "ok", "fileId": "abc123"}
```

#### 从服务器缓存下载 GET /download

```
GET /download?fileId={fileId} HTTP/1.1
Host: {serverIp}:{serverPort}
```

**成功响应**：文件流式返回（`application/octet-stream`）。

---

使用 `downloadFileByMeta()` 下载时，下载完成后会自动进行 SHA256 校验：

```dart
// 下载完成后校验
final savedBytes = await File(savePath).readAsBytes();
final actualHash = sha256.convert(savedBytes).toString();
if (actualHash != meta.sha256) {
  await File(savePath).delete();
  throw Exception('文件校验失败: SHA256 不匹配');
}
```

**校验流程**：
1. 读取已下载文件的全部字节。
2. 计算 SHA256 哈希值。
3. 与 `FileMetaMessage.sha256` 对比。
4. 不匹配则删除已下载文件并抛出异常。

> **注意**：使用 `requestRemoteDownloadToken()` 方式不会自动校验，需要调用方自行实现。

---

## API 参考

### DeviceClient API

```dart
// 文件位置: lib/src/device/device_client.dart

// ===== 设备间直传（机制 A）=====

/// 请求远程设备文件下载 Token
///
/// [toDeviceId] 目标设备 ID
/// [path] 目标设备上的文件绝对路径
///
/// 返回 FileDownloadUrlResult，包含完整下载 URL 和文件元信息
Future<FileDownloadUrlResult> requestRemoteDownloadToken({
  required String toDeviceId,
  required String path,
})

/// 请求远程设备文件上传 Token
///
/// [toDeviceId] 目标设备 ID
/// [path] 目标设备上的目标文件绝对路径
/// [overwrite] 是否覆盖已存在文件
///
/// 返回 FileUploadUrlResult，包含完整上传 URL
Future<FileUploadUrlResult> requestRemoteUploadToken({
  required String toDeviceId,
  required String path,
  bool overwrite = true,
})

/// 发送文件元信息到指定设备（或广播）
///
/// 不会上传文件本身，仅发送元信息。接收方根据元信息自行下载。
///
/// [filePath] 本地文件路径
/// [toDeviceId] 目标设备 ID（null 则广播）
/// [employeeId] 关联会话 ID
Future<void> sendFileMeta({
  required String filePath,
  String? toDeviceId,
  String role = 'user',
  String? employeeId,
})

/// 根据文件元信息从远端设备下载文件（推荐）
///
/// [meta] 文件元信息（FileMetaMessage）
/// [saveDir] 本地保存目录
/// [onProgress] 下载进度回调 (0.0 ~ 1.0)
///
/// 返回本地保存路径，自动进行 SHA256 校验
Future<String> downloadFileByMeta(
  FileMetaMessage meta, {
  required String saveDir,
  void Function(double progress)? onProgress,
})

// ===== 服务器中转（机制 B）=====

/// 上传文件到服务器缓存
///
/// [filePath] 本地文件路径
///
/// 返回 fileId
Future<String> uploadFile(String filePath)

/// 通过 fileId 下载 Server 缓存的文件
///
/// [fileId] 文件 ID（上传时返回）
/// [savePath] 本地保存路径
Future<void> downloadFile(String fileId, String savePath)
```

### AgentProxyRemoteOps API

```dart
// 文件位置: lib/src/agent/client/agent_proxy_remote_ops.dart

/// 请求远程文件下载 Token
///
/// [path] 远程文件路径
///
/// 返回 FileDownloadUrlResult
/// URL 格式: http://{hostIp}:{hostPort}/file-download?token={token}
Future<FileDownloadUrlResult> requestDownloadToken(String path)

/// 请求远程文件上传 Token
///
/// [path] 远程目标文件路径
/// [overwrite] 是否覆盖
///
/// 返回 FileUploadUrlResult
/// URL 格式: http://{hostIp}:{hostPort}/file-upload?token={token}
Future<FileUploadUrlResult> requestUploadToken(String path, {bool overwrite = true})
```

---

## 错误处理

### RPC 阶段错误

| 错误场景 | 响应 | 处理建议 |
|----------|------|----------|
| 文件不存在 | `{success: false, error: "文件不存在: /path"}` | 检查文件路径是否正确 |
| 文件方设备离线 | RPC 超时 | 确认目标设备在线 |
| 文件无读取权限 | `{success: false, error: "生成下载链接失败: ..."}` | 检查文件权限 |

### HTTP 下载阶段错误

| HTTP 状态码 | 原因 | 处理建议 |
|-------------|------|----------|
| 400 | Token 缺失 | 检查 URL 是否包含 token 参数 |
| 403 | Token 无效/过期/已使用 | 重新请求 Token |
| 404 | 文件已被删除 | 确认文件存在后重试 |
| 416 | Range 越界 | 检查 Range 头的值 |

### 校验错误

| 错误场景 | 异常信息 | 处理建议 |
|----------|----------|----------|
| SHA256 不匹配 | `文件校验失败: SHA256 不匹配` | 文件可能传输损坏，重新下载 |

---

## 完整时序图

```
请求方 (设备A)                     Server                    文件方 (设备B)
     │                               │                           │
     │  ┌──────────────────────────────────────────────────────┐ │
     │  │ 阶段 1: RPC 信令 (WebSocket)                          │ │
     │  └──────────────────────────────────────────────────────┘ │
     │                               │                           │
     │  invokeFileRpc({              │                           │
     │    toDeviceId: 'device-b',    │                           │
     │    method: 'agentDownloadFile'│                           │
     │    params: {path: '/docs/f.pdf'}                         │ │
     │  })                           │                           │
     │ ─────────────────────────────►│                           │
     │                               │  转发 RPC 到 device-b     │
     │                               │ ─────────────────────────►│
     │                               │                           │
     │                               │                 ┌─────────┴─────────┐
     │                               │                 │ 检查文件存在       │
     │                               │                 │ File.exists(path)  │
     │                               │                 │ File.stat() → size │
     │                               │                 │                    │
     │                               │                 │ 生成 Token:        │
     │                               │                 │ FileTransferToken  │
     │                               │                 │   .generateDownload│
     │                               │                 │   Token(           │
     │                               │                 │     deviceId,      │
     │                               │                 │     filePath       │
     │                               │                 │   )                │
     │                               │                 └─────────┬─────────┘
     │                               │                           │
     │                               │  返回 RPC 响应            │
     │                               │◄───────────────────────── │
     │                               │  {success: true,          │
     │                               │   token: "uuid...",       │
     │                               │   expiresIn: 300,         │
     │                               │   fileSize: 1048576,      │
     │                               │   fileName: "f.pdf",      │
     │                               │   hostIp: "192.168.1.100",│
     │                               │   hostPort: 9090}         │
     │                               │                           │
     │  返回 RPC 响应                │                           │
     │◄──────────────────────────────│                           │
     │                               │                           │
     │  ┌──────────────────────────────────────────────────────┐ │
     │  │ 阶段 2: HTTP 直传 (TCP)                               │ │
     │  └──────────────────────────────────────────────────────┘ │
     │                               │                           │
     │  拼接 URL:                    │                           │
     │  http://192.168.1.100:9090/   │                           │
     │  file-download?token=uuid...  │                           │
     │                               │                           │
     │  HTTP GET (URL)               │                           │
     │ ─────────────────────────────────────────────────────────►│
     │                               │                           │
     │                               │                 ┌─────────┴─────────┐
     │                               │                 │ validateAndConsume │
     │                               │                 │ (token, 'download')│
     │                               │                 │                    │
     │                               │                 │ Token 有效 →       │
     │                               │                 │ 读取文件流式返回    │
     │                               │                 │ Token 无效 → 403   │
     │                               │                 └─────────┬─────────┘
     │                               │                           │
     │  HTTP 200 (文件流)            │                           │
     │  Content-Length: 1048576      │                           │
     │  Accept-Ranges: bytes         │                           │
     │◄───────────────────────────────────────────────────────── │
     │                               │                           │
     │  ┌──────────────────────────────────────────────────────┐ │
     │  │ 阶段 3: 本地写入 + 校验                                │ │
     │  └──────────────────────────────────────────────────────┘ │
     │                               │                           │
     │  流式写入本地文件              │                           │
     │  onProgress(received/total)   │                           │
     │                               │                           │
     │  计算 SHA256                  │                           │
     │  对比 meta.sha256             │                           │
     │  匹配 → 返回 savePath         │                           │
     │  不匹配 → 删除文件 + 抛异常    │                           │
     │                               │                           │
     ▼                               ▼                           ▼
```

---

## 常见问题

### Q1: 下载失败，提示 "Invalid or expired token"

**原因**：
- Token 已被使用过（一次性 Token）。
- Token 已超过 5 分钟有效期。
- Token 字符串不完整或被截断。

**解决方案**：重新调用 `requestRemoteDownloadToken()` 获取新 Token。

### Q2: RPC 调用成功但 HTTP 下载连接失败

**原因**：
- 文件方设备的 IP 地址不可达（不在同一子网）。
- 文件方设备的 HTTP 端口被防火墙阻止。
- 文件方设备在 RPC 响应后、HTTP 下载前断线。

**解决方案**：
1. 确认两台设备在同一局域网内，可以互相 ping 通。
2. 检查防火墙设置，确保文件方设备的 HTTP 端口（默认跟随 Server 配置）开放。
3. 检查文件方设备是否在线。

### Q3: 大文件下载超时

**原因**：Token 有效期仅 5 分钟，如果从获取 Token 到开始 HTTP 下载间隔过长，Token 可能过期。

**解决方案**：获取 Token 后应立即发起 HTTP 下载，不要延迟。Token 仅控制下载请求的发起，下载过程中的数据传输不受 Token 过期影响。

### Q4: SHA256 校验失败

**原因**：
- 网络传输过程中数据损坏。
- 文件在下载期间被修改或删除。

**解决方案**：重新下载文件。如果持续失败，检查文件方设备上文件是否被占用或频繁修改。

### Q5: 如何实现断点续传？

在 HTTP 下载请求中添加 `Range` 头即可：

```dart
final request = await client.getUrl(uri);
request.headers.set('range', 'bytes=$downloadedBytes-');
```

服务端会返回 HTTP 206 和对应范围的数据。注意：每个 Range 请求需要独立的 Token。

### Q6: 文件没有上传，怎么下载？

**这是本文档最核心的问题。**

WenzAgent 的设备间文件传输是**按需直传**，文件**不需要预先上传**。完整流程如下：

1. **发送方**调用 `sendFileMeta()` 仅发送文件元信息（文件名、大小、SHA256、路径），**不传输文件本身**。
2. **接收方**收到元信息后，决定是否下载。
3. 如果需要下载，接收方调用 `downloadFileByMeta()`，此时才通过 RPC → Token → HTTP 链路直接从发送方设备拉取文件。

文件始终保留在发送方设备的磁盘上，直到接收方主动拉取时才进行传输。

### Q7: 什么时候需要上传到服务器？

只有以下场景需要使用 `uploadFile()` 上传到服务器缓存：

- 文件需要被**多个设备**下载（避免每个设备都从发送方拉取）。
- 发送方**即将离线**，但文件需要持续可下载。
- 需要**持久化存储**文件（服务器缓存不自动清理）。

大多数设备间文件传输场景不需要上传到服务器，直接使用 `sendFileMeta()` + `downloadFileByMeta()` 即可。

### Q8: downloadFile() 和 requestRemoteDownloadToken() 的区别？

| 方法 | 用途 | 传输路径 |
|------|------|----------|
| `downloadFile(fileId, savePath)` | 下载 Server 缓存文件 | Client → Server |
| `requestRemoteDownloadToken()` | 获取设备间直传 Token | Client → Server → Client（RPC） |
| `requestRemoteUploadToken()` | 获取设备间上传 Token | Client → Server → Client（RPC） |
| `downloadFileByMeta()` | 一站式设备间下载 | Client → Server → Client（RPC + HTTP） |
| `uploadFile()` | 上传文件到 Server 缓存 | Client → Server |

---

## 相关文档

- [LAN Server & Client 使用指南](./lan-server-client-guide.md) — 局域网部署和配置
- [前端集成指南](./frontend-integration-guide.md) — 前端应用接入方式
