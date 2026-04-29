/// 文件元信息消息
///
/// 作为 [LanMessage.content] 的 JSON 载荷，描述一个可从发送方设备下载的文件。
///
/// 发送方仅广播此元信息，不做任何文件上传。接收方根据元信息中的
/// [fromDeviceId] 和 [filePath]，通过已有的 RPC → Token → HTTP 直传链路
/// 从发送方设备直接拉取文件。
class FileMetaMessage {
  /// 文件唯一标识（发送方生成的 UUID）
  final String fileId;

  /// 文件名
  final String fileName;

  /// 文件大小（字节）
  final int fileSize;

  /// SHA256 哈希（用于校验下载完整性）
  final String sha256;

  /// 文件在发送方设备上的绝对路径
  final String filePath;

  /// 发送方设备 ID
  final String fromDeviceId;

  /// MIME 类型（可选，用于前端预览判断）
  final String? mimeType;

  /// 消息角色（user / assistant），用于持久化时区分发送方
  final String? role;

  /// 所属会话 / 员工 ID，用于持久化到正确的会话
  final String? employeeId;

  const FileMetaMessage({
    required this.fileId,
    required this.fileName,
    required this.fileSize,
    required this.sha256,
    required this.filePath,
    required this.fromDeviceId,
    this.mimeType,
    this.role,
    this.employeeId,
  });

  factory FileMetaMessage.fromJson(Map<String, dynamic> json) =>
      FileMetaMessage(
        fileId: json['fileId'] as String,
        fileName: json['fileName'] as String,
        fileSize: json['fileSize'] as int,
        sha256: json['sha256'] as String,
        filePath: json['filePath'] as String,
        fromDeviceId: json['fromDeviceId'] as String,
        mimeType: json['mimeType'] as String?,
        role: json['role'] as String?,
        employeeId: json['employeeId'] as String?,
      );

  Map<String, dynamic> toJson() => {
        'fileId': fileId,
        'fileName': fileName,
        'fileSize': fileSize,
        'sha256': sha256,
        'filePath': filePath,
        'fromDeviceId': fromDeviceId,
        if (mimeType != null) 'mimeType': mimeType,
        if (role != null) 'role': role,
        if (employeeId != null) 'employeeId': employeeId,
      };

  @override
  String toString() =>
      'FileMetaMessage(fileId: $fileId, fileName: $fileName, '
      'fileSize: $fileSize, fromDeviceId: $fromDeviceId, '
      'role: $role, employeeId: $employeeId)';
}
