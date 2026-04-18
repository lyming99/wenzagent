# Employee Session 系统 - 阶段性任务测试规划

> **项目**: wenzagent  
> **版本**: v1.0  
> **日期**: 2025-07-11  
> **范围**: Employee Session 数据模型 + Device Client RPC 功能链路  

---

## 一、系统架构总览

### 1.1 核心概念

Employee Session 是 wenzagent 的核心数据模型，以 **`employeeId + deviceId`** 为复合维度组织数据：

```
┌─────────────────────────────────────────────────────────────┐
│  Employee (AiEmployeeEntity)                                 │
│  PK: uuid (employeeId)                                       │
│  全局共享: provider/model/project/permission/mcp/skills       │
│  设备绑定: deviceId, currentDeviceId                          │
│  软删除: deleted + deletedTime                                │
│  DB表: employees (uuid TEXT PRIMARY KEY)                      │
├─────────────────────────────────────────────────────────────┤
│  Session (AiEmployeeSessionEntity)                           │
│  PK: employeeId (1:1 对应 Employee)                          │
│  设备隔离: config[deviceId] → DeviceSessionConfig             │
│  软删除: deleted + deleteTime                                 │
│  复活机制: updateTime > deleteTime → 自动复活                  │
│  DB表: sessions (employee_id TEXT PRIMARY KEY)                │
├─────────────────────────────────────────────────────────────┤
│  DeviceSessionConfig                                         │
│  存储于: session.config[deviceId]                             │
│  字段: providerConfig, systemPromptOverride, contextData,    │
│        totalInputTokens, totalOutputTokens, totalMessageCount │
│  注意: projectUuid 已废弃，迁移到 Employee 实体               │
└─────────────────────────────────────────────────────────────┘
```

### 1.2 DeviceClient 子模块架构

```
DeviceClient (单例, 按 deviceId 隔离)
├── AppContext          依赖注入容器, 持有所有子模块引用
├── Service 层
│   ├── EmployeeManager          Employee CRUD + 事件通知
│   ├── SessionManager           Session CRUD + 设备配置管理
│   ├── SkillManager             Skill CRUD + 启用/禁用
│   ├── EmployeeConfigService    综合配置(provider/permission/mcp/project)
│   └── MessageStoreService      消息存储与检索
├── Device 实现层
│   ├── DataSyncManager          跨设备数据同步(防抖)
│   ├── DeviceAgentManager       Agent 生命周期(Local/Remote Proxy)
│   ├── DeviceRpcHandler         RPC 方法注册(~60+ 个)
│   ├── DeviceConnectionManager  TCP/MQTT 连接管理
│   ├── DeviceMessageHandler     消息处理与分发
│   ├── DeviceNotificationManager 未读消息通知管理
│   ├── DeviceRegistry           在线设备注册表
│   ├── EmployeeOnlineTracker    Employee 在线状态追踪
│   ├── DeviceConfigManager      设备配置持久化
│   └── DeviceStateHolder        状态中心(事件流聚合)
└── Persistence 层
    ├── DatabaseManager          SQLite 数据库管理
    ├── EmployeeStore            employees 表 CRUD
    ├── SessionStore             sessions 表 CRUD
    ├── SkillStore               skills 表 CRUD
    ├── MessageStore             messages 表 CRUD
    └── Migrations v1→v13        数据库迁移
```

### 1.3 RPC 方法分类 (DeviceRpcHandler)

| 分类 | 方法数 | 方法名 | 说明 |
|------|--------|--------|------|
| **消息操作** | 12+ | sendMessage, getSessionMessages*, getUnreceived, markAsRead*, getMaxSeq, getMinSeq, getClearSeq, getSessionSummary, revokeMessage | 消息收发、已读未读、LSN增量 |
| **Agent 控制** | 4 | interrupt, getOrCreateAgent, ping, getState, getCallingToolIds | Agent 生命周期与状态 |
| **Provider/Model** | 2 | setProvider, getProvider | AI 模型配置 |
| **Project** | 2 | setProject, getProjectUuid | 项目绑定 |
| **Skills** | 2 | setSkills, getSkills | 技能配置 |
| **MCP** | 2 | setMcpConfigs, getMcpConfigs | MCP 服务器配置 |
| **Permission** | 4 | getPendingPermission, respondPermission, getPendingConfirm, respondConfirm | 权限与确认管理 |
| **Context** | 3 | setContext, getContext, clearContext | 上下文管理 |
| **Todo/Topic** | 12 | getCurrentTopics, getPendingTopics, getAllTopics, getCompletedTopics, getTodoStats, updateTopicContent, deleteTopic, updateTopicStatus, reorderTopics, clearCompletedTopics, getTaskItemsByTopic, updateTaskItemStatus, updateTaskItemContent, deleteTaskItem, reorderTaskItems | Todo 全套 CRUD |
| **Spec** | 8 | getActiveSpecs, getCompletedSpecs, getSpecStats, updateSpecStatus, updateSpecContent, deleteSpec, clearCompletedSpecs, reorderSpecs | Spec 全套 CRUD |
| **文件操作** | 6 | checkPathExists, listDirectory, getFileInfo, createDirectory, deleteFile, renameFile | 文件系统操作 |
| **文件追踪** | 3 | getFileOperations, getFileOperationsByMessage, clearFileOperations | 文件操作记录 |
| **数据同步** | 3 | syncEmployees, syncSessions, syncMessages | 跨设备数据同步 |
| **Host 方法** | 8 | getEmployees, getEmployee, getSessions, getSkills, getSessionSummaries, getOnlineDevices, updateDeviceInfo | Host 端查询 |

