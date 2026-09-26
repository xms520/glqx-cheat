// GLQXCheat.m — 古龙群侠录 悬浮助手 v1（arm64, TrollFools 注入）
// 功能：秒杀 / 无敌 / 全局加速（战斗内 timeScale）
//
// 引擎档案（逆向实证）：
//   LayaAir 3.x Conch（laya::JSRuntime + V8），游戏代码经 CDN + dcc2.0(git-like对象库) 加载
//   主二进制 ObjC 类 conchRuntime：-[conchRuntime runJS:] imp=0x100257790（native→JS 闭包队列，线程安全）
//   战斗系统：src/sharecode/battle/battleLogic（esbuild bundle js/bundle-36b0d.js）
//     - BattleCalc.calDamage(attacker, defender, base, opts) → {damage, block}  本地伤害计算
//     - BattleCalc.calDotDamage(...)                                            DOT 伤害
//     - battleCommon.battleTimeScale                                            战斗时间速率（公共属性）
//     - Hero.playerUserId === battleCommon.leftPlayer.uuid                      阵营判定
// 注入链：swizzle -[conchRuntime update]（等5帧）→ [self runJS: bootstrap]
//   bootstrap: wrap window.loadLib → dcc.readFile(url) → bundle 头部插入 HOOK_SRC → window.eval
//   HOOK_SRC（bundle IIFE 内执行，可访问内部模块）：
//     轮询 init_BattleCalc()/battleCommon → wrap calDamage/calDotDamage + 500ms 读 flags 文件
// 状态同步：native 写 glqx_flags.json（Documents/Library-Caches/Library-Preferences/tmp 四路）
//           JS 侧 fs_readFileSync('glqx_flags.json' 或 conch.getCachePath()+'/glqx_flags.json')
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <QuartzCore/QuartzCore.h>
#import <unistd.h>
#import <stdio.h>
#import <string.h>
#import "fishhook.h"

static FILE *g_log = NULL;
static void mlog(NSString *fmt, ...) NS_FORMAT_FUNCTION(1,2);
static void mlog(NSString *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSLog(@"[GLQX] %@", s);
    if (!g_log) {
        NSString *p = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents/glqx.log"];
        g_log = fopen(p.UTF8String, "a");
    }
    if (g_log) { fprintf(g_log, "[GLQX] %s\n", s.UTF8String); fflush(g_log); }
}

#pragma mark - v1.4: fopen 重定向（JS↔native 文件通道闭环）
// LayaNative 的 fs_readFileSync/fs_writeFileSync 底层是纯 fopen，相对路径基于进程 cwd
// （iOS 默认 "/"，不可写）。JS 侧读 glqx_flags.json / 写 glqx_js_probe.txt / glqx_js.log
// 全部落到错误位置。这里用 fishhook 把这三个文件名的【相对路径】读写一律重定向到
// Documents —— native 写 flags 到 Documents，JS 读必中；JS 写日志/探针 native 也必能扫到。
static FILE *(*orig_fopen)(const char *, const char *);
static FILE *my_fopen(const char *path, const char *mode) {
    if (path && path[0] != '/') {
        const char *slash = strrchr(path, '/');
        const char *base = slash ? slash + 1 : path;
        if (!strcmp(base, "glqx_flags.json") || !strcmp(base, "glqx_js_probe.txt") || !strcmp(base, "glqx_js.log")) {
            static char s_doc[512];
            if (!s_doc[0]) snprintf(s_doc, sizeof(s_doc), "%s/Documents", NSHomeDirectory().UTF8String);
            char np[768];
            snprintf(np, sizeof(np), "%s/%s", s_doc, base);
            return orig_fopen(np, mode);
        }
    }
    return orig_fopen(path, mode);
}
static void mx_install_fopen_hook(void) {
    rebind_symbols((struct rebinding[1]){{"fopen", (void *)my_fopen, (void *)&orig_fopen}}, 1);
    mlog(@"fopen redirect installed (glqx_* -> Documents)");
}

#pragma mark - 功能状态 + 文件同步
static int g_kill = 0;      // 秒杀 0/1
static int g_inv = 0;       // 无敌 0/1
static int g_spdIdx = 0;    // 0=OFF 1=x2 2=x4 3=x8
static const int kSpdVal[4] = {1, 2, 4, 8};

static NSString *g_jsCachePath = nil;   // v1.3: 从 JS 探针解析出的真实 cache 路径
static BOOL g_probeSeen = NO;

static void sync_flags(void) {
    NSString *json = [NSString stringWithFormat:@"{\"kill\":%d,\"inv\":%d,\"spd\":%d}",
                      g_kill, g_inv, kSpdVal[g_spdIdx]];
    NSString *home = NSHomeDirectory();
    NSMutableArray *dirs = [NSMutableArray arrayWithArray:@[
        [home stringByAppendingPathComponent:@"Documents"],
        [home stringByAppendingPathComponent:@"Library/Caches"],
        [home stringByAppendingPathComponent:@"Library/Preferences"],
        [home stringByAppendingPathComponent:@"tmp"],
        [NSString stringWithUTF8String:getcwd(NULL, 0) ?: "/"]]];
    if (g_jsCachePath) [dirs addObject:g_jsCachePath];
    for (NSString *d in dirs)
        [json writeToFile:[d stringByAppendingPathComponent:@"glqx_flags.json"]
               atomically:YES encoding:NSUTF8StringEncoding error:nil];
    mlog(@"flags sync: %@", json);
}

