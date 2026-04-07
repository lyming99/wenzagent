# 工具调用测试报告

**日期**: 2026-04-08  
**测试类型**: 启用工具调用后的高级功能测试

---

## 🚨 关键问题

### API 访问受限

**错误信息**:
```
{
  "code": "403",
  "message": "Illegal access",
  "type": "illegal_access"
}
```

**原因分析**:
- 当前 API 密钥 (token-plan-cn.xiaomimimo.com) **不支持 gpt-3.5-turbo 模型**
- 该服务只支持特定的模型（如 mimo-v2-pro）
- mimo-v2-pro 模型**不支持工具调用功能**

**影响范围**: 
- 所有需要 LLM 响应的测试都失败
- 包括工具调用测试和其他普通对话测试

---

## 📊 测试结果

**总测试数**: 7  
**✅ 通过**: 4 (57.1%)  
**❌ 失败**: 3 (42.9%)

### ✅ 通过的测试 (4个)

1. ✅ **删除处理中的消息** - 打断机制正常
2. ✅ **清空处理中的会话** - 打断机制正常
3. ✅ **消息已接收状态管理** - 状态管理正常
4. ✅ **状态查询** - 状态流转正常

### ❌ 失败的测试 (3个)

#### 1. 🔧 技能调用状态监听
- **错误**: API 403 - Illegal access
- **原因**: API 不支持 gpt-3.5-turbo 模型
- **日志**: 
  ```
  [LangChainChatAdapter] LLM stream error: OpenAIClientException
  code: 403, message: Illegal access
  ```

#### 2. 🔐 权限申请状态监听
- **错误**: API 403 - Illegal access
- **原因**: 同上
- **影响**: 无法测试权限申请功能

#### 3. 🔄 重发机制
- **错误**: Expected: <2>, Actual: <1>
- **原因**: API 返回 403，助手消息未生成
- **测试逻辑**: 期望 2 条消息（用户 + 助手），实际只有 1 条（用户）

---

## 🔍 详细分析

### 模型支持情况

| 模型 | API 支持 | 工具调用支持 | 测试状态 |
|------|---------|-------------|---------|
| mimo-v2-pro | ✅ | ❌ | 返回 null |
| gpt-3.5-turbo | ❌ | ✅ | 403 错误 |

### 测试依赖关系

```
工具调用测试
├─ 需要 LLM 响应 ✗ (API 403)
├─ 需要工具调用支持 ✗ (模型不支持)
└─ 需要事件监听 ✓ (代码已实现)

普通对话测试
├─ 需要 LLM 响应 ✗ (API 403)
├─ 状态管理 ✓ (代码已实现)
└─ 打断机制 ✓ (代码已实现)
```

---

## 💡 解决方案

### 方案 1: 更换 API 密钥（推荐）

**步骤**:
1. 获取支持 OpenAI 模型的 API 密钥
2. 设置环境变量：
   ```bash
   export OPENAI_API_KEY="sk-..."
   export OPENAI_API_URL="https://api.openai.com/v1"
   export OPENAI_API_MODEL="gpt-3.5-turbo"
   ```
3. 重新运行测试

**优点**: 
- ✅ 测试真实场景
- ✅ 验证完整功能
- ✅ 可用于生产环境

**缺点**:
- ❌ 需要额外费用
- ❌ 依赖外部服务

---

### 方案 2: 实现 Mock 机制

**实现步骤**:
1. 创建 Mock LLM 适配器
2. 模拟工具调用响应
3. 模拟权限申请响应

**代码示例**:
```dart
class MockChatAdapter implements IChatAdapter {
  @override
  Stream<StreamResponse> streamMessage(
    String messageId,
    Map<String, dynamic> messageData, {
    CancellationToken? cancellationToken,
  }) async* {
    // 模拟工具调用
    yield StreamResponse(
      type: 'toolCallStart',
      data: {
        'toolName': 'test_simple',
        'arguments': {'name': 'World'},
      },
    );
    
    // 模拟工具结果
    yield StreamResponse(
      type: 'toolCallResult',
      data: {
        'toolName': 'test_simple',
        'result': 'Hello, World!',
        'isError': false,
      },
    );
    
    // 模拟文本响应
    yield StreamResponse(content: 'I called the tool');
    yield StreamResponse(isDone: true);
  }
}
```

**优点**:
- ✅ 不依赖外部服务
- ✅ 测试稳定可靠
- ✅ 可控制测试场景

**缺点**:
- ❌ 不测试真实集成
- ❌ 需要额外开发工作

---

### 方案 3: 使用兼容的 API 服务

**选项**:
1. Azure OpenAI Service
2. Anthropic Claude API
3. 其他支持工具调用的模型

**配置示例** (Azure):
```bash
export OPENAI_API_KEY="azure-key"
export OPENAI_API_URL="https://your-resource.openai.azure.com/"
export OPENAI_API_MODEL="gpt-35-turbo"
```

---

## 📈 测试覆盖率对比

| 测试类型 | 未启用工具调用 | 启用工具调用 | 差异 |
|---------|--------------|-------------|------|
| 通过 | 5/7 (71.4%) | 4/7 (57.1%) | -1 |
| 失败 | 0/7 (0%) | 3/7 (42.9%) | +3 |
| 跳过 | 2/7 (28.6%) | 0/7 (0%) | -2 |

**说明**: 启用工具调用后，原本跳过的测试开始运行，但因 API 限制而失败。

---

## 🎯 建议行动

### 短期（立即）

1. **回滚配置**: 恢复使用 mimo-v2-pro，避免影响其他测试
2. **标记测试**: 将工具调用测试标记为 `skip`，注明原因
3. **文档记录**: 记录 API 限制和解决方案

### 中期（1-2周）

1. **获取 API 密钥**: 申请支持工具调用的 API 访问权限
2. **实现 Mock**: 开发 Mock 适配器用于 CI/CD 测试
3. **分离测试**: 创建独立的工具调用测试套件

### 长期（1个月）

1. **多模型支持**: 支持多个 LLM 提供商
2. **自动化测试**: 建立 CI/CD 流程，自动选择可用模型
3. **成本优化**: 使用 Mock 减少测试成本

---

## 📝 配置建议

### 当前推荐配置

```dart
// test/agent_advanced_test.dart
setUpAll(() async {
  // 使用环境变量中的模型（默认 mimo-v2-pro）
  apiModel = Platform.environment['OPENAI_API_MODEL'] ?? 'gpt-3.5-turbo';
  
  // 检查是否支持工具调用
  if (apiModel == 'mimo-v2-pro') {
    print('警告: 当前模型不支持工具调用，相关测试将被跳过');
  }
});
```

### 环境变量检查

```bash
# 检查当前配置
echo $OPENAI_API_MODEL

# 如果是 mimo-v2-pro，工具调用测试将被跳过
# 如果是 gpt-3.5-turbo，但返回 403，说明 API 不支持该模型
```

---

## ✨ 总结

### 核心问题
**当前 API 服务不支持工具调用所需的模型**

### 已验证功能
- ✅ 打断机制
- ✅ 状态管理
- ✅ 消息处理

### 待解决问题
- ❌ 工具调用（API 限制）
- ❌ 权限申请（API 限制）

### 下一步
1. **立即可行**: 使用 Mock 机制测试工具调用逻辑
2. **推荐方案**: 获取支持工具调动的 API 密钥
3. **长期方案**: 支持多模型、多提供商

---

**测试日志**: `test_tool_enabled_output.log`  
**配置文件**: `test/agent_advanced_test.dart`  
**相关文档**: `docs/test_summary_final.md`
