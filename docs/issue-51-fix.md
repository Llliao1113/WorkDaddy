# Issue #51 修复：升级死锁自愈

## 根因

`apply-update.ps1` 的早期校验（权限/boundary/路径）位于日志初始化与主 `try/finally` **之前**，失败时静默退出：`apply.log` 不存在、`pending.json` 残留 → watchdog 检测到标记后**永久拒绝**重启 daemon → 应用卡在「启动较慢」。

触发条件：1.1.1 装在非默认目录（如 D 盘），daemon 认定路径与脚本实际位置不一致，路径校验 throw。

## 改动（2 个文件）

### `scripts/apply-update.ps1`

1. **权限探针**保留在目录创建前（`windows-powershell-boundary` 契约要求），但失败时不再 `exit 5`，改为记录 `$privilegeError` 变量，延后到主 try 内 throw（此时 transcript 已启动 → 有日志）。
2. **boundary 加载 + 路径检查**移入主 try：失败会写入 `apply.log` 并由 finally 清理 `pending.json`。
3. **finally 无条件清理** `pending.json`，移除 `$lifecycleValidated` 门控（原门控导致「停止 watchdog 之前」的失败跳过清理）。

### `scripts/watchdog.js`

1. 新增 `schedulePendingRecheck()`：跳过 daemon 重启时启动 15s 复查定时器。
2. 标记被 apply 脚本删除、或宽限期满被 `updatePendingIsActive()` 清理后，**自动重新拉起 daemon**——形成自愈闭环。
3. `shutdown()` 清理定时器，避免泄漏。

原实现：watchdog 检查一次 `pending.json` → 标记存在 → `return`，从此再无人复查。`updatePendingIsActive()` 内置的 10 分钟宽限清理是**死代码**。

## 测试

### 运行测试

```bash
# 在仓库根目录
node --test test/update-deadlock-recovery.test.js

# Windows 上还需确认现有契约测试未被破坏
node --test test/windows-powershell-boundary.test.js
node --test test/windows-privilege-boundary.test.js
```

### 测试覆盖（5 个）

| # | 测试 | 类型 | 验证 |
|---|------|------|------|
| 1 | early validation lives inside main try | 静态 | boundary 加载与路径检查在 `Write-ApplyLog "start"` 之后；权限失败的 `if ($privilegeError)` throw 也在 start 之后（transcript 已启动） |
| 2 | finally clears pending.json unconditionally | 静态 | finally 块清理 `pending.json` 不被 `if` 门控，无 `$lifecycleValidated` |
| 3 | schedulePendingRecheck provides self-healing loop | 静态 | watchdog 定义 `schedulePendingRecheck`，函数体复查 `updatePendingIsActive` 并调 `startDaemon`，shutdown 清理定时器 |
| 4 | path-mismatch failure writes apply.log and clears pending.json | Windows 行为 | 精确复现 issue #51 场景（路径不一致 throw），验证 `apply.log` 已生成 + `pending.json` 已删除 |
| 5 | missing-package failure still clears pending.json | Windows 行为 | 中期失败（包不存在）也清 `pending.json`（原 `lifecycleValidated` 门控会跳过） |

### 手动端到端验证（可选）

1. 在测试环境装 1.1.1 到非默认目录（如 D 盘）
2. 触发升级到 1.1.2（让 daemon spawn apply-update.ps1）
3. 预期：`apply.log` 存在且记录路径不一致错误，`pending.json` 被清理，watchdog 15s 内自动拉起 daemon
4. 确认 GUI 不再卡「启动较慢」

## 提 PR

```bash
git push origin fix/update-deadlock-recovery
gh pr create --title "fix(update): prevent upgrade deadlock on non-default install path (#51)" \
  --body "See test/update-deadlock-recovery.test.js for the deadlock contract and regression coverage."
```
