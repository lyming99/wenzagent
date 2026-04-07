/// Host RPC 请求参数实体类
///
/// 为所有Host RPC方法提供类型安全的参数封装

/// 获取员工列表请求
class GetEmployeesRequest {
  final String? keyword;
  final String? status;

  const GetEmployeesRequest({
    this.keyword,
    this.status,
  });

  Map<String, dynamic> toMap() {
    final map = <String, dynamic>{};
    if (keyword != null) map['keyword'] = keyword!;
    if (status != null) map['status'] = status!;
    return map;
  }

  factory GetEmployeesRequest.fromMap(Map<String, dynamic> map) {
    return GetEmployeesRequest(
      keyword: map['keyword'] as String?,
      status: map['status'] as String?,
    );
  }
}

/// 获取单个员工请求
class GetEmployeeRequest {
  final String uuid;

  const GetEmployeeRequest({required this.uuid});

  Map<String, dynamic> toMap() {
    return {'uuid': uuid};
  }

  factory GetEmployeeRequest.fromMap(Map<String, dynamic> map) {
    return GetEmployeeRequest(
      uuid: map['uuid'] as String,
    );
  }
}

/// 获取会话列表请求
class GetSessionsRequest {
  final bool includeArchived;

  const GetSessionsRequest({this.includeArchived = false});

  Map<String, dynamic> toMap() {
    return {'includeArchived': includeArchived};
  }

  factory GetSessionsRequest.fromMap(Map<String, dynamic> map) {
    return GetSessionsRequest(
      includeArchived: map['includeArchived'] as bool? ?? false,
    );
  }
}

/// 获取技能列表请求
class GetSkillsRequest {
  final String employeeId;

  const GetSkillsRequest({required this.employeeId});

  Map<String, dynamic> toMap() {
    return {'employeeId': employeeId};
  }

  factory GetSkillsRequest.fromMap(Map<String, dynamic> map) {
    return GetSkillsRequest(
      employeeId: map['employeeId'] as String,
    );
  }
}

/// 同步员工请求
class SyncEmployeesRequest {
  final List<Map<String, dynamic>> employees;

  const SyncEmployeesRequest({required this.employees});

  Map<String, dynamic> toMap() {
    return {'employees': employees};
  }

  factory SyncEmployeesRequest.fromMap(Map<String, dynamic> map) {
    return SyncEmployeesRequest(
      employees: (map['employees'] as List)
          .map((e) => e as Map<String, dynamic>)
          .toList(),
    );
  }
}

/// 同步会话请求
class SyncSessionsRequest {
  final List<Map<String, dynamic>> sessions;

  const SyncSessionsRequest({required this.sessions});

  Map<String, dynamic> toMap() {
    return {'sessions': sessions};
  }

  factory SyncSessionsRequest.fromMap(Map<String, dynamic> map) {
    return SyncSessionsRequest(
      sessions: (map['sessions'] as List)
          .map((s) => s as Map<String, dynamic>)
          .toList(),
    );
  }
}

/// 同步消息请求
class SyncMessagesRequest {
  final List<Map<String, dynamic>> messages;

  const SyncMessagesRequest({required this.messages});

  Map<String, dynamic> toMap() {
    return {'messages': messages};
  }

  factory SyncMessagesRequest.fromMap(Map<String, dynamic> map) {
    return SyncMessagesRequest(
      messages: (map['messages'] as List)
          .map((m) => m as Map<String, dynamic>)
          .toList(),
    );
  }
}
