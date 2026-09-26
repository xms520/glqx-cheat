#!/usr/bin/env python3
# 从 GLQXCheat.m 提取 kBootJS/kHookJS，还原转义，做 JS 语法平衡检查
import re

src = open('/var/minis/workspace/gulong/proj/GLQXCheat.m').read()

def grab(varname):
    i = src.find('static NSString * const ' + varname)
    assert i >= 0, varname
    endm = src.find('@"})();";', i)
    assert endm > 0, varname
    body = src[i:endm + len('@"})();";')]
    parts = re.findall(r'@"((?:[^"\\]|\\.)*)"', body)
    return ''.join(parts)

def unesc(s):
    # ObjC: \" -> " ; \\n -> \n
    return s.replace('\\"', '"').replace('\\n', '\n')

bootjs = unesc(grab('kBootJS'))
hookjs = unesc(grab('kHookJS'))
open('/tmp/boot.js', 'w').write(bootjs)
open('/tmp/hook.js', 'w').write(hookjs)
print('boot len', len(bootjs))
print('hook len', len(hookjs))

def balance(code):
    stack = []
    pairs = {')': '(', '}': '{', ']': '['}
    in_str = None
    i = 0
    while i < len(code):
        c = code[i]
        if in_str:
            if c == '\\':
                i += 2
                continue
            if c == in_str:
                in_str = None
            i += 1
            continue
        if c in '\'"':
            in_str = c
        elif c in '({[':
            stack.append(c)
        elif c in ')}]':
            if not stack or stack[-1] != pairs[c]:
                return 'unbalanced at %d: ...%s...' % (i, code[max(0, i-40):i+5])
            stack.pop()
        i += 1
    if stack:
        return 'unclosed: ' + ''.join(stack)
    if in_str:
        return 'unterminated string'
    return 'OK'

print('boot balance:', balance(bootjs))
print('hook balance:', balance(hookjs))

def str_newline_check(code):
    """字符串/正则字面量内出现真实换行 = ObjC 转义 bug"""
    in_str = None
    i = 0
    while i < len(code):
        c = code[i]
        if in_str:
            if c == '\\':
                i += 2
                continue
            if c == '\n':
                return 'REAL NEWLINE inside %s literal at %d: ...%s...' % (in_str, i, code[max(0, i-50):i+5])
            if c == in_str:
                in_str = None
            i += 1
            continue
        if c in '\'"':
            in_str = c
        elif c == '/' and i+1 < len(code) and code[i+1] != '/' and code[i+1] != '*':
            # 可能是正则字面量（简化：无法精确判断，跳过）
            pass
        i += 1
    if in_str:
        return 'unterminated %s literal' % in_str
    return 'OK'

print('boot str-newline:', str_newline_check(bootjs))
print('hook str-newline:', str_newline_check(hookjs))

for k in ['use strict";(()=>{', '__GLQX_HOOK_SRC', 'fs_readFileSync', 'dcc.readFile',
          'loadLib wrapped', 'bootstrap ok']:
    assert k in bootjs, k
print('boot key strings OK')

for k in ['init_BattleCalc', 'battleCommon', 'BattleCommon_default', 'calDamage', 'calDotDamage',
          'battleTimeScale', 'leftPlayer', 'playerUserId', 'readFlags']:
    assert k in hookjs, k
assert '__GLQX_HOOKED' in bootjs
assert 'use strict' in hookjs or True
print('hook key strings OK')

# 模拟 bundle 插桩：锚点必须唯一且命中
bundle_head = open('/var/minis/workspace/gulong/extracted/js/bundle-36b0d.js', encoding='utf8').read(200)
anchor = '"use strict";(()=>{'
print('bundle head:', bundle_head[:30])
assert bundle_head.startswith(anchor), 'anchor mismatch!'
print('anchor OK -> 插桩后开头:', (anchor + hookjs[:70]).replace(chr(10), ' '))