// 读 JS 探针（glqx_js_probe.txt，内容含 cachePath=...）→ 得知 JS 侧真实可写路径
static void mx_scan_probe(void) {
    if (g_probeSeen) return;
    NSString *home = NSHomeDirectory();
    NSMutableArray *dirs = [NSMutableArray arrayWithArray:@[
        [home stringByAppendingPathComponent:@"Documents"],
        [home stringByAppendingPathComponent:@"Library/Caches"],
        [home stringByAppendingPathComponent:@"tmp"],
        [NSString stringWithUTF8String:getcwd(NULL, 0) ?: "/"]]];
    for (NSString *d in dirs) {
        NSString *p = [d stringByAppendingPathComponent:@"glqx_js_probe.txt"];
        NSString *s = [NSString stringWithContentsOfFile:p encoding:NSUTF8StringEncoding error:nil];
        if (!s) continue;
        NSString *cp = nil;
        for (NSString *line in [s componentsSeparatedByString:@"\n"])
            if ([line hasPrefix:@"cachePath="]) cp = [line substringFromIndex:10];
        if (cp.length) {
            g_jsCachePath = cp;
            mlog(@"js probe: cachePath=%@, resync flags", cp);
        } else {
            mlog(@"js probe found (no cachePath): %@", s);
        }
        g_probeSeen = YES;
        sync_flags();   // 拿到 cachePath 后立即补写一份
        return;
    }
}

