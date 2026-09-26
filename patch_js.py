#!/usr/bin/env python3
# 安全替换 GLQXCheat.m 里的 kBootJS / kHookJS 常量块
import sys

PATH = '/var/minis/workspace/gulong/proj/GLQXCheat.m'
src = open(PATH).read()

BOOT = open('/var/minis/workspace/gulong/proj/_boot.txt').read()
HOOK = open('/var/minis/workspace/gulong/proj/_hook.txt').read()

def replace_block(src, decl_start, new_text):
    i = src.find(decl_start)
    assert i >= 0, decl_start
    # 块结束 = 从 i 开始第一个 '@"})();";'（两个常量的 JS 尾都是 })(); ）
    j = src.find('@"})();";', i)
    assert j > i, 'end not found'
    j += len('@"})();";')
    return src[:i] + new_text + src[j:], src[i:j]

src, old1 = replace_block(src, 'static NSString * const kBootJS', BOOT)
src, old2 = replace_block(src, 'static NSString * const kHookJS', HOOK)

open(PATH, 'w').write(src)
print('boot:', len(old1), '->', len(BOOT))
print('hook:', len(old2), '->', len(HOOK))
# 校验
assert src.count('static NSString * const kBootJS') == 1
assert src.count('static NSString * const kHookJS') == 1
print('OK, total size', len(src))
