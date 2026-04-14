// RPC 请求参数实体类 - Host/文件操作相关请求

/// 检查路径是否存在请求
class CheckPathExistsRequest {
  final String employeeId;
  final String path;

  const CheckPathExistsRequest({required this.employeeId, required this.path});

  Map<String, dynamic> toMap() {
    return {'employeeId': employeeId, 'path': path};
  }

  factory CheckPathExistsRequest.fromMap(Map<String, dynamic> map) {
    return CheckPathExistsRequest(
      employeeId: map['employeeId'] as String,
      path: map['path'] as String,
    );
  }
}

/// 列出目录内容请求
class ListDirectoryRequest {
  final String employeeId;
  final String path;

  const ListDirectoryRequest({required this.employeeId, required this.path});

  Map<String, dynamic> toMap() {
    return {'employeeId': employeeId, 'path': path};
  }

  factory ListDirectoryRequest.fromMap(Map<String, dynamic> map) {
    return ListDirectoryRequest(
      employeeId: map['employeeId'] as String,
      path: map['path'] as String,
    );
  }
}

/// 获取文件/目录信息请求
class GetFileInfoRequest {
  final String employeeId;
  final String path;

  const GetFileInfoRequest({required this.employeeId, required this.path});

  Map<String, dynamic> toMap() {
    return {'employeeId': employeeId, 'path': path};
  }

  factory GetFileInfoRequest.fromMap(Map<String, dynamic> map) {
    return GetFileInfoRequest(
      employeeId: map['employeeId'] as String,
      path: map['path'] as String,
    );
  }
}

/// 创建目录请求
class CreateDirectoryRequest {
  final String employeeId;
  final String path;

  const CreateDirectoryRequest({required this.employeeId, required this.path});

  Map<String, dynamic> toMap() {
    return {'employeeId': employeeId, 'path': path};
  }

  factory CreateDirectoryRequest.fromMap(Map<String, dynamic> map) {
    return CreateDirectoryRequest(
      employeeId: map['employeeId'] as String,
      path: map['path'] as String,
    );
  }
}

/// 删除文件/目录请求
class DeleteFileRequest {
  final String employeeId;
  final String path;

  const DeleteFileRequest({required this.employeeId, required this.path});

  Map<String, dynamic> toMap() {
    return {'employeeId': employeeId, 'path': path};
  }

  factory DeleteFileRequest.fromMap(Map<String, dynamic> map) {
    return DeleteFileRequest(
      employeeId: map['employeeId'] as String,
      path: map['path'] as String,
    );
  }
}

/// 重命名/移动文件请求
class RenameFileRequest {
  final String employeeId;
  final String oldPath;
  final String newPath;

  const RenameFileRequest({
    required this.employeeId,
    required this.oldPath,
    required this.newPath,
  });

  Map<String, dynamic> toMap() {
    return {
      'employeeId': employeeId,
      'oldPath': oldPath,
      'newPath': newPath,
    };
  }

  factory RenameFileRequest.fromMap(Map<String, dynamic> map) {
    return RenameFileRequest(
      employeeId: map['employeeId'] as String,
      oldPath: map['oldPath'] as String,
      newPath: map['newPath'] as String,
    );
  }
}

/// Ping请求
class PingRequest {
  final String? employeeId;

  const PingRequest({this.employeeId});

  Map<String, dynamic> toMap() {
    final map = <String, dynamic>{};
    if (employeeId != null) {
      map['employeeId'] = employeeId!;
    }
    return map;
  }

  factory PingRequest.fromMap(Map<String, dynamic> map) {
    return PingRequest(
      employeeId: map['employeeId'] as String?,
    );
  }
}

/// 获取或创建Agent请求
class GetOrCreateAgentRequest {
  final String employeeId;

  const GetOrCreateAgentRequest({required this.employeeId});

  Map<String, dynamic> toMap() {
    return {'employeeId': employeeId};
  }

  factory GetOrCreateAgentRequest.fromMap(Map<String, dynamic> map) {
    return GetOrCreateAgentRequest(
      employeeId: map['employeeId'] as String,
    );
  }
}
