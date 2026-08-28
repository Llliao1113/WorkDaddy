'use strict';

/**
 * 升级死锁自愈契约测试（issue #51）
 *
 * 验证 apply-update.ps1 + watchdog.js 的防死锁加固：
 *   1. apply-update.ps1 的早期校验（权限/boundary/路径）必须位于主 try 内、
 *      在 Write-ApplyLog "start" 之后；任何早期失败都会留下 apply.log。
 *   2. apply-update.ps1 的 finally 块必须无条件清理 pending.json
 *      （不再受 lifecycleValidated 门控，否则早期失败会残留标记）。
 *   3. watchdog.js 在跳过 daemon 重启时必须启动 pendingRecheckTimer 持续复查，
 *      标记被清除后自动重新拉起 daemon（原实现的 10 分钟宽限清理是死代码）。
 *   4. （Windows 行为测试）路径不一致触发 throw 后，apply.log 已生成且
 *      pending.json 已被清理——这是 issue #51 死锁的精确复现与回归保护。
 */
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const test = require('node:test');

const repoRoot = path.join(__dirname, '..');
const scriptsDir = path.join(repoRoot, 'scripts');
const applyScriptPath = path.join(scriptsDir, 'apply-update.ps1');
const watchdogScriptPath = path.join(scriptsDir, 'watchdog.js');
const applySource = fs.readFileSync(applyScriptPath, 'utf8');
const watchdogSource = fs.readFileSync(watchdogScriptPath, 'utf8');

// ---- 静态契约：apply-update.ps1 ----

test('apply-update.ps1: early validation lives inside main try, after start log', () => {
  const startIdx = applySource.indexOf('Write-ApplyLog "start attempt=');
  assert.ok(startIdx >= 0, 'missing "start attempt" log line');

  const tryIdx = applySource.lastIndexOf('try {', startIdx);
  assert.ok(tryIdx >= 0 && tryIdx < startIdx, '"start" log must be inside main try');

  // boundary 加载与路径检查必须在 start log 之后（修复前在前面，崩溃无日志 → issue #51）
  for (const marker of ['windows-process-boundary.ps1', '更新脚本位置与目标安装目录不一致']) {
    const idx = applySource.indexOf(marker);
    assert.ok(idx > startIdx, `${marker} must appear after "start" log (was before, caused silent deadlock)`);
  }

  // 权限探针的 IsInRole 可在 start log 之前（windows-powershell-boundary 契约要求探针在副作用前），
  // 但失败的 throw 必须在 start log 之后，确保 transcript 已启动 → 有日志
  const privilegeThrow = applySource.indexOf('if ($privilegeError)');
  assert.ok(privilegeThrow > startIdx, 'privilege failure throw must be after start log (so transcript captures it)');
});

