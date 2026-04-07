# Agent 功能测试 - 快速开始

## 一、环境准备

### 1. 设置环境变量

**Windows (PowerShell):**
```powershell
$env:OPENAI_API_KEY="your-api-key-here"
```

**Linux / macOS:**
```bash
export OPENAI_API_KEY="your-api-key-here"
```

## 二、运行测试

### 方式 1：运行基础测试（推荐新手）

```bash
dart test test/agent_basic_test.dart --reporter=expanded
```

**测试内容**:
- ✅ 发送消息并收到回复
- ✅ 消息ID一致性
- ✅ 消息不重复
- ✅ 状态监听
- ✅ 删除消息
- ✅ 清空消息

**预计时间**: 2-3 分钟

### 方式 2：运行完整测试

```bash
dart test test/agent_functional_test.dart --reporter=expanded
```

**测试内容**: 所有 15 个功能点

**预计时间**: 10-15 分钟

### 方式 3：使用测试脚本

```bash
dart run_test.dart
```

## 三、查看结果

测试会输出详细的执行过程和结果：

```
✅ 发送消息并收到回复
✅ 消息ID一致性
✅ 消息不重复
...
```

## 四、测试清单

| # | 功能点 | 状态 |
|---|--------|------|
| 1 | 发送消息，远程端收到回复 | ✅ |
| 2 | 思考中状态监听 | ✅ |
| 3 | 技能调用状态监听 | ✅ |
| 4 | 权限申请状态监听 | ✅ |
| 5 | 回复中状态监听 | ✅ |
| 6 | 删除消息功能 | ✅ |
| 7 | 清空消息功能 | ✅ |
| 8 | 会话状态查询 | ✅ |
| 9 | 客户端消息不重复原则 | ✅ |
| 10 | 消息已接收状态 | ✅ |
| 11 | 消息状态更新后，已接收状态移除 | ✅ |
| 12 | 发送失败重发 | ✅ |
| 13 | 消息ID不被修改 | ✅ |
| 14 | 打断机制 | ✅ |
| 15 | 权限申请状态打断 | ✅ |

## 五、详细文档

- [完整测试指南](docs/agent_test_guide.md)
- [测试清单](docs/test_checklist.md)
- [API文档](docs/)

## 六、常见问题

### Q: 测试失败怎么办？

检查：
1. ✅ 环境变量是否设置
2. ✅ API Key 是否有效
3. ✅ 网络是否正常
4. ✅ API 配额是否充足

### Q: 如何只测试某个功能？

```bash
dart test test/agent_basic_test.dart --name="发送消息"
```

## 七、项目结构

```
wenzagent/
├── test/
│   ├── agent_basic_test.dart          # 基础功能测试
│   ├── agent_functional_test.dart     # 完整功能测试
│   └── ...
├── docs/
│   ├── agent_test_guide.md            # 测试指南
│   └── test_checklist.md              # 测试清单
├── run_test.dart                       # 测试脚本
└── README.md                           # 项目说明
```

---

**开始测试吧！** 🚀
