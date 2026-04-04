import 'package:wenzagent/wenzagent.dart';
import 'package:test/test.dart';

void main() {
  group('LAN Message Tests', () {
    test('LanMessage can be serialized', () {
      final msg = LanMessage(
        id: 'test-id',
        type: LanMessageType.text,
        fromId: 'client-1',
        content: 'Hello',
      );

      final json = msg.toJson();
      expect(json['id'], equals('test-id'));
      expect(json['type'], equals('text'));
      expect(json['content'], equals('Hello'));

      final restored = LanMessage.fromJson(json);
      expect(restored.id, equals('test-id'));
      expect(restored.type, equals(LanMessageType.text));
    });

    test('LanClient can be serialized', () {
      final client = LanClient(
        id: 'client-1',
        name: 'Test Client',
        spaceId: 'space-1',
      );

      final json = client.toJson();
      expect(json['id'], equals('client-1'));
      expect(json['name'], equals('Test Client'));

      final restored = LanClient.fromJson(json);
      expect(restored.id, equals('client-1'));
    });
  });

  group('Agent State Tests', () {
    test('AgentStateSnapshot can be serialized', () {
      final snapshot = AgentStateSnapshot(
        status: AgentStatus.idle,
        queueLength: 0,
      );

      final map = snapshot.toMap();
      expect(map['status'], equals('idle'));

      final restored = AgentStateSnapshot.fromMap(map);
      expect(restored.status, equals(AgentStatus.idle));
    });

    test('AgentStatus can be parsed from string', () {
      expect(AgentStatus.fromString('idle'), equals(AgentStatus.idle));
      expect(AgentStatus.fromString('processing'), equals(AgentStatus.processing));
      expect(AgentStatus.fromString('unknown'), equals(AgentStatus.idle));
    });
  });

  group('RPC Protocol Tests', () {
    test('RpcRequest can be serialized', () {
      final request = RpcRequest(
        requestId: 'req-1',
        method: 'testMethod',
        params: {'key': 'value'},
        fromSpaceId: 'space-1',
        toSpaceId: 'space-2',
      );

      final json = request.toJson();
      expect(json['requestId'], equals('req-1'));
      expect(json['method'], equals('testMethod'));

      final restored = RpcRequest.fromJson(json);
      expect(restored.requestId, equals('req-1'));
    });

    test('RpcResponse success', () {
      final response = RpcResponse.success('req-1', {'result': 'ok'});
      expect(response.success, isTrue);
      expect(response.result?['result'], equals('ok'));
    });

    test('RpcResponse error', () {
      final response = RpcResponse.error('req-1', RpcError(code: 1, message: 'Error'));
      expect(response.success, isFalse);
      expect(response.error?.code, equals(1));
    });
  });
}