#pragma mark - 内嵌头像（base64 JPEG 256x256）
static NSString * const kAvatarB64 =
    @"/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAAYEBQYFBAYGBQYHBwYIChAKCgkJChQODwwQFxQYGBcUFhYaHSUfGhsjHBYWICwgIyYnKSopGR8tMC0oMCUoKSj/2wBDAQcHBwoIChMKChMoGhYaKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCj/wAARCAEAAQADASIAAhEBAxEB/8QAHwAAAQUBAQEBAQEAAAAAAAAAAAECAwQFBgcICQoL/8QAtRAAAgEDAwIEAwUFBAQAAAF9AQIDAAQRBRIhMUEGE1FhByJxFDKBkaEII0KxwRVS0fAkM2JyggkKFhcYGRolJicoKSo0NTY3ODk6Q0RFRkdISUpTVFVWV1hZWmNkZWZnaGlqc3R1dnd4eXqDhIWGh4iJipKTlJWWl5iZmqKjpKWmp6ipqrKztLW2t7i5usLDxMXGx8jJytLT1NXW19jZ2uHi4+Tl5ufo6erx8vP09fb3+Pn6/8QAHwEAAwEBAQEBAQEBAQAAAAAAAAECAwQFBgcICQoL/8QAtREAAgECBAQDBAcFBAQAAQJ3AAECAxEEBSExBhJBUQdhcRMiMoEIFEKRobHBCSMzUvAVYnLRChYkNOEl8RcYGRomJygpKjU2Nzg5OkNERUZHSElKU1RVVldYWVpjZGVmZ2hpanN0dXZ3eHl6goOEhYaHiImKkpOUlZaXmJmaoqOkpaanqKmqsrO0tba3uLm6wsPExcbHyMnK0tPU1dbX2Nna4uPk5ebn6Onq8vP09fb3+Pn6/9oADAMBAAIRAxEAPwD6VaszVNRW1jYIw345P93/AOvU+p3a2sR5Acjv2HrXnWuaoZ3ZIydmfzrKrV5VZG1Gjzu72Kus37XUxVSSM/UmqQj8pS2fm7n0+lTWcBYtK52oOpqzDB9sk3Y2wL0HrXDZtnpJqKsZKWrzsW520lzEtuuOrnoK3ppIoIWkA/dr8qj+81V7HTmlY3d3nLHKrQ420W4KV9XsYi2jbfMl6noKrzWzE811M1qWJJFU7i3VFJbgU/Z2D2lzmHtiO1ItmTwfx9q3/sxYIUGXk+4Pb+8ap6mUtozDG2T/ABN6mocS1Iw548t5cQyar6hGthb7pPvnpXUaNYKLSS+n4jAJBPpXmnjHWhJNLJk7AcIB3qZQsXGV2Y+uaoVYhTmRugridR1XfOUBMsgPOBkCtVIJdQnZSTz99gf0FdNpehQwRgLGo+grWCUEY1JOR56LxJPklGCfUYNdj4f8Vy6Z4Yksg5E0UzNG+egZQM/pXZ2HhdNTPlfZklU9dy5Fd54Q+EehWVwLq5s1nk6iOUlkX6KaJNNWJU+TVnzqdX1Ez+fGtw4znIHFeieGvFP9oWaW2pEvGeFc9UNe56l8P/Dt3GVbTIEJH3oxt/lXnniH4TLaPJc6JIyt3iY5Df4H3qHpsVGqpaM5TVLMwuSp3IeQR3rJfIzWvbyy20r6bqaMjKcKW6g1Sv7cxSMDUW6o2M96jJNOl4NRk9xTQDxIG+V+n8qY2Y34NNYg+xqPeR8j/gapEtG3oet3WlXsdzZzNFOhyGU19D+BfGFt4nssMVi1CNcyxdm/2l9vbtXy4GwcHgitfQtYudKv4bq0laOaJgVYV0UqjicleipH1mTRurD8G+I7bxNo6XUO1J1ws8Q/gb29j2rbYV2p3PNaadmLupc0wClNAATRjim96fjjFAHD+JdaM7siPnJ5PrWBZRNd3IQfjWZc3O5iSa2hnS9PVDxeXAyR/cX0+teY5czuz2VDkVkS3LrLMLaHiJPvEd6ke43sLS3O1QP3jf3RWNLdfZo9qcyvwKv6fCEg/ethT80jevtTTt6iaNK1t1upBNMNtrFxGvrWn/rDkjC9hWdazm4YEDbEvCrWmZFVMk4xWkUY1GQ3RSKNmbgCuUS7XU76TGfsVvy5H8bdlH1qh4z8QvLOunWGXlkYJhepJ7V0PhvT47GyTfgw2vzMf+ekp6n8OgqXK7sjSMeVXZJe/wCgWrSS4+1TDJA/gHYCuHvJnvNQgs4j+8nkCD8eprZ8SamZHkdjWD4C/wCJj4rmnJ+S3TYD/tN1P4KGqXvZGkVpzM6H4j6imlaHbadbna0i5OOyjpXgl/K9/fbI8kA7V+vc12nxN1xtQ1e6eNuC3lReyjiuf8MWG8+eR14X6f8A16Td3cPhjY1tE0tYYlAWux0PRnvplVRhAeTUOj6e1zMkSDr1r1nw7pCWsS7V5pLUylKw/QtEis4lCoAfpXSxRhV4FJFFgVN0FO1jBu4xhkVWlQHNWiahk5oYHn3xD8IJrNi1xZoF1CEZQj+Mf3f8K8gWRpozBcArNHxz147GvpWdcg15H8U/Dn2eb+2bJMIxAuVXsez/AI9D71m9Drozv7rPM7hdrEHtWe7+W/tWvdjzF39+9ZF2mVOKcTVjtwYZFDYZSrdPX0qjbz5JXupwRVksCKdrMW6GljG2x+o6H1FTxNnpTFQXCGJuG6qfeqkU7QzNHJwQcH2rRLqZS7Hd+AvE0/hrWorlCWt2+SaPs6d/x7ivpq2uIry1iubZxJBKodHHQg9K+QrchhxXt3wU8QtLDLod0/zIDLb5Pb+Jf6/nXVSlbQ4q8PtHqWKDQ2aStzkADmnimjpTx0oQzxTw5EpD6tfD/RoTiFD/AMtZP8BReXrSSS3M7ZZjmjU71J2jht18uzgGyJPQep9zWFcTG6uBEh+Qda8lM9219TV0zNxObiXoPu1qNcGeUQofkHWshphDBheAOB7mtDTBtTc33jTTJfc6K1YRoAO1YfjDxCNPsnRG/esMD2qS/wBQS0tXkdgABXkuvalNq2pCOPLSSOERfqeK0crKyM4Qu7s6vwDaS3+oS6lICz7vLhJ/vnq34D9TXfa1dpbWqWkB/dxjBPqaz/DNpHpOlIE6Rp5aH1P8TfiaydYvcljmlHRXHL3pWOc8T6h5cMhLc1L4BmOn+FNR1IkiSUOyn3PyL/I/nXF+MNQ3M4BrpLub+z/AtnajhpNufoq/4k1N+ppbSxxGoM17qRRSeDt/E9T+Vdxo1mI4kCjpwBXH+HYPPv8AzG5xlvxJ/wABXqPh61828hiVGkkJ4jQZJ/Ch9jKTvqdr4L0gRxiV1+Zq7+2iVF4FUNE0e9SBfMWOAf3Scn9K21sHUczDP+7/APXrSNOXY5JVIt7kYoYVK1rKo+Uq36VAxIO1gQfQ0mmtxJp7DTxmonNPY1FI1SMil5rMv7eO4glhnQPFIpVlPQg9RWi5qpOw5qWaRdj5+8T6NJoerTWj5aE/NC5/iQ9PxHQ1y9yu1mB6V77428M3GvaZvtLaSSeAl0ZV6juM/wCeleF6jEyEhhhlODUpHZGSkvM5DVpjYajDMf8AUzfI3swrWifcgZeQazvE8H2jSbgAZaMeYv4dapeF9Q8+AROfmXp71u1zRUjFStJxZ0AcqwI4NP1mHzbRb+MfMuFlA/Q1E44yK0NFlR5Hgn5imXYwoh2YVO5R0i8+by3P0NdroN/LpuoW1/akiWBw4x3x2rzeeF7G9mt3JDxPgH27V1eg3qzKFY89DW0dNDGaurn1xY3cV/YwXlucwzoJFPsRUuK4L4O6qbnRrjTZGzJaNvT/AHG/wP8AOu+I5rpTujgkrOwcU/HFMxUg6U0I+b9QuvLTYh+Y9aNOTbHvPVqxHmaa4APJdsVt3M62tsT6DArxvI+gJvP+0akkCfdiG9vr0ArdSQImPSuX8NKTA9y/3ppC2f8AZHA/XNXNX1AQQFVPzmrT1Jkuhk+LtWMm6JG+RetY/gK0N5rr3TD5YBhf948foM1l65cE5GeSea7XwBai00iORhhpP3h/Hp+mKbEdjfXIjgWNeFUYriNevtkbnNbmqXXytg1534kvMsyg02+iJiranM6zMbi5Vcn5nC/mcV2HjCcpYW0QP3Y/5muBL79XsI+7Tp/Ouw8WSb7uNOwCj8uabWqQJ+62S+EIZZpvIs03TuwBOMhB0H4nsK+pvh94Sh0PTEd03XcgDSyNyxPpmvJ/gR4b"
    @"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"
    @"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"
    @"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";

