# glqx-cheat — 古龙群侠录 GLQX 悬浮助手

TrollFools 注入 dylib（arm64，iOS 15+）。功能：**秒杀 / 无敌 / 全局加速**。

## 注入链
1. swizzle `-[conchRuntime update]`（等 5 帧）→ `[self runJS:]` 注入 bootstrap
2. bootstrap wrap `window.loadLib` → `dcc.readFile` 读游戏 bundle → 在 `"use strict";(()=>{` 后插桩 → `window.eval`
3. 插桩代码（bundle IIFE 内）：轮询 `init_BattleCalc()`/`battleCommon` → wrap `BattleCalc.calDamage/calDotDamage`；500ms 读 `glqx_flags.json`（native 面板写入 Documents/Library-Caches/Library-Preferences/tmp 四路）

## 挂点（逆向实证）
- 伤害：`src/sharecode/battle/battleLogic/BattleCalc.ts` 的静态方法（bundle js/bundle-36b0d.js）
- 加速：`battleCommon.battleTimeScale`（战斗时间速率，动画/音效/逻辑帧统一消费）
- 阵营：`hero.playerUserId === battleCommon.leftPlayer.uuid`

## 真机判决点
- Documents/glqx.log：`ctor` → `-[conchRuntime update] hooked` → `bootstrap injected`
- syslog/console：`[GLQX] bootstrap ok` → `loadLib wrapped` → `lib ok js/bundle-...` → `BattleCalc patched, leftPlayer=1`
- 悬浮球出现（头像+彩虹环）→ 点开面板 → 开关后 flags sync 日志

## ⚠️ 风险
- PVP/服务器权威玩法不受客户端 hook 影响；hook 的是本地模拟的回合制战斗计算
- 若游戏重载 JS 上下文，window.__GLQX_INNER 幂等标记失效后 hook 自动重建（calDamage wrap 保存在 patched 类上，类重建则重新轮询 wrap）
