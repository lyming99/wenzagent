import re

path = r'd:\project\GitHub\wenzagent\lib\src\shared\chat_message.dart'
with open(path, 'r', encoding='utf-8') as f:
    content = f.read()

old = '  /// 处理中\n  processing,\n\n  /// 已完成'
new = '  /// 处理中\n  processing,\n\n  /// LLM 调用重试中\n  retrying,\n\n  /// 已完成'

if old in content:
    content = content.replace(old, new)
    with open(path, 'w', encoding='utf-8', newline='') as f:
        f.write(content)
    print('SUCCESS: retrying added to MessageStatus')
else:
    # Try with CRLF
    old_crlf = old.replace('\n', '\r\n')
    new_crlf = new.replace('\n', '\r\n')
    if old_crlf in content:
        content = content.replace(old_crlf, new_crlf)
        with open(path, 'w', encoding='utf-8', newline='') as f:
            f.write(content)
        print('SUCCESS: retrying added to MessageStatus (CRLF)')
    else:
        print('FAILED: pattern not found')
        # Show context
        import re
        idx = content.find('processing,')
        if idx >= 0:
            print('Context around processing:')
            print(repr(content[idx-50:idx+100]))