static UIImage *mx_avatar(void) {
    static UIImage *img = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSData *d = [[NSData alloc] initWithBase64EncodedString:kAvatarB64 options:0];
        img = [UIImage imageWithData:d];
    });
    return img;
}

#pragma mark - JS 注入源码
// bootstrap：最早注入（runJS: 全局上下文）
// 1) 定义 readFlags  2) wrap window.loadLib（dcc 读源码→bundle插桩→eval）
// 3) 兜底拦 window.eval（CDN index.js 若先执行则补 wrap）
// bootstrap：最早注入（runJS: 全局上下文）；v1.3 + jlog/probe/readFlags 强化
// bootstrap：最早注入（runJS: 全局上下文）；v1.3 + jlog/probe/readFlags 强化
// bootstrap：最早注入（runJS: 全局上下文）；v1.3 + jlog/probe/readFlags 强化
static NSString * const kBootJS = @"(function(){"
@"if(window.__GLQX_BOOTED)return;window.__GLQX_BOOTED=1;"
@"var w=window;w.__GLQX={kill:0,inv:0,spd:0,jlogs:[]};"
@"function CP(){try{return (typeof conch!=='undefined'&&conch&&conch.getCachePath)?conch.getCachePath():'';}catch(e){return '';}}"
@"w.__GLQX.jlog=function(m){"
@"try{"
@"w.__GLQX.jlogs.push('['+((Date.now()/1000)%1000).toFixed(1)+'] '+m);"
@"if(w.__GLQX.jlogs.length>150)w.__GLQX.jlogs.shift();"
@"var txt=w.__GLQX.jlogs.join('\\n');"
@"var ps=['glqx_js.log'];"
@"var cp=CP();if(cp)ps.push(cp+'/glqx_js.log');"
@"for(var i=0;i<ps.length;i++){try{fs_writeFileSync(ps[i],txt);return;}catch(e){}}"
@"}catch(e){}"
@"};"
@"var J=w.__GLQX.jlog;"
@"function toStr(v){"
@"if(v==null)return null;"
@"if(typeof v==='string')return v;"
@"try{return new TextDecoder('utf8').decode(v);}catch(e){}"
@"try{var u8=new Uint8Array(v),o=[],i=0;"
@"while(i<u8.length){var c=u8[i];"
@"if(c<128){o.push(String.fromCharCode(c));i++;}"
@"else if(c<224){o.push(String.fromCharCode(((c&31)<<6)|(u8[i+1]&63)));i+=2;}"
@"else{o.push(String.fromCharCode(((c&15)<<12)|((u8[i+1]&63)<<6)|(u8[i+2]&63)));i+=3;}}"
@"return o.join('');}catch(e){return null;}"
@"}"
@"w.__GLQX.toStr=toStr;"
@"w.__GLQX.readFlags=function(){"
@"var ns=['glqx_flags.json'];"
@"var cp=CP();if(cp){ns.push(cp+'/glqx_flags.json');ns.push(cp+'/../Documents/glqx_flags.json');ns.push(cp+'/../../Documents/glqx_flags.json');}"
@"ns.push('Documents/glqx_flags.json');ns.push('Library/Caches/glqx_flags.json');ns.push('tmp/glqx_flags.json');"
@"for(var i=0;i<ns.length;i++){"
@"try{var raw=null;"
@"if(typeof fs_readFileSync==='function')raw=fs_readFileSync(ns[i],'utf8');"
@"else if(typeof readFileSync==='function')raw=readFileSync(ns[i],'utf8');"
@"var s=toStr(raw);"
@"if(s&&s.length>2&&s.indexOf('{')>=0)return s;"
@"}catch(e){}}"
@"return null;"
@"};"
@"function probe(){"
@"var info='';"
@"info+='cachePath='+CP()+'\\n';"
@"try{info+='exePath='+getExePath()+'\\n';}catch(e){info+='exePath=ERR\\n';}"
@"info+='fs_read='+(typeof fs_readFileSync)+' read='+(typeof readFileSync)+' fs_write='+(typeof fs_writeFileSync)+' wstr='+(typeof writeStrFileSync)+'\\n';"
@"var ps=['glqx_js_probe.txt'];var cp=CP();if(cp)ps.push(cp+'/glqx_js_probe.txt');"
@"for(var i=0;i<ps.length;i++){try{fs_writeFileSync(ps[i],info);}catch(e){}}"
@"J('probe: '+info.replace(/\\n/g,' | '));"
@"}"
@"function wrapLoad(){"
@"if(w.__GLQX_WRAPPED)return;w.__GLQX_WRAPPED=1;"
@"var orig=w.loadLib;w.__GLQX_ORIG=orig;"
@"var chain=Promise.resolve();"
@"function dec(u8){var o=[],i=0;"
@"while(i<u8.length){var c=u8[i];"
@"if(c<128){o.push(String.fromCharCode(c));i++;}"
@"else if(c<224){o.push(String.fromCharCode(((c&31)<<6)|(u8[i+1]&63)));i+=2;}"
@"else{o.push(String.fromCharCode(((c&15)<<12)|((u8[i+1]&63)<<6)|(u8[i+2]&63)));i+=3;}}"
@"return o.join('');}"
@"var fn=function(url){"
@"try{"
@"if(typeof url!=='string')return orig(url);"
@"if(url.indexOf('js/')<0&&url.indexOf('libs/')<0)return orig(url);"
@"chain=chain.then(function(){"
@"if(!w.dcc||!w.dcc.readFile)throw 'nodcc';"
@"return w.dcc.readFile(url);"
@"}).then(function(buf){"
@"if(buf==null)throw 'empty';"
@"var txt=(typeof buf==='string')?buf:null;"
@"if(txt==null){"
@"try{txt=new TextDecoder('utf8').decode(buf);}catch(e){"
@"txt=dec(new Uint8Array(buf));}}"
@"if(url.indexOf('js/bundle')>=0&&txt.indexOf('BattleCalc')>=0&&txt.indexOf('__GLQX_HOOKED')<0){"
@"txt=txt.replace('\"use strict\";(()=>{','\"use strict\";(()=>{'+w.__GLQX_HOOK_SRC+';var __GLQX_HOOKED=1;');"
@"J('bundle instrumented, len='+txt.length);"
@"}"
@"w.eval(txt+'\\n//@ sourceURL='+url);"
@"J('lib ok '+url);"
@"}).catch(function(e){"
@"J('read fail '+url+' '+e);"
@"orig(url);});"
@"}catch(e){J('loadLib err '+e);try{orig(url);}catch(_){}}};"
@"w.loadLib=fn;"
@"J('loadLib wrapped');"
@"}"
@"probe();"
@"wrapLoad();"
@"var oe=w.eval;"
@"w.eval=function(code){"
@"try{"
@"if(typeof code==='string'&&code.indexOf('loadLib(')>=0&&code.length<40000&&!w.__GLQX_WRAPPED){wrapLoad();}"
@"}catch(e){}"
@"return oe.call(w,code);};"
@"J('bootstrap ok');"
@"})();";