### 1.4 数据同步机制

```
设备A                              设备B
  │                                  │
  │  broadcastEmployeeToAllDevices   │
  │ ──────────────────────────────> │
  │  methodSyncEmployees            │
  │  { employees: [...] }           │
  │                                  │  _mergeAndSaveEmployee()
  │                                  │  ├── updateTime 比较 → 数据合并
  │                                  │  ├── deleteTime 比较 → 删除合并
  │                                  │  └── permission 热更新
  │                                  │
  │  broadcastSessionToAllDevices   │
  │ ──────────────────────────────> │
  │  methodSyncSessions             │
  │  { sessions: [...] }            │
  │                                  │  _mergeAndSaveSession()
  │                                  │  ├── updateTime 比较 → 数据合并
  │                                  │  └── deleteTime 比较 → 删除合并
```

**合并规则**：
- `updateTime` 较新者覆盖数据
- `deleteTime` 取较晚者，决定 `deleted` 状态
- 本地不存在 + 远程已删除 → 不保存（避免数据污染）
- 已删除数据不复活（deleted=1 的数据不会覆盖本地正常数据）

---

## 二、现有测试覆盖情况

| 测试文件 | 大小 | 覆盖范围 | 状态 |
|----------|------|----------|------|
| `employee_crud_sync_test.dart` | 47KB | EmployeeStore CRUD + EmployeeManager + 同步合并 + 序列化 | ✅ 完善 |
| `session_deletion_sync_test.dart` | 12KB | Session 软删除同步、deleteTime 合并、不复活 | ✅ 完善 |
| `todo_store_test.dart` | 22KB | Todo Topic/TaskItem 存储 | ✅ 完善 |
| `permission_test.dart` | 7KB | 权限规则测试 | ✅ 完善 |
| `notification_hub_test.dart` | 14KB | 通知中心测试 | ✅ 完善 |
| `session_summary_store_test.dart` | 15KB | Session 摘要存储 | ✅ 完善 |
| `agent_basic_test.dart` | 10KB | Agent 基础测试 | ✅ 已有 |
| `agent_event_test.dart` | 27KB | Agent 事件测试 | ✅ 已有 |
| `cached_proxy_toolcall_test.dart` | 11KB | CachedProxy 工具调用测试 | ✅ 已有 |
| `event_broadcast_test.dart` | 28KB | 事件广播测试 | ✅ 已有 |
| `sub_agent_executor_test.dart` | 15KB | 子 Agent 执行器 | ✅ 已有 |
| `command_session_pool_test.dart` | 21KB | 命令会话池 | ✅ 已有 |

**缺口分析**：

| 缺口 | 优先级 | 说明 |
|------|--------|------|
| ❌ Session Entity 序列化测试 | P0 | 特别是 DeviceSessionConfig 嵌套、fromLegacyMap 兼容 |
| ❌ SkillManager / SkillStore 测试 | P1 | 技能 CRUD + 事件通知 |
| ❌ EmployeeConfigService 综合测试 | P0 | provider/permission/mcp/project 联动 |
| ❌ DeviceRpcHandler 功能测试 | P1 | 各模块 RPC 方法单元测试 |
| ❌ EmployeeOnlineTracker 测试 | P1 | 在线状态追踪 |
| ❌ DeviceAgentManager 生命周期测试 | P1 | Local/Remote Agent 创建/销毁/切换 |
| ❌ 多设备集成测试 | P2 | 端到端同步链路 |

---

## 三、阶段性任务规划

### 阶段一：数据模型与持久化（P0 - 基础）

> **目标**：确保所有 Entity 和 Store 层的数据读写正确，是后续所有测试的基础。

