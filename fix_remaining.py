#!/usr/bin/env python3
"""Fix remaining await patterns in Dart test files.
Handles:
1. final x = store.method(...);  ->  final x = await store.method(...);
2. expect(await store.method(...)!.prop  ->  expect((await store.method(...))!.prop
"""
import re
import sys

def fix_file(filepath):
    with open(filepath, 'r', encoding='utf-8') as f:
        content = f.read()
    
    # Fix pattern: expect(await store.method(...)!.property
    # Should be: expect((await store.method(...))!.property
    # The await was placed before store.method but ! is after the closing paren
    # Pattern: 'await store.name(args)!.property' -> '(await store.name(args))!.property'
    content = re.sub(
        r'await (store\.\w+\([^)]*\))!([.\[])',
        r'(await \1)!\2',
        content
    )
    
    # Fix: final x = store.method(args); -> final x = await store.method(args);
    # Only if not already awaited
    content = re.sub(
        r'(final \w+ = )(store\.\w+\([^)]*\);)',
        lambda m: m.group(1) + 'await ' + m.group(2) if not m.group(2).startswith('await') else m.group(0),
        content
    )
    
    # Fix: final x = store.method(args)!\n -> final x = (await store.method(args))!
    content = re.sub(
        r'(final \w+ = )(store\.\w+\([^)]*\))!',
        r'\1(await \2)!',
        content
    )
    
    # Fix double await
    content = content.replace('await await ', 'await ')
    content = content.replace('await (await ', 'await (')
    # Fix: final x = await await store -> final x = await store
    content = re.sub(r'= await await ', '= await ', content)
    
    with open(filepath, 'w', encoding='utf-8') as f:
        f.write(content)
    
    print(f"Fixed {filepath}")

if __name__ == '__main__':
    fix_file(sys.argv[1])