// HOOK_SRC：插入 bundle IIFE 内部（可访问 esbuild 顶层 var）
// HOOK_SRC：插入 bundle IIFE 内部（可访问 esbuild 顶层 var）；日志走 jlog（写文件）
// HOOK_SRC：插入 bundle IIFE 内部（可访问 esbuild 顶层 var）；日志走 jlog（写文件）
// HOOK_SRC：插入 bundle IIFE 内部（可访问 esbuild 顶层 var）；日志走 jlog（写文件）
static NSString * const kHookJS =
@";(function(){"
@"if(window.__GLQX_INNER)return;window.__GLQX_INNER=1;"
@"var w=window;"
@"function lg(m){try{console.log('[GLQX] '+m);}catch(e){}try{w.__GLQX&&w.__GLQX.jlog&&w.__GLQX.jlog(m);}catch(e){}}"
@"var tries=0;"
@"var timer=setInterval(function(){"
@"tries++;"
@"try{"
@"try{if(typeof init_BattleCalc==='function')init_BattleCalc();}catch(e){}"
@"var CM=(typeof battleCommon!=='undefined'&&battleCommon)?battleCommon:"
@"((typeof BattleCommon_default!=='undefined'&&BattleCommon_default)?BattleCommon_default:null);"
@"var BC=(typeof BattleCalc!=='undefined')?BattleCalc:null;"
@"if(tries%2===0){"
@"var s=null;"
@"try{s=(w.__GLQX&&w.__GLQX.readFlags)?w.__GLQX.readFlags():null;}catch(e){}"
@"if(s){"
@"try{var o=JSON.parse(s);"
@"var nk=o.kill|0,ni=o.inv|0,nsp=o.spd|0;"
@"if(nk!==w.__GLQX.kill||ni!==w.__GLQX.inv||nsp!==w.__GLQX.spd){"
@"w.__GLQX.kill=nk;w.__GLQX.inv=ni;w.__GLQX.spd=nsp;"
@"lg('flags applied k='+nk+' i='+ni+' s='+nsp);"
@"}"
@"}catch(e){lg('flags parse err '+e);}"
@"}else if(tries===2||tries===20){lg('readFlags empty t='+tries);}"
@"if(CM&&w.__GLQX.spd>1){"
@"try{if(CM.battleTimeScale!==w.__GLQX.spd){CM.battleTimeScale=w.__GLQX.spd;lg('timeScale='+w.__GLQX.spd);}}catch(e){}"
@"}"
@"}"
@"if(BC&&CM&&!w.__GLQX_PATCHED){"
@"w.__GLQX_PATCHED=1;"
@"function isOur(u){"
@"try{"
@"if(!u)return false;"
@"var lp=CM.leftPlayer;"
@"if(!lp)return false;"
@"if(u===lp)return true;"
@"if(u.player===lp)return true;"
@"if(u.getPlayer&&u.getPlayer()===lp)return true;"
@"if(u.playerUserId!=null&&lp.uuid!=null&&u.playerUserId===lp.uuid)return true;"
@"return false"
@"}catch(e){return false;}"
@"}"
@"var oCal=BC.calDamage;"
@"BC.calDamage=function(atk,def,base,opts){"
@"try{"
@"if(w.__GLQX.inv&&def&&isOur(def))return{damage:0,block:true};"
@"var r=oCal.apply(this,arguments);"
@"if(w.__GLQX.kill&&atk&&isOur(atk)&&def&&!isOur(def)){"
@"r.damage=(def.hp||0)+(def.armor||0)+1;r.block=false;"
@"}"
@"return r;"
@"}catch(e){return oCal.apply(this,arguments);}"
@"};"
@"var oDot=BC.calDotDamage;"
@"if(oDot)BC.calDotDamage=function(atk,def,base,typ){"
@"try{"
@"if(w.__GLQX.inv&&def&&isOur(def))return 0;"
@"return oDot.apply(this,arguments);"
@"}catch(e){return oDot.apply(this,arguments);}"
@"};"
@"w.__GLQX.isOur=isOur;w.__GLQX.calc=BC;w.__GLQX.common=CM;"
@"lg('BattleCalc patched, leftPlayer='+(CM.leftPlayer?'1':'0'));"
@"}"
@"if(tries===10||tries===60||tries===240){"
@"lg('waiting: BC='+(typeof BC)+' CM='+(typeof CM)+' inner='+!!w.__GLQX_PATCHED);"
@"}"
@"}catch(e){if(tries%100===0)lg('tick err '+e);}"
@"},500);"
@"})();";