| 编号 | 任务 | 优先级 | 涉及文件 | 详细说明 |
|------|------|--------|----------|----------|
| T1.1 | Employee Entity 序列化往返 | P0 | `employee_entity.dart` | `toMap()` → `fromMap()` 所有字段零丢失；`copyWith()` 各字段覆盖；特殊字段：`deletedTime` null/非null、`mcpConfig` JSON、`getMcpConfigs()`/`setMcpConfigs()` |
| T1.2 | Session Entity 序列化往返 | P0 | `session_entity.dart` | `toMap()` → `fromMap()` 含 `config[deviceId]` 嵌套结构；`fromLegacyMap()` 旧格式兼容（顶层 providerConfig/projectUuid 迁移到 config['']）；`isEffectivelyDeleted()` 边界条件；`getOrCreateConfig()` 幂等性 |
| T1.3 | DeviceSessionConfig 序列化 | P0 | `session_entity.dart` | `fromMap()`/`toMap()` 往返；`updateTime` 既支持 `DateTime` 也支持 `int`（毫秒时间戳）；`copyWith()` 各字段 |
| T1.4 | EmployeeStore CRUD | P0 | `employee_store.dart` | `save`/`find`/`findAll`/`delete`/`count`/`exists`/`findIncludingDeleted`；软删除场景：`delete` 后 `find` 返回 null 但 `findIncludingDeleted` 可查到；多 deviceId 隔离：`findAll(deviceId)` 只返回该设备的员工 |
| T1.5 | SessionStore CRUD | P0 | `session_store.dart` | `save`/`find`/`getOrCreate`/`delete`/`hardDelete`；`getOrCreate` 幂等性：多次调用返回同一 session；`config` 字段 JSON 序列化（含嵌套 `Map<String, DeviceSessionConfig>`）；软删除后 `find` 返回 null |
| T1.6 | SkillStore CRUD | P1 | `skill_store.dart` | `saveWithDeviceId`/`findByEmployeeWithDeviceId`/`find`/`delete`；按 `deviceId + employeeId` 联合查询 |
| T1.7 | 数据库迁移兼容性 | P1 | `migrations/` | v1→v13 渐进迁移，特别是 v13（session config 重构：顶层字段迁移到 config JSON） |

#### 验收标准

- [ ] `AiEmployeeEntity.toMap()` → `AiEmployeeEntity.fromMap()` 往返序列化零丢失
- [ ] `AiEmployeeSessionEntity` 的 `config[deviceId]` 嵌套结构正确序列化/反序列化
- [ ] `fromLegacyMap` 能正确解析旧格式数据（向后兼容）
- [ ] `DeviceSessionConfig.fromMap` 同时支持 `DateTime` 和 `int` 类型的时间字段
- [ ] EmployeeStore 的 `save`/`find`/`delete`/`count` 操作正确
- [ ] 软删除记录可通过 `findIncludingDeleted` 查到，普通 `find` 过滤掉
- [ ] SessionStore 的 `getOrCreate` 幂等性验证
- [ ] 所有测试使用独立临时数据库（`Directory.systemTemp.path` + UUID），测试间无状态泄漏

---

### 阶段二：Service 业务逻辑（P0 - 核心）

> **目标**：确保 Service 层的 CRUD 操作、事件通知、配置联动正确。

| 编号 | 任务 | 优先级 | 涉及文件 | 详细说明 |
|------|------|--------|----------|----------|
| T2.1 | EmployeeManager CRUD + 事件 | P0 | `employee_manager.dart` | `createEmployee` → `EmployeeChangeEvent(created)`；`updateEmployee` → `EmployeeChangeEvent(updated)` 且 `updateTime` 自动更新；`deleteEmployee` → `EmployeeChangeEvent(deleted)`；`saveEmployee` 区分 created/updated；`getEmployees(allDevices: true)` 跨设备查询；`getEmployeeIncludingDeleted` 同步场景 |
| T2.2 | SessionManager 设备配置 | P0 | `session_manager.dart` | `updateDeviceConfig` 正确更新指定 deviceId 的 providerConfig/systemPromptOverride，不影响其他设备配置；`updateDeviceStats` 累加 inputTokens/outputTokens/messageCount；`getOrCreateSession` 自动复活（deleted=0） |
| T2.3 | SessionManager 软删除/复活 | P0 | `session_manager.dart` | `deleteSession` 软删除（deleted=1, deleteTime=now）；`isEffectivelyDeleted()` 逻辑：deleted=1 且 deleteTime >= updateTime → 已删除；updateTime > deleteTime → 复活 |
| T2.4 | SkillManager CRUD + 事件 | P1 | `skill_manager.dart` | `createSkill`/`updateSkill`/`deleteSkill` + `SkillChangeEvent`；`setSkillEnabled` 启用/禁用；按 `deviceId` 隔离 |
| T2.5 | EmployeeConfigService 综合配置 | P0 | `employee_config_service.dart` | `getEmployeeConfig` 聚合 employee + skills + permission + mcp；`updateEmployeeBasicInfo` 联动 Employee 更新 + `EmployeeConfigChangeEvent(basicInfo)`；`updateEmployeeProvider` 联动 Employee 更新 + `EmployeeConfigChangeEvent(provider)` |
| T2.6 | EmployeeConfigService MCP 配置 | P0 | `employee_config_service.dart` | `updateEmployeeMcpConfigs` 序列化/反序列化 `McpServerConfig`；`addMcpServerConfig` 重复名称检测 → `ArgumentError`；`removeMcpServerConfig`/`updateMcpServerConfig`；`setMcpEnabled` 开关联动 |
| T2.7 | EmployeeConfigService 权限配置 | P0 | `employee_config_service.dart` | `updateEmployeePermission` JSON 序列化；`EmployeeConfigChangeEvent(permission)` 触发 |

