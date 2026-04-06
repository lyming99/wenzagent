@echo off
echo ========================================
echo 测试远程对话关闭后授权状态恢复
echo ========================================
echo.

echo [1/3] 运行测试...
dart test test/agent/remote_auth_state_test.dart

if %errorlevel% equ 0 (
    echo.
    echo [2/3] 测试通过！
    echo.
    echo [3/3] 测试报告:
    echo - 远程Proxy创建和销毁
    echo - 状态恢复为idle
    echo - 事件流隔离
    echo - 权限请求清理
    echo ========================================
) else (
    echo.
    echo [错误] 测试失败！
    echo 请检查测试输出。
    echo ========================================
)

pause
