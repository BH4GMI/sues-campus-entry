#!/usr/bin/env node
/**
 * 对着**手机上真实的 WebView** 执行一段 JS，把结果打出来。
 *
 * 为什么需要它：这个工程里两次严重的 bug（滑轨长度、过期判据优先级）都源于「照着截图和记载猜
 * 页面的结构」。这个工具让「量真实页面」变成一条命令，而不是又一次猜测。
 *
 * 前提：
 *   1. debug 构建（`BuildConfig.DEBUG` 时才会 `WebView.setWebContentsDebuggingEnabled(true)`）；
 *   2. 应用已经打开，目标页面已加载；
 *   3. 端口转发已建好：
 *        adb shell cat /proc/net/unix | grep webview_devtools     ← 拿到 socket 名与 pid
 *        adb forward tcp:9222 localabstract:webview_devtools_remote_<pid>
 *
 * 用法：
 *   node android/tools/cdp-eval.mjs <查询文件.js> [目标序号]
 *
 * 查询文件里写一个表达式，最后 return 一个字符串（用 JSON.stringify 最省事）。
 */
import { readFile } from 'node:fs/promises';

const argv = process.argv.slice(2);
// 两种用法：
//   node cdp-eval.mjs <查询文件.js> [目标序号]      在页面里跑一段 JS
//   node cdp-eval.mjs --cdp <方法名> [参数JSON]     直接发一条 CDP 命令（如 Network.getAllCookies）
const cdpMode = argv[0] === '--cdp';
const file = cdpMode ? null : argv[0];
const indexArg = cdpMode ? undefined : argv[1];
if (!cdpMode && !file) {
    console.error('用法: node cdp-eval.mjs <查询文件.js> [目标序号]');
    console.error('      node cdp-eval.mjs --cdp <方法名> [参数JSON]');
    process.exit(2);
}
const index = Number(indexArg ?? 0);

const response = await fetch('http://127.0.0.1:9222/json/list');
const targets = (await response.json()).filter((t) => t.type === 'page');
if (targets.length === 0) {
    console.error('没有可用的页面目标。应用打开了吗？端口转发建好了吗？');
    process.exit(1);
}
if (process.env.CDP_LIST) {
    targets.forEach((t, i) => console.log(`${i}. ${t.title}  ${t.url}`));
    process.exit(0);
}
const target = targets[index];
if (!target) {
    console.error(`没有第 ${index} 个目标，共 ${targets.length} 个`);
    process.exit(1);
}
console.error(`→ ${target.title}  ${target.url}`);

const socket = new WebSocket(target.webSocketDebuggerUrl);
await new Promise((resolve, reject) => {
    socket.onopen = resolve;
    socket.onerror = reject;
});

const id = 1;
const payload = cdpMode
    ? { id, method: argv[1], params: argv[2] ? JSON.parse(argv[2]) : {} }
    : {
        id,
        method: 'Runtime.evaluate',
        params: { expression: await readFile(file, 'utf8'), returnByValue: true, awaitPromise: true },
    };
socket.send(JSON.stringify(payload));

const message = await new Promise((resolve) => {
    socket.onmessage = (event) => {
        const data = JSON.parse(event.data);
        if (data.id === id) resolve(data);
    };
});
socket.close();

const result = message.result?.result;
if (message.result?.exceptionDetails) {
    console.error('页面里抛错了：', JSON.stringify(message.result.exceptionDetails, null, 2));
    process.exit(1);
}
console.log(typeof result?.value === 'string' ? result.value : JSON.stringify(result?.value, null, 2));