#### 验收标准

- [ ] EmployeeManager 的 CRUD 操作正确触发对应类型的 `EmployeeChangeEvent`
- [ ] `updateEmployee` 自动设置 `updateTime = DateTime.now()`
- [ ] SessionManager 的 `updateDeviceConfig` 只更新指定 deviceId 的配置
- [ ] `isEffectivelyDeleted()` 在各种边界条件下返回正确结果
- [ ] EmployeeConfigService 的 provider 更新同时持久化到 Employee
- [ ] MCP 配置的 add/remove/update 操作正确，重复名称检测生效
- [ ] 所有 `EmployeeConfigChangeEvent` 正确触发且携带正确的 `type` 和 `employeeId`

---

### 阶段三：数据同步逻辑（P0 - 关键）

> **目标**：确保跨设备数据同步的合并逻辑正确，是系统可靠性的核心。

| 编号 | 任务 | 优先级 | 涉及文件 | 详细说明 |
|------|------|--------|----------|----------|
| T3.1 | Employee 同步合并 | P0 | `data_sync_manager.dart` | `_mergeAndSaveEmployee`：remote.updateTime > existing.updateTime → 更新数据；remote.updateTime <= existing.updateTime → 保留本地数据 |
| T3.2 | Session 同步合并 | P0 | `data_sync_manager.dart` | `_mergeAndSaveSession`：同上逻辑，验证 config[deviceId] 在合并时正确保留 |
| T3.3 | 双向删除冲突 | P0 | `data_sync_manager.dart` | 两端同时软删除：localDT 和 remoteDT 均非空 → 取较晚者作为 mergedDeleteTime，`deleted` 状态跟随较晚者 |
| T3.4 | 已删除数据不复活 | P0 | `data_sync_manager.dart` | 远程 deleted=1 的数据不会将本地正常数据覆盖为已删除（仅当 mergedDeleteTime 指向远程时才更新 deleted） |
| T3.5 | 本地不存在 + 远程已删除 | P0 | `data_sync_manager.dart` | 本地不存在该 employee/session → 远程已删除的不保存（避免数据污染） |
| T3.6 | Employee 删除传播 | P1 | `data_sync_manager.dart` | `deleteEmployeeWithSync` → 软删除 + `_syncEmployeeDeleteToDevices` 广播 |
| T3.7 | Session 删除传播 | P1 | `data_sync_manager.dart` | `deleteSessionWithSync` → 软删除 + 销毁 AgentProxy + `_syncSessionDeleteToDevices` 广播 |
| T3.8 | RPC Handler 同步方法 | P1 | `device_rpc_handler.dart` | `methodSyncEmployees`：权限配置热更新 `reloadPermissionConfig`；`methodSyncSessions`：`_mergeDeleteTime` 合并；`methodSyncMessages`：按 deviceId 分组写入 |
| T3.9 | `_mergeDeleteTime` 边界 | P0 | `data_sync_manager.dart` | 四种组合：(null, null)→(null,0)；(null, remote)→(remote,remoteD)；(local, null)→(local,localD)；(local, remote)→较晚者 |

#### 验收标准

- [ ] `_mergeAndSaveEmployee`：remote.updateTime > existing.updateTime 时更新数据
- [ ] `_mergeAndSaveSession`：同上逻辑，config 嵌套结构不丢失
- [ ] 双向删除：localDT 和 remoteDT 均非空时，取较晚者作为 mergedDeleteTime
- [ ] 已删除数据不复活：远程 deleted=1 的数据不会将本地正常数据覆盖为已删除
- [ ] 本地不存在 + 远程已删除 → 不保存
- [ ] 删除传播：本端删除后，通过广播通知其他设备
- [ ] `_mergeDeleteTime` 四种组合均返回正确结果

