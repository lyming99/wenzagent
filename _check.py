import sys
f = open(sys.argv[1], 'rb')
c = f.read()
f.close()
text = c.decode('utf-8')
i = text.find('设置权限回调：通过事件流广播权限请求')
if i >= 0:
    chunk = text[i-80:i+30]
    print(repr(chunk))
    print()
    # Show hex around the key area
    b = c[i-30:i+20]
    print('Bytes:', b.hex(' '))
else:
    print("NOT FOUND")
    # Try to find the pattern
    i2 = text.find('设置权限回调')
    if i2 >= 0:
        print(text[i2-50:i2+50])