test('apply-update.ps1: finally clears pending.json unconditionally (no lifecycleValidated gate)', () => {
  const finallyIdx = applySource.lastIndexOf('} finally {');
  assert.ok(finallyIdx >= 0, 'missing finally block');
  const finallyBlock = applySource.slice(finallyIdx);

  // pending.json 清理必须在 finally 内
  assert.ok(/Remove-Item.*pending\.json/.test(finallyBlock), 'finally must remove pending.json');

  // finally 块内不得出现 $lifecycleValidated 门控（原实现用它跳过早期失败的清理）
  // 注：注释中解释「为何移除」时会提到该词，因此只检查实际的 if 门控结构
  assert.ok(!/if\s*\([^)]*\$lifecycleValidated/i.test(finallyBlock), 'finally must not gate cleanup on $lifecycleValidated');

  // pending.json 清理行本身不得被 if 包裹
  const cleanupLine = finallyBlock
    .split('\n')
    .find((l) => /pending\.json/.test(l) && /Remove-Item/.test(l));
  assert.ok(cleanupLine, 'must find pending.json cleanup line in finally');
  assert.ok(!/if\s*\(/.test(cleanupLine), 'pending.json cleanup must not be gated by if');
});

// ---- 静态契约：watchdog.js ----

test('watchdog: schedulePendingRecheck provides self-healing loop', () => {
  assert.ok(/function schedulePendingRecheck\(\)/.test(watchdogSource), 'must define schedulePendingRecheck');

  // 跳过 daemon 重启时必须调度复查
  const skipIdx = watchdogSource.indexOf('跳过自动重启 daemon');
  assert.ok(skipIdx >= 0, 'must have skip-restart log line');
  const scheduleCallIdx = watchdogSource.indexOf('schedulePendingRecheck();', skipIdx);
  assert.ok(scheduleCallIdx > 0, 'must call schedulePendingRecheck when skipping daemon restart');

  // schedulePendingRecheck 函数体内必须复查 pending，标记清除后重新拉起 daemon
  const fnDefIdx = watchdogSource.indexOf('function schedulePendingRecheck()');
  const fnBody = watchdogSource.slice(fnDefIdx, watchdogSource.indexOf('\n}', fnDefIdx) + 2);
  assert.ok(/updatePendingIsActive\(\)/.test(fnBody), 'schedulePendingRecheck body must re-check pending via updatePendingIsActive');
  assert.ok(/startDaemon\(\)/.test(fnBody), 'schedulePendingRecheck body must re-pull daemon after marker clears');
  assert.ok(/重新拉起 daemon/.test(fnBody), 'must log self-healing action');

  // shutdown 时清理定时器，避免泄漏
  assert.ok(/clearInterval\(pendingRecheckTimer\)/.test(watchdogSource), 'must clear pendingRecheckTimer on shutdown');
});

// ---- Windows 行为测试：精确复现 issue #51 死锁场景并验证自愈 ----

test('apply-update.ps1: path-mismatch failure writes apply.log and clears pending.json', { skip: process.platform !== 'win32' }, () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'workdaddy-deadlock-'));
  // 脚本实际所在位置（模拟非标准安装目录）
  const runScriptsDir = path.join(dir, 'runScripts');
  // 目标安装目录的 scripts（与脚本位置不一致 → 触发路径校验 throw）
  const fakeAppDir = path.join(dir, 'fakeApp');
  fs.mkdirSync(runScriptsDir, { recursive: true });
  fs.mkdirSync(fakeAppDir, { recursive: true });

  // 复制脚本与 boundary 到「脚本位置」（apply-update.ps1 用 $PSScriptRoot 加载 boundary）
  fs.copyFileSync(applyScriptPath, path.join(runScriptsDir, 'apply-update.ps1'));
  fs.copyFileSync(
    path.join(scriptsDir, 'windows-process-boundary.ps1'),
    path.join(runScriptsDir, 'windows-process-boundary.ps1'),
  );

  // 隔离 APPDATA：pending.json / apply.log 都基于它
  const appData = path.join(dir, 'AppData', 'Roaming');
  const localAppData = path.join(dir, 'AppData', 'Local');
  const updateDir = path.join(appData, 'WorkDaddy', 'update');
  fs.mkdirSync(updateDir, { recursive: true });

  // 预置 pending.json（模拟 daemon 已退出、apply 启动前的死锁起点）
  const attemptId = 'test-' + Date.now();
  fs.writeFileSync(
    path.join(updateDir, 'pending.json'),
    JSON.stringify({ at: new Date().toISOString(), attempt: attemptId }),
  );
  fs.writeFileSync(
    path.join(updateDir, 'last-attempt.json'),
    JSON.stringify({ attemptId, scriptPid: 999999 }),
  );

  // 运行 apply-update.ps1：AppDir 与脚本位置不一致 → 路径校验 throw
  // 修复前：throw 在 transcript/finally 之前 → apply.log 不存在 + pending.json 残留
  // 修复后：throw 在主 try 内 → apply.log 已有 "start" 行 + finally 清 pending.json
  const result = spawnSync(
    'powershell',
    [
      '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
      '-File', path.join(runScriptsDir, 'apply-update.ps1'),
      '-SrcPackage', path.join(dir, 'nonexistent.zip'),
      '-AppDir', fakeAppDir,
      '-AttemptId', attemptId,
      '-Port', '47832',
    ],
    {
      encoding: 'utf8',
      env: { ...process.env, APPDATA: appData, LOCALAPPDATA: localAppData, CI: '1' },
      timeout: 30000,
      windowsHide: true,
    },
  );

  // 预期：非零退出（路径校验 throw → catch → exit 1）
  assert.ok(result.status !== 0, `expected non-zero exit, got ${result.status}. stderr: ${result.stderr}`);

  // 契约 1：apply.log 必须存在（修复前不存在 → 无从排查 → issue #51 根因）
  const applyLog = path.join(updateDir, 'apply.log');
  assert.ok(fs.existsSync(applyLog), 'apply.log must exist after early failure (was missing before fix)');
  const logContent = fs.readFileSync(applyLog, 'utf8');
  assert.ok(/start attempt=/.test(logContent), `apply.log must contain start line: ${logContent}`);

  // 契约 2：pending.json 必须被清理（修复前残留 → watchdog 永不拉起 daemon → 死锁）
  assert.ok(
    !fs.existsSync(path.join(updateDir, 'pending.json')),
    'pending.json must be cleaned up after early failure (was leaving deadlock marker before fix)',
  );

  // 清理
  try { fs.rmSync(dir, { recursive: true, force: true }); } catch (_) {}
});