---

### 阶段四：RPC 功能验证（P1 - 功能链路）

> **目标**：确保 DeviceRpcHandler 注册的各 RPC 方法正确调用底层 Service/Agent。

#### 4.1 Project 配置 RPC

| 编号 | 测试用例 | 说明 |
|------|----------|------|
| T4.1.1 | `setProject` 更新 Employee | 验证 `Employee.projectUuid/projectName/projectContext/workPath` 更新 |
| T4.1.2 | `setProject` 广播同步 | 验证调用 `broadcastEmployeeToAllDevices` |
| T4.1.3 | `getProjectUuid` 返回正确值 | 从 Agent 获取当前 projectUuid |
| T4.1.4 | `setProject` null 值清除 | projectData=null 时清除项目绑定 |

#### 4.2 Provider/Model 配置 RPC

| 编号 | 测试用例 | 说明 |
|------|----------|------|
| T4.2.1 | `setProvider` 更新 Agent | 验证 `ProviderConfig` 正确传递给 Agent |
| T4.2.2 | `setProvider` 同步 Employee | 验证 `Employee.provider/model/apiKey/apiBaseUrl` 同步更新 |
| T4.2.3 | `setProvider` 广播同步 | 验证调用 `broadcastEmployeeToAllDevices` |
| T4.2.4 | `getProvider` 返回当前配置 | 从 Agent 获取 providerConfig |

#### 4.3 Skills 配置 RPC

| 编号 | 测试用例 | 说明 |
|------|----------|------|
| T4.3.1 | `setSkills` 写入 Agent | 验证 Agent 收到 skills 列表 |
| T4.3.2 | `getSkills` 从 Store 读取 | 验证 `SkillStore.findByEmployeeWithDeviceId` 正确返回 |
| T4.3.3 | Skills 按 deviceId 隔离 | 不同设备的 skills 互不干扰 |

#### 4.4 MCP 配置 RPC

| 编号 | 测试用例 | 说明 |
|------|----------|------|
| T4.4.1 | `setMcpConfigs` 写入 Agent | 验证 MCP 配置正确传递 |
| T4.4.2 | `getMcpConfigs` 返回配置 | 从 Agent 获取 mcpConfigs |
| T4.4.3 | MCP 配置序列化 | `McpServerConfig` 的 JSON 序列化/反序列化 |

#### 4.5 Permission 管理 RPC

| 编号 | 测试用例 | 说明 |
|------|----------|------|
| T4.5.1 | `getPendingPermission` | Agent 有/无待处理权限请求 |
| T4.5.2 | `respondPermission` | decision(allow/deny) + scope(once/session/always) + customPattern |
| T4.5.3 | `getPendingConfirm` / `respondConfirm` | 确认请求的获取和响应 |

#### 4.6 Context 管理 RPC

| 编号 | 测试用例 | 说明 |
|------|----------|------|
| T4.6.1 | `setContext` / `getContext` | 上下文数据读写 |
| T4.6.2 | `clearContext` | 清除上下文 |

#### 4.7 Todo/Topic RPC

| 编号 | 测试用例 | 说明 |
|------|----------|------|
| T4.7.1 | Topic 查询 | getCurrentTopics, getPendingTopics, getAllTopics, getCompletedTopics |
| T4.7.2 | Topic 写操作 | updateTopicContent, deleteTopic, updateTopicStatus, reorderTopics, clearCompletedTopics |
| T4.7.3 | TaskItem 操作 | getTaskItemsByTopic, updateTaskItemStatus, updateTaskItemContent, deleteTaskItem, reorderTaskItems |
| T4.7.4 | TodoStats | getTodoStats 返回正确的统计 |

#### 4.8 Spec RPC

| 编号 | 测试用例 | 说明 |
|------|----------|------|
| T4.8.1 | Spec 查询 | getActiveSpecs, getCompletedSpecs, getSpecStats |
| T4.8.2 | Spec 写操作 | updateSpecStatus, updateSpecContent, deleteSpec, clearCompletedSpecs, reorderSpecs |

#### 4.9 消息同步 RPC

| 编号 | 测试用例 | 说明 |
|------|----------|------|
| T4.9.1 | `syncMessages` 按 deviceId 分组 | 验证消息按 `msg.deviceId` 分组写入 |
| T4.9.2 | `getSessionSummary` | 返回指定 employeeId 的摘要 |