#pragma mark - conchRuntime hook（手写 swizzle，零依赖）
static int g_updateTicks = 0;
static BOOL g_bootInjected = NO;

static void (*orig_update)(id, SEL);
static void hook_update(id self, SEL _cmd) {
    orig_update(self, _cmd);
    if (g_bootInjected) return;
    if (++g_updateTicks < 5) return;   // 等引擎就绪
    g_bootInjected = YES;
    if (![self respondsToSelector:@selector(runJS:)]) {
        mlog(@"runJS: selector missing!"); return;
    }
    // JS 字符串安全转义（NSJSONSerialization）
    NSData *d = [NSJSONSerialization dataWithJSONObject:@[kHookJS] options:0 error:nil];
    NSString *arr = [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding];
    NSString *quoted = [arr substringWithRange:NSMakeRange(1, arr.length - 2)];
    NSString *boot = [NSString stringWithFormat:@"window.__GLQX_HOOK_SRC=%@;\n%@", quoted, kBootJS];
    ((void(*)(id, SEL, id))objc_msgSend)(self, @selector(runJS:), boot);
    mlog(@"bootstrap injected via update (tick#%d, %lu bytes)", g_updateTicks, (unsigned long)boot.length);
}

static void mx_install_hooks(void) {
    Class c = objc_getClass("conchRuntime");
    if (!c) { mlog(@"class conchRuntime NOT FOUND"); return; }
    Method m = class_getInstanceMethod(c, @selector(update));
    if (!m) { mlog(@"-[conchRuntime update] NOT FOUND"); return; }
    orig_update = (void (*)(id, SEL))method_getImplementation(m);
    method_setImplementation(m, (IMP)hook_update);
    mlog(@"-[conchRuntime update] hooked");
}

#pragma mark - 彩虹环悬浮球
static void mx_addRainbowRing(CALayer *parent, CGFloat inset) {
    CAGradientLayer *g = [CAGradientLayer layer];
    g.type = kCAGradientLayerConic;
    g.colors = @[(id)[UIColor colorWithRed:0 green:0.85 blue:0.85 alpha:1].CGColor,
                 (id)[UIColor colorWithRed:0.35 green:0.35 blue:1 alpha:1].CGColor,
                 (id)[UIColor colorWithRed:1 green:0.15 blue:0.15 alpha:1].CGColor,
                 (id)[UIColor colorWithRed:1 green:0.6 blue:0 alpha:1].CGColor,
                 (id)[UIColor colorWithRed:0 green:0.85 blue:0.85 alpha:1].CGColor];
    g.startPoint = CGPointMake(0.5, 0.5);
    g.endPoint = CGPointMake(0.5, 0);
    g.frame = CGRectMake(0, 0, parent.bounds.size.width, parent.bounds.size.height);
    g.cornerRadius = g.frame.size.width / 2;
    CAShapeLayer *mask = [CAShapeLayer layer];
    CGFloat r = g.frame.size.width / 2;
    UIBezierPath *outer = [UIBezierPath bezierPathWithArcCenter:CGPointMake(r, r) radius:r startAngle:0 endAngle:M_PI*2 clockwise:YES];
    CGFloat ri = r * inset;
    UIBezierPath *inner = [UIBezierPath bezierPathWithArcCenter:CGPointMake(r, r) radius:ri startAngle:0 endAngle:M_PI*2 clockwise:YES];
    [outer appendPath:inner];
    mask.path = outer.CGPath;
    mask.fillRule = kCAFillRuleEvenOdd;
    g.mask = mask;
    [parent addSublayer:g];
}

#pragma mark - 面板（可拖动 + ✕ 关闭 + 3 开关）
@class MXBox;
static MXBox *g_panel = nil;
static UILabel *g_btnKill = nil, *g_btnInv = nil, *g_btnSpd = nil;

static void mx_refreshButtons(void) {
    g_btnKill.text = g_kill ? @"💀 秒杀  ON" : @"💀 秒杀  OFF";
    g_btnKill.textColor = g_kill ? [UIColor colorWithRed:0.3 green:1 blue:0.4 alpha:1] : UIColor.lightGrayColor;
    g_btnInv.text = g_inv ? @"🛡 无敌  ON" : @"🛡 无敌  OFF";
    g_btnInv.textColor = g_inv ? [UIColor colorWithRed:0.3 green:1 blue:0.4 alpha:1] : UIColor.lightGrayColor;
    g_btnSpd.text = g_spdIdx == 0 ? @"⏩ 加速  OFF" : [NSString stringWithFormat:@"⏩ 加速  x%d", kSpdVal[g_spdIdx]];
    g_btnSpd.textColor = g_spdIdx ? [UIColor colorWithRed:1 green:0.8 blue:0.2 alpha:1] : UIColor.lightGrayColor;
}

