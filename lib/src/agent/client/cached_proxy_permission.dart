part of 'cached_agent_proxy.dart';

/// 权限查询 mixin
mixin _CachedProxyPermission on _CachedAgentProxyBase {
  // ===== 权限查询 =====

  /// 查询待处理的权限请求
  @override
  Future<void> _queryPendingPermission() async {
    if (_isDisposed || _proxy.isLocalMode) return;

    try {
      _CachedAgentProxyBase._log.debug('查询待处理的权限请求...');

      final permissionRequest = await _proxy.getPendingPermissionRequestAsync();
      if (permissionRequest != null) {
        _pendingPermissionRequests[permissionRequest.requestId] =
            permissionRequest;
        _CachedAgentProxyBase._log.info('已缓存权限请求: ${permissionRequest.requestId}');

        // 通知客户端重新加载消息
        _notifyMessagesChanged();
      }
    } catch (e) {
      _CachedAgentProxyBase._log.error('查询权限请求失败', e);
    }
  }
}