test('apply-update.ps1: missing-package failure still clears pending.json', { skip: process.platform !== 'win32' }, () => {
  // 与路径不一致测试互补：路径校验通过（脚本位置 = AppDir/scripts），但包不存在
  // 验证「停止 watchdog 之前」的中期失败也清 pending（修复前 lifecycleValidated 门控跳过清理）
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'workdaddy-missing-pkg-'));
  const appDir = path.join(dir, 'app');           // 真实安装目录
  const runScriptsDir = path.join(appDir, 'scripts'); // 脚本位置 = AppDir/scripts（路径一致）
  fs.mkdirSync(runScriptsDir, { recursive: true });

  fs.copyFileSync(applyScriptPath, path.join(runScriptsDir, 'apply-update.ps1'));
  fs.copyFileSync(
    path.join(scriptsDir, 'windows-process-boundary.ps1'),
    path.join(runScriptsDir, 'windows-process-boundary.ps1'),
  );

  const appData = path.join(dir, 'AppData', 'Roaming');
  const localAppData = path.join(dir, 'AppData', 'Local');
  const updateDir = path.join(appData, 'WorkDaddy', 'update');
  fs.mkdirSync(updateDir, { recursive: true });

  const attemptId = 'test-missing-' + Date.now();
  fs.writeFileSync(path.join(updateDir, 'pending.json'), JSON.stringify({ at: new Date().toISOString(), attempt: attemptId }));
  fs.writeFileSync(path.join(updateDir, 'last-attempt.json'), JSON.stringify({ attemptId, scriptPid: 999999 }));

  const result = spawnSync(
    'powershell',
    [
      '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
      '-File', path.join(runScriptsDir, 'apply-update.ps1'),
      '-SrcPackage', path.join(dir, 'definitely-missing.zip'),  // 包不存在 → 路径校验通过后 throw
      '-AppDir', appDir,  // 路径一致（脚本在 AppDir/scripts）
      '-AttemptId', attemptId,
      '-Port', '47832',
    ],
    {
      encoding: 'utf8',
      env: { ...process.env, APPDATA: appData, LOCALAPPDATA: localAppData, CI: '1' },
      timeout: 30000,
      windowsHide: true,
    },
  );

  assert.ok(result.status !== 0, `expected non-zero exit, got ${result.status}`);

  // apply.log 存在 + pending.json 被清（修复前 lifecycleValidated=false 时 finally 跳过清理）
  assert.ok(fs.existsSync(path.join(updateDir, 'apply.log')), 'apply.log must exist after missing-package failure');
  assert.ok(
    !fs.existsSync(path.join(updateDir, 'pending.json')),
    'pending.json must be cleared even when failure happens before watchdog stop (lifecycleValidated gate removed)',
  );

  try { fs.rmSync(dir, { recursive: true, force: true }); } catch (_) {}
});
