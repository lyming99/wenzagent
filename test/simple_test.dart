import 'package:test/test.dart';
import 'package:wenzagent/src/agent/entity/entity.dart';
import 'package:wenzagent/src/agent/adapter/provider_config.dart';

void main() {
  test('Simple test - ProviderConfig creation', () {
    final config = ProviderConfig(
      provider: LLMProvider.openai,
      model: 'gpt-3.5-turbo',
      apiKey: 'test-key',
    );
    
    expect(config.provider, equals(LLMProvider.openai));
    expect(config.model, equals('gpt-3.5-turbo'));
    expect(config.apiKey, equals('test-key'));
    
    print('✓ ProviderConfig created successfully');
  });
  
  test('Simple test - MessageInput with UUID', () {
    final messageId = 'test-message-id';
    final input = MessageInput(
      content: 'Test message',
      id: messageId,
    );
    
    expect(input.id, equals(messageId));
    expect(input.content, equals('Test message'));
    
    print('✓ MessageInput created with ID: $messageId');
  });
  
  test('Simple test - AgentMessage creation', () {
    final message = AgentMessage(
      id: 'msg-123',
      role: 'user',
      type: 'text',
      content: 'Hello',
      createdAt: DateTime.now(),
    );
    
    expect(message.id, equals('msg-123'));
    expect(message.role, equals('user'));
    expect(message.content, equals('Hello'));
    
    print('✓ AgentMessage created successfully');
  });
}