#### 验收标准

- [ ] `setProject` 正确更新 `Employee.projectUuid` 并持久化 + 广播
- [ ] `setProvider` 更新 Employee 的 provider/model/apiKey/apiBaseUrl，且广播
- [ ] Skills RPC 的 `setSkills`/`getSkills` 正确操作 SkillStore
- [ ] MCP RPC 的 `setMcpConfigs`/`getMcpConfigs` 正确序列化/反序列化
- [ ] Permission RPC 的 scope 和 customPattern 正确传递
- [ ] Todo/Topic/Spec 全套 CRUD 操作正常
- [ ] `syncMessages` 按 deviceId 正确分组存储消息

---

### 阶段五：Agent 生命周期（P1）

> **目标**：确保 Agent 创建、切换、销毁的正确性。

| 编号 | 任务 | 优先级 | 涉及文件 | 详细说明 |
|------|------|--------|----------|----------|
| T5.1 | Local Agent 创建 | P1 | `device_agent_manager.dart` | `_getOrCreateLocalAgent`：读取 Employee + Session.config[deviceId] 配置初始化 Agent；设置 Provider（优先 session config，fallback 到 Employee 字段）；设置 SystemPrompt；设置 Project；注入权限配置 |
| T5.2 | Remote Proxy 创建/切换 | P1 | `device_agent_manager.dart` | key 格式 `targetDeviceId:employeeId`；缓存命中/未命中；后台同步 `_backgroundSyncRemoteProxy` |
| T5.3 | Agent Proxy 缓存一致性 | P2 | `cached_agent_proxy.dart` | 本地/远程代理切换；缓存失效；initialize + warmup |
| T5.4 | `ensureLocalAgentForRpc` | P1 | `device_agent_manager.dart` | Agent 不存在时自动创建；远程 Employee 获取 `_fetchEmployeeFromRemote`；fallback 创建默认 Employee |
| T5.5 | `destroyAgentProxy` | P1 | `device_agent_manager.dart` | 清理本地代理 + Agent 实例 + 事件订阅；清理远程代理（按 targetDeviceId 或全部）；`keepLocalAgent=true` 场景 |
| T5.6 | Employee 在线状态 | P1 | `employee_online_tracker.dart` | `refreshEmployeeOnlineStates`；`markDeviceEmployeesOffline` |

#### 验收标准

- [ ] Local Agent 创建时正确读取 Employee + Session.config[deviceId] 配置
- [ ] Provider 设置优先级：session.config[deviceId].providerConfig > Employee.provider/model/apiKey
- [ ] Remote Proxy 的 key 格式为 `targetDeviceId:employeeId`
- [ ] `ensureLocalAgentForRpc` 在 Agent 不存在时自动创建
- [ ] `destroyAgentProxy` 正确清理所有相关资源
- [ ] Employee 在线状态根据 `currentDeviceId` 和设备在线列表正确判断

---

### 阶段六：集成与端到端（P2）

> **目标**：验证完整链路的正确性。

| 编号 | 任务 | 优先级 | 涉及文件 | 详细说明 |
|------|------|--------|----------|----------|
| T6.1 | 多设备 Employee 同步 E2E | P2 | 全链路 | 设备A创建Employee → 同步到设备B → 设备B更新 → 同步回设备A |
| T6.2 | 多设备 Session 同步 E2E | P2 | 全链路 | 设备A更新Session.config['devA'] → 同步到设备B → 设备B的 config['devB'] 不受影响 |
| T6.3 | 设备上下线事件 | P2 | 全链路 | 设备连接/断开 → Employee 在线状态更新 → AgentProxy 切换 |
| T6.4 | 消息收发与未读状态同步 | P2 | 全链路 | 发送消息 → 同步 → 未读计数更新 → 标记已读 → 广播 |
| T6.5 | 删除冲突场景 | P2 | 全链路 | 设备A删除Employee → 设备B同时更新同一Employee → 冲突解决 |

---

## 四、测试文件规划

### 4.1 需要新增的测试文件

