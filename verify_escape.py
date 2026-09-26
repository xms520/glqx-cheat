#!/usr/bin/env python3
# 把 GLQXCheat.m 的 kBootJS/kHookJS 常量块转成 C 字符串编译运行，验证 JS 引擎最终收到的字节
import re, subprocess

src = open('/var/minis/workspace/gulong/proj/GLQXCheat.m').read()

def grab(varname):
    i = src.find('static NSString * const ' + varname)
    j = src.find('@"})();";', i)
    assert j > 0, varname
    j += len('@"})();";')
    body = src[i:j]
    m = re.search(r'=\s*((?:@"(?:[^"\\]|\\.)*"\s*)+);', body)
    assert m, varname
    lits = re.findall(r'@"((?:[^"\\]|\\.)*)"', m.group(1))
    # 拼 C 字符串字面量（@"..." 与 "..." 转义规则一致，直接换前缀）
    cstr = ''.join('"%s"' % p for p in lits)
    return cstr

boot_c = grab('kBootJS')
hook_c = grab('kHookJS')

cfile = '''#include <stdio.h>
#include <string.h>
int main(){
    const char *boot = %s;
    const char *hook = %s;
    FILE *f = fopen("/tmp/boot_real.js","w"); fwrite(boot,1,strlen(boot),f); fclose(f);
    f = fopen("/tmp/hook_real.js","w"); fwrite(hook,1,strlen(hook),f); fclose(f);
    printf("boot=%%zu hook=%%zu\\n", strlen(boot), strlen(hook));
    return 0;
}
''' % (boot_c, hook_c)
open('/tmp/test_escape.c','w').write(cfile)
r = subprocess.run(['clang','/tmp/test_escape.c','-o','/tmp/test_escape'], capture_output=True, text=True)
print('compile:', r.returncode, r.stderr[:300])
if r.returncode == 0:
    r2 = subprocess.run(['/tmp/test_escape'], capture_output=True, text=True)
    print(r2.stdout)

# 检查真实 JS 字节：字符串字面量内不得有真实换行
def check(path):
    code = open(path).read()
    in_s = None
    i = 0
    while i < len(code):
        c = code[i]
        if in_s:
            if c == '\\':
                i += 2
                continue
            if c == '\n':
                return 'BUG real newline in %s at %d: ...%s...' % (in_s, i, code[max(0,i-40):i+6])
            if c == in_str_end(in_s, c):
                in_s = None
            i += 1
            continue
        if c in ('"', "'"):
            in_s = c
        i += 1
    return 'CLEAN'

def in_str_end(q, c):
    return q

print('boot_real:', check('/tmp/boot_real.js'))
print('hook_real:', check('/tmp/hook_real.js'))
print('---- boot sample (join 附近) ----')
b = open('/tmp/boot_real.js').read()
i = b.find('join(')
print(repr(b[i:i+30]))
i = b.find('replace(/')
print(repr(b[i:i+30]))
i = b.find('sourceURL')
print(repr(b[i-8:i+20]))