@interface MXBox : UIView
@end
@implementation MXBox
- (instancetype)initWithFrame:(CGRect)f {
    if ((self = [super initWithFrame:f])) {
        self.backgroundColor = [UIColor colorWithRed:0.08 green:0.08 blue:0.12 alpha:0.96];
        self.layer.cornerRadius = 18;
        self.layer.borderWidth = 1;
        self.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.15].CGColor;
        self.layer.shadowColor = UIColor.blackColor.CGColor;
        self.layer.shadowOpacity = 0.5;
        self.layer.shadowRadius = 12;
        self.userInteractionEnabled = YES;

        // 左上角彩虹头像
        UIImageView *av = [[UIImageView alloc] initWithFrame:CGRectMake(14, 14, 40, 40)];
        av.image = mx_avatar();
        av.layer.cornerRadius = 20;
        av.layer.masksToBounds = YES;
        av.layer.borderWidth = 2.5;
        av.layer.borderColor = [UIColor colorWithRed:1 green:0.75 blue:0.2 alpha:1].CGColor;
        [self addSubview:av];

        UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(62, 14, 150, 22)];
        title.text = @"✦ 昆哥儿科技 ✦";
        title.textColor = [UIColor colorWithRed:1 green:0.75 blue:0.2 alpha:1];
        title.font = [UIFont boldSystemFontOfSize:15];
        [self addSubview:title];

        UILabel *sub = [[UILabel alloc] initWithFrame:CGRectMake(62, 35, 150, 16)];
        sub.text = @"GLQX · 战斗助手";
        sub.textColor = [UIColor colorWithWhite:1 alpha:0.45];
        sub.font = [UIFont systemFontOfSize:10];
        [self addSubview:sub];

        UIButton *x = [UIButton buttonWithType:UIButtonTypeCustom];
        x.frame = CGRectMake(f.size.width - 42, 12, 30, 30);
        [x setTitle:@"✕" forState:UIControlStateNormal];
        x.titleLabel.font = [UIFont boldSystemFontOfSize:15];
        [x setTitleColor:UIColor.lightGrayColor forState:UIControlStateNormal];
        [x addTarget:self action:@selector(closeTap) forControlEvents:UIControlEventTouchUpInside];
        [self addSubview:x];

        // 3 个开关行
        CGFloat y = 66;
        NSArray *names = @[@"kill", @"inv", @"spd"];
        for (int i = 0; i < 3; i++) {
            UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
            b.frame = CGRectMake(16, y, f.size.width - 32, 42);
            b.backgroundColor = [UIColor colorWithWhite:1 alpha:0.07];
            b.layer.cornerRadius = 10;
            b.titleLabel.font = [UIFont boldSystemFontOfSize:14];
            b.tag = i;
            [b addTarget:self action:@selector(btnTap:) forControlEvents:UIControlEventTouchUpInside];
            [self addSubview:b];
            if (i == 0) { g_btnKill = [[UILabel alloc] initWithFrame:b.bounds]; g_btnKill.textAlignment = NSTextAlignmentCenter; [b addSubview:g_btnKill]; b.userInteractionEnabled = YES; }
            if (i == 1) { g_btnInv = [[UILabel alloc] initWithFrame:b.bounds]; g_btnInv.textAlignment = NSTextAlignmentCenter; [b addSubview:g_btnInv]; }
            if (i == 2) { g_btnSpd = [[UILabel alloc] initWithFrame:b.bounds]; g_btnSpd.textAlignment = NSTextAlignmentCenter; [b addSubview:g_btnSpd]; }
            (void)names;
            y += 50;
        }
        mx_refreshButtons();

        // 面板整体拖动（边界钳制）
        UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(drag:)];
        [self addGestureRecognizer:pan];
    }
    return self;
}
- (void)closeTap {
    [g_panel removeFromSuperview];
    g_panel = nil;
}
- (void)btnTap:(UIButton *)b {
    if (b.tag == 0) g_kill = !g_kill;
    if (b.tag == 1) g_inv = !g_inv;
    if (b.tag == 2) g_spdIdx = (g_spdIdx + 1) % 4;
    mx_refreshButtons();
    sync_flags();
}
- (void)drag:(UIPanGestureRecognizer *)p {
    CGPoint t = [p translationInView:self.superview];
    CGPoint c = self.center;
    c.x += t.x; c.y += t.y;
    [p setTranslation:CGPointZero inView:self.superview];
    CGRect scr = self.superview.bounds;
    c.x = MAX(self.bounds.size.width/2, MIN(scr.size.width - self.bounds.size.width/2, c.x));
    c.y = MAX(self.bounds.size.height/2, MIN(scr.size.height - self.bounds.size.height/2, c.y));
    self.center = c;
}
@end

#pragma mark - 悬浮球/面板挂载（v1.2：直接挂游戏 delegate.window，不建独立 UIWindow）
// v1.0/v1.1 教训：LayaNative 是老式 AppDelegate lifecycle（无 Scene Delegate），自建
// initWithWindowScene: 的 window 挂到 connectedScenes 的 scene 上——图层能显示（球可见）
// 但事件路由不通（球点不了、pointInside 从未被调）。v1.2 直接把球 addSubview 到游戏
// keyWindow 顶层：球仅 58pt 自身响应，其余区域无视图，事件直达游戏，不可能挡屏幕。
static UIView *g_ball = nil;