```
test/
├── entity/
│   ├── employee_entity_test.dart          # T1.1 Employee Entity 序列化
│   ├── session_entity_test.dart           # T1.2 Session Entity 序列化
│   └── device_session_config_test.dart    # T1.3 DeviceSessionConfig 序列化
├── store/
│   ├── employee_store_test.dart           # T1.4 EmployeeStore CRUD
│   ├── session_store_test.dart            # T1.5 SessionStore CRUD
│   └── skill_store_test.dart              # T1.6 SkillStore CRUD
├── service/
│   ├── employee_manager_test.dart         # T2.1 EmployeeManager 测试
│   ├── session_manager_test.dart          # T2.2-T2.3 SessionManager 测试
│   ├── skill_manager_test.dart            # T2.4 SkillManager 测试
│   └── employee_config_service_test.dart  # T2.5-T2.7 EmployeeConfigService 测试
├── sync/
│   ├── data_sync_merge_test.dart          # T3.1-T3.5 同步合并逻辑
│   ├── sync_delete_propagation_test.dart  # T3.6-T3.7 删除传播
│   └── rpc_sync_test.dart                 # T3.8 RPC Handler 同步方法
├── rpc/
│   ├── rpc_project_test.dart              # T4.1 Project RPC
│   ├── rpc_provider_test.dart             # T4.2 Provider/Model RPC
│   ├── rpc_skills_test.dart               # T4.3 Skills RPC
│   ├── rpc_mcp_test.dart                  # T4.4 MCP RPC
│   ├── rpc_permission_test.dart           # T4.5 Permission RPC
│   ├── rpc_context_test.dart              # T4.6 Context RPC
│   ├── rpc_todo_test.dart                 # T4.7 Todo/Topic RPC
│   ├── rpc_spec_test.dart                 # T4.8 Spec RPC
│   └── rpc_message_sync_test.dart         # T4.9 消息同步 RPC
├── agent/
│   ├── device_agent_manager_test.dart     # T5.1,T5.2,T5.4,T5.5 Agent 生命周期
│   ├── cached_proxy_test.dart             # T5.3 Proxy 缓存
│   └── employee_online_tracker_test.dart  # T5.6 在线状态
└── integration/
    ├── multi_device_sync_test.dart        # T6.1-T6.2 多设备同步 E2E
    └── device_lifecycle_test.dart         # T6.3-T6.5 设备生命周期 E2E
```

### 4.2 测试基础设施

所有测试遵循现有模式（参考 `employee_crud_sync_test.dart`）：

```dart
// 通用 setUp/tearDown 模式
int _testCounter = 0;

setUp(() async {
  _testCounter++;
  testDbPath = '${Directory.systemTemp.path}/wenzagent_XXX_test_$_testCounter';
  await Directory(testDbPath).create(recursive: true);
  deviceId = 'dev-${const Uuid().v4().substring(0, 8)}';
  await DatabaseManager.getInstance(deviceId).initialize(storagePath: testDbPath);
  // ... 初始化被测对象
});

tearDown(() async {
  // ... 清理被测对象
  await DatabaseManager.getInstance(deviceId).close();
  DatabaseManager.removeInstance(deviceId);
  // ... 清理其他单例
  try { await Directory(testDbPath).delete(recursive: true); } catch (_) {}
});
```

### 4.3 测试运行命令

```bash
# 运行全部测试
dart test

# 运行指定阶段测试
dart test test/entity/ test/store/ test/service/     # 阶段一+二
dart test test/sync/                                  # 阶段三
dart test test/rpc/                                   # 阶段四
dart test test/agent/                                 # 阶段五
dart test test/integration/                           # 阶段六

# 运行已有测试（验证不退化）
dart test test/employee_crud_sync_test.dart test/session_deletion_sync_test.dart

# 运行单个测试文件
dart test test/service/employee_config_service_test.dart
```

---

## 五、风险与注意事项

| 风险项 | 说明 | 缓解措施 |
|--------|------|----------|
| **单例模式测试隔离** | DeviceClient 及子模块均为单例，测试间可能互相影响 | 每个测试使用唯一 `deviceId`（UUID），tearDown 中调用 `removeInstance` |
| **数据库文件泄漏** | 临时数据库未清理导致磁盘占用 | tearDown 中强制删除临时目录 |
| **异步操作时序** | Agent 创建、同步操作为异步，测试需正确等待 | 使用 `async/await`，避免 `sleep` |
| **RPC Mock 复杂度** | RPC 测试需要 Mock `RemoteCallServer` | 优先测试 Handler 逻辑（直接调用方法体），集成测试使用真实 RPC |
| **迁移兼容性** | v13 重构了 Session config 结构 | 确保从旧格式迁移的测试覆盖 `fromLegacyMap` |
| **copyWith null 语义** | `copyWith(field: null)` 在当前实现中会保留原值（`?? this.field`），无法显式置空 | 需要注意 `apiKey`/`projectUuid` 等字段的清除场景 |
| **时间戳精度** | `DateTime.now()` 在快速测试中可能相同，影响 `updateTime` 比较 | 在需要区分时间的测试中使用 `DateTime.now().add(Duration(seconds: 1))` |

---

## 六、执行优先级与时间线