static UIWindow * mx_game_window(void) {
    UIWindow *w = [UIApplication sharedApplication].delegate.window;
    if (w) return w;
    for (UIScene *s in [UIApplication sharedApplication].connectedScenes) {
        if (![s isKindOfClass:[UIWindowScene class]]) continue;
        UIWindowScene *ws = (UIWindowScene *)s;
        for (UIWindow *ww in ws.windows) if (ww.isKeyWindow) return ww;
        if (ws.windows.count) return ws.windows.firstObject;
    }
    return nil;
}

static UIView * mx_build_ball(void) {
    CGFloat bs = 58;
    UIView *ball = [[UIView alloc] initWithFrame:CGRectMake(0, 0, bs, bs)];
    ball.layer.cornerRadius = bs/2;
    ball.layer.masksToBounds = NO;
    ball.layer.shadowColor = UIColor.blackColor.CGColor;
    ball.layer.shadowOpacity = 0.6;
    ball.layer.shadowRadius = 6;
    ball.layer.shadowOffset = CGSizeMake(0, 2);
    mx_addRainbowRing(ball.layer, 0.88);
    UIImageView *ava = [[UIImageView alloc] initWithFrame:CGRectMake(3, 3, bs-6, bs-6)];
    ava.image = mx_avatar();
    ava.layer.cornerRadius = (bs-6)/2;
    ava.layer.masksToBounds = YES;
    [ball addSubview:ava];
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:ball action:@selector(mx_ballTap:)];
    [ball addGestureRecognizer:tap];
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:ball action:@selector(mx_ballDrag:)];
    [ball addGestureRecognizer:pan];
    objc_setAssociatedObject(ball, "drag", @(1), OBJC_ASSOCIATION_RETAIN);
    return ball;
}

// 确保球挂在游戏 window 顶层；被游戏盖住/换窗时自愈
static void mx_ensure_overlay(void) {
    UIWindow *w = mx_game_window();
    if (!w) { static int s_w = 0; if (++s_w <= 5) mlog(@"game window not ready #%d", s_w); return; }
    BOOL need = NO;
    if (!g_ball) {
        g_ball = mx_build_ball();
        need = YES;
    } else if (g_ball.superview != w) {
        need = YES;
    } else if (w.subviews.lastObject != g_ball) {
        // 游戏在球之后加了视图（盖层）→ 顶到最前
        [w bringSubviewToFront:g_ball];
        static int s_b = 0; if (++s_b <= 5) mlog(@"ball brought to front #%d", s_b);
    }
    if (need) {
        CGFloat bs = 58;
        if (g_ball.frame.size.width < 1) g_ball.frame = CGRectMake(0, 0, bs, bs);
        CGPoint old = g_ball.center;
        CGRect scr = w.bounds;
        if (old.x < 1 && old.y < 1) g_ball.center = CGPointMake(scr.size.width - 57, scr.size.height * 0.42);
        [w addSubview:g_ball];
        [w bringSubviewToFront:g_ball];
        mlog(@"ball attached to game window (%.0fx%.0f) subviews=%lu", scr.size.width, scr.size.height, (unsigned long)w.subviews.count);
    }
    if (g_panel && g_panel.superview == w && w.subviews.lastObject != g_panel)
        [w bringSubviewToFront:g_panel];
}

@implementation UIView (GLQXGestures)
- (void)mx_ballDrag:(UIPanGestureRecognizer *)p {
    UIView *b = self;
    CGPoint t = [p translationInView:b.superview];
    CGPoint c = b.center;
    c.x += t.x; c.y += t.y;
    [p setTranslation:CGPointZero inView:b.superview];
    CGRect scr = b.superview.bounds;
    c.x = MAX(b.bounds.size.width/2, MIN(scr.size.width - b.bounds.size.width/2, c.x));
    c.y = MAX(b.bounds.size.height/2, MIN(scr.size.height - b.bounds.size.height/2, c.y));
    b.center = c;
}
- (void)mx_ballTap:(UITapGestureRecognizer *)p {
    UIWindow *w = self.window;
    if (!w) return;
    if (g_panel) {
        [g_panel removeFromSuperview];
        g_panel = nil;
        return;
    }
    CGFloat pw = 250, ph = 232;
    CGRect scr = w.bounds;
    CGFloat px = self.center.x - pw/2;
    px = MAX(10, MIN(scr.size.width - pw - 10, px));
    CGFloat py = self.center.y + 70;
    py = MAX(10, MIN(scr.size.height - ph - 10, py));
    g_panel = [[MXBox alloc] initWithFrame:CGRectMake(px, py, pw, ph)];
    [w addSubview:g_panel];
    [w bringSubviewToFront:g_panel];
    mlog(@"panel opened at %.0f,%.0f", px, py);
}
@end

#pragma mark - 保活 tick
static void mx_keepalive_tick(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        mx_scan_probe();          // v1.3: 找 JS 探针 → cachePath → flags 同步路径闭环
        mx_ensure_overlay();
        static int s_cnt = 0;
        if (++s_cnt % 15 == 0) sync_flags();   // 30s 周期重写（防文件被清）
    });
}

#pragma mark - ctor
__attribute__((constructor))
static void glqx_ctor(void) {
    mlog(@"ctor: GLQXCheat v1.5 boot (pid=%d)", getpid());
    mx_install_fopen_hook();
    mx_install_hooks();
    sync_flags();
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        mx_ensure_overlay();
    });
    dispatch_source_t t = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_global_queue(0, 0));
    dispatch_source_set_timer(t, DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC, 1 * NSEC_PER_SEC);
    dispatch_source_set_event_handler(t, ^{ mx_keepalive_tick(); });
    dispatch_resume(t);
}