```
Week 1: 阶段一 (T1.1-T1.7)  ── 数据模型与持久化
         ↓
Week 2: 阶段二 (T2.1-T2.7)  ── Service 业务逻辑
         ↓
Week 3: 阶段三 (T3.1-T3.9)  ── 数据同步逻辑
         ↓
Week 4: 阶段四 (T4.1-T4.9)  ── RPC 功能验证
         ↓
Week 5: 阶段五 (T5.1-T5.6)  ── Agent 生命周期
         ↓
Week 6: 阶段六 (T6.1-T6.5)  ── 集成与端到端
```

**关键路径**：阶段一 → 阶段二 → 阶段三（这三个阶段是后续所有测试的基础，必须优先完成且质量最高）

---

## 七、Employee Session 数据流全景

```
┌──────────────────────────────────────────────────────────────────────┐
│                        Employee Session 数据流                        │
│                                                                      │
│  ┌─────────┐    RPC     ┌──────────────┐    Service    ┌──────────┐ │
│  │  Host   │ ────────> │ DeviceRpc    │ ───────────> │ Employee │ │
│  │  App    │ <──────── │ Handler      │ <─────────── │ Manager  │ │
│  │         │    RPC     │              │    Service    │          │ │
│  └─────────┘           │              │              │          │ │
│                        │  60+ RPC     │              └────┬─────┘ │
│  ┌─────────┐    RPC     │  methods     │                   │       │
│  │ Remote  │ ────────> │              │    Service    ┌────┴─────┐ │
│  │ Device  │ <──────── │              │ ───────────> │ Session  │ │
│  │         │           │              │              │ Manager  │ │
│  └─────────┘           └──────┬───────┘              └────┬─────┘ │
│                               │                           │       │
│                        ┌──────┴───────┐           ┌──────┴──────┐ │
│                        │ DataSync     │           │ Skill       │ │
│                        │ Manager      │           │ Manager     │ │
│                        │ (防抖同步)    │           └─────────────┘ │
│                        └──────┬───────┘                           │
│                               │                                   │
│                        ┌──────┴───────┐                           │
│                        │ DeviceAgent  │                           │
│                        │ Manager      │                           │
│                        │ (Local/      │                           │
│                        │  Remote)     │                           │
│                        └──────────────┘                           │
│                                                                      │
│  ┌──────────────────────────────────────────────────────────────┐   │
│  │  Persistence Layer                                            │   │
│  │  ┌──────────┐ ┌──────────┐ ┌──────────┐ ┌──────────┐       │   │
│  │  │ Employee │ │ Session  │ │ Skill    │ │ Message  │       │   │
│  │  │ Store    │ │ Store    │ │ Store    │ │ Store    │       │   │
│  │  └──────────┘ └──────────┘ └──────────┘ └──────────┘       │   │
│  │  ┌──────────┐ ┌──────────┐ ┌──────────┐ ┌──────────┐       │   │
│  │  │ Todo     │ │ Spec     │ │ Summary  │ │ Sync     │       │   │
│  │  │ Store    │ │ Store    │ │ Store    │ │ Watermark│       │   │
│  │  └──────────┘ └──────────┘ └──────────┘ └──────────┘       │   │
│  └──────────────────────────────────────────────────────────────┘   │
└──────────────────────────────────────────────────────────────────────┘
```

---

## 八、RPC 方法与 Employee Session 维度映射

| Employee Session 维度 | RPC 方法 | 数据流向 | 存储位置 |
|----------------------|----------|----------|----------|
| **project** | `setProject`, `getProjectUuid` | RPC → Agent → Employee → DB + 广播 | `Employee.projectUuid/projectName/projectContext/workPath` |
| **model** | `setProvider`, `getProvider` | RPC → Agent → Employee → DB + 广播 | `Employee.provider/model/apiKey/apiBaseUrl` + `Session.config[deviceId].providerConfig` |
| **skills** | `setSkills`, `getSkills` | RPC → Agent (内存) / SkillStore (DB) | `skills` 表 (deviceId + employeeId) |
| **mcp** | `setMcpConfigs`, `getMcpConfigs` | RPC → Agent (内存) | `Employee.mcpConfig` (JSON) |
| **permission** | `getPendingPermission`, `respondPermission` | RPC → Agent (内存) | `Employee.permissionConfig` (JSON) |
| **spec** | `getActiveSpecs`, `updateSpecStatus`, `deleteSpec`, ... | RPC → Agent → SpecStore (DB) | `specs` 表 (employeeId) |
| **todo** | `getCurrentTopics`, `updateTopicContent`, `deleteTopic`, ... | RPC → Agent → TodoStore (DB) | `todo_topics` + `todo_task_items` 表 (employeeId) |
