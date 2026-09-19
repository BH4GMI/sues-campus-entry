# SUES 校内系统接入协议（实测）

本文件记录**已实测**的事实，三端（Android / PC / iOS）实现都以此为准。凡未实测的推断都标注
「未验证」。日期：2026-09-19，观测环境：Android 16 / WebView + Python 3.12 / requests。

## 1. 两个入口

| 入口 | 地址 | 说明 |
| --- | --- | --- |
| 教务系统（默认） | `<网关前缀>/student/sso/login` | 免二次登录的支点；换票成功后落 `/student/home` |
| WebVPN 门户 | `https://webvpn.sues.edu.cn` | 资源门户；登录后停在这里 |

## 2. 网关地址与编码（不可写死）

WebVPN 把目标站点改写成同源路径：

```
https://webvpn.sues.edu.cn/https/<编码>/…          目标为 https
https://webvpn.sues.edu.cn/http/<编码>/…           目标为 http
https://webvpn.sues.edu.cn/http-10980/<编码>/…     目标为非标准端口（10980）
```

`<编码>` 由目标**主机 + 端口**决定（实测：`jxfw.sues.edu.cn` 恒为
`77726476706e69737468656265737421faef478b69237d556d468ca88d1b203b`，`jxxt.sues.edu.cn` 是另一串；
同一主机多次请求一致）。它是网关的部署细节，**不得写进代码**——

- 只认形状：`^https?://[^/]+/https/[0-9a-fA-F]+$`（改写到 https 的情形）；
- 值一律从门户读，读不到就回退门户首页，不做猜测。

## 3. 前缀从哪来：门户自己的资源接口

```http
GET https://webvpn.sues.edu.cn/user/portal_groups   （需已登录会话，同源）
```

返回 JSON 数组，每项 `{group:{...}, resource:[...]}`，资源项里：

```json
{
  "name": "新教务系统学生端",
  "detail": "jxfw.sues.edu.cn",
  "url": "https://jxfw.sues.edu.cn/student/home",
  "redirect": "/https/77726476706e69737468656265737421faef478b69237d556d468ca88d1b203b/student/home"
}
```

判据：`detail` 或 `url` 里含 `jxfw.sues.edu.cn` 且 `redirect` 以 `/https/` 开头。取
`redirect.substringBefore("/student/")` 即网关前缀。实测该接口一次就返回完整列表
（20138 字节，含 56 个资源），比等门户前端把卡片渲染进 DOM 确定得多。

兜底判据（接口拿不到时）：门户 DOM 里找文字含 `jxfw.sues.edu.cn` 的 `<a>`，或
「`href` 含 `/https/` 且文字含『教务』」——后者足以把走 `/http/` 的老教务（`jxxt`）排除。

## 4. 为什么不能用门户卡片地址当落点

门户里「新教务系统学生端」卡片指向 `/student/home`。实测（已登录 WebVPN 会话直打）：

```
GET <前缀>/student/home
  302 -> <前缀>/student/login?refer=https://jxfw.sues.edu.cn/student/home
```

`/student/login` 是 jxfw **自己的登录页**（页面标题「登录页面」，正文「账号登录【学生端】」），
要求**二次登录**。而 `/student/sso/login` 走统一身份认证换票，**免二次登录**：

```
GET <前缀>/student/sso/login
  302 -> https://webvpn.sues.edu.cn/https/<cas 编码>/cas/login?service=https%3A%2F%2Fjxfw.sues.edu.cn%2Fstudent%2Fsso%2Flogin
```

（会话有效时 CAS 直接放行，落到 `<前缀>/student/home`；会话失效时才停在认证页。）

## 5. 会话特性（决定了"每次都要重新登录"）

实测 `Set-Cookie`（值已省略）：

| 名称 | 域 | 过期 |
| --- | --- | --- |
| `wengine_vpn_ticketwebvpn_sues_edu_cn` | `.webvpn.sues.edu.cn` | 无 `Expires`（会话 cookie） |
| `route` | `.webvpn.sues.edu.cn` | 无 |
| `show_vpn` / `show_faq` / `wrdvpn_upstream_ip` | `webvpn.sues.edu.cn` | 无 |
| `CASTGC` / `SESSION` / `route` | `cas.sues.edu.cn` | 无 |

**全是会话级 cookie**。Android WebView 不持久化它们，所以进程一结束（冷启动）就要重走一次统一
身份认证。这是"登录辅助"必须存在的原因。

会话失效时的落点（无 cookie 直打任一入口）：

```
GET <前缀>/student/home      -> 302 /login -> 302 <cas前缀>/cas/login?service=https%3A%2F%2Fwebvpn.sues.edu.cn%2Flogin%3Fcas_login%3Dtrue
GET <前缀>/student/sso/login -> 同上
```

即网关把请求弹到统一身份认证页，`service` 是**门户自己的登录**（`/login?cas_login=true`），
不是原来那个深链接。因此登录完成后通常落在门户首页，需要再走一次「读前缀 → SSO」才进教务系统。

## 6. 统一身份认证页（CAS）要素

- 表单字段：`#username`、`#password`、`#rememberMe`、隐藏的 `execution`；
  **密码在滑块之前提交**，RSA 加密由页面 `login.js` 在同一次点击内完成（不轮询密文）。
- **提交与回应都是整页导航**（2026-09-19 PC 端实测：点击「登 录」→ 新文档；滑块验证通过后页面
  自己提交 `fm1` → 新文档；密码错误回应是一张重新渲染的登录页）。因此「哪次提交被否定」的归因
  **不能按文档序号相等判断**——回应本来就是另一份文档。这条事实直接决定 `docs/CORE-SPEC.md` §6.3
  的实现方式（待判决标志）。
- 滑块人机验证：`.ap-container`、拖块 `.ap-bar-ctr`、就绪文案在 `.ap-bar-rect`
  （「加载中……」→「向右拖动滑块拼图」）；两张图以 data-URL 写进 `.ap-slider-bg`（440×240）
  与 `.ap-slider-img`（80×240）；松手时页面按 `parseInt(cursor/slidingScope*scope)` 编码提交到
  `/cas/captcha/validate`，成功后页面自己提交 `fm1` 表单。
  - PC（桌面 UA）实测：**滑块是一份独立文档**（该文档只有滑块、没有 `#username`/`#password`），
    即 CORE-SPEC §5.1 的「滑动登录文档」分支；手机端则是滑块与表单同页。
  - 一次拖动可能落出服务端 ±2 容差（PC 实测遇到一次：缺口 301 第一把提交 301 未过，换图后
    缺口 319 第二把通过）——「同一张图只报一次、最多自动拖 3 次」的重试设计因此是必要的。
- **未绑定滑块身份**：同一份文档里若换图，两张图 data-URL 整串不同——身份比较必须用整串，
  比长度会撞车。
- **密码过期**：部分账号会弹「密码已过期」提示页（正文含 `密码已过期`），处理方式是**点掉
  「点击跳过」**——该按钮的 `onclick` 就是 `document.location.href = document.location.href`，
  也就是重载当前 URL。这条路径**不消耗**账号失败次数，与「密码错误」有本质区别。
  **不要假设按钮的元素类型**：共享浏览器实测登录页的按钮是
  `<input class="login_btn" value="登 录">`，而 `D:\webvpn` 的夹具里写的是
  `<button class="login_btn" onclick="…">点击跳过</button>`。两种都得认，所以按**文字**找
  （`input` 看 `value`，`button` / `a` 看文本），找不到再退到重载当前 URL。
- **判据的优先级**：过期提示的文案**本身就写在 `#msg1` / `.form-error` 容器里**，所以判定时
  必须**先看「正文含 `密码已过期`」，再看那个容器里的提示文本**。反过来的话，通用提示会把过期
  整个挡住——表现是页面上明明写着密码已过期，应用却既不跳过也不提示（本工作区真机上发生过）。
- **密码错误**：服务端返回的仍是登录页，错误文案在 `#msg1`（`name="error_fm1"`）或 `.form-error`
  容器里（`#msg2` / `error_fm2` 是短信表单的）。实测文案：「密码错误。再输错3次，账号将被锁定。」
- 勾选 `#rememberMe`（「记住我」，不是「我已阅读」）后才能起拖。

滑块求解（详见 `CORE-SPEC.md` §5.2）：整幅滑块图作模板、亮度掩码 `299R+587G+114B>12000`、掩码内三通道
ccorr、只搜 1.0 档；服务端容差 ±2px。

拖动换算（详见 `CORE-SPEC.md` §5.3）：页面提交 `parseInt(光标 / 滑轨长度 × 值域)`，其中

- **值域** `= 440 − 80 = 360`（页面里叫 `cutScope` / `data.scope`）
- **滑轨长度** `= 容器渲染宽 − 手柄内容宽 = 330 − 45 = 285`（zoom = 0.75）
- 反解 `光标 = x / 值域 × 滑轨长度`，再枚举附近整数把量化误差压到 ≤ 1px

**这是两个不同的量**：滑轨长度**不是** `值域 × zoom`（那是 270），把两者混起来提交值会变成
`0.947x`（每次都偏短，x 越大偏得越多）。手柄内容宽也不能用 `offsetWidth`（含 1px 边框）。

## 7. 登录结果判定（一律按内容，不按 URL 形态）

| 判定 | 依据 |
| --- | --- |
| 成功 | 页面正文含 `个人信息` / `注销` / `资源站点`（`注销` 只对已登录用户渲染） |
| 密码已过期 | 正文含 `密码已过期` |
| 密码错误 | `#msg1`（或 `.form-error`）文本含 `密码错误` / `密码不正确` / `用户名或密码` / `账号或密码` / `用户不存在` / `账号不存在` / `用户名不存在` |
| 换票中转 | 主机 `webvpn.sues.edu.cn` 且路径以 `/wengine-vpn/failed` 开头，正文「出错啦！该网站无法访问…」——**不代表登录失败** |

**两个反例（实测）**

1. 换票链中间会经过 `https://webvpn.sues.edu.cn/wengine-vpn/failed`，它只是那条跳转自身的落点，
   随后正常落到首页。用 URL 形态判成功/失败会在这里误判。
2. 首页是 Nuxt SPA，`window.__NUXT__.userInfo.username` 是 SSR 初始值，**恒为空串**——浏览器中
   完全登录成功的页面上同样是 `""`，**不可用作判据**。

**剩余尝试次数**：文案句式不固定，匹配所有 `(\d+)\s*次`，再看其前约 12 个字符内是否出现
`再` / `还` / `剩余` / `剩` / `可再` / `尝试` / `输错` / `错误`。实测「密码错误。再输错3次，账号
将被锁定。」→ 剩余 3。取文案要用深度感知的解析（`<br>` / `<hr>` 是 void 元素，不改变嵌套深度），
不要用非贪婪正则（嵌套标签会提前截断，整容器取文本会混入同容器里的 `swiSpan*` 空节点）。

**服务端累计失败次数，5 次锁号**。因此密码错误必须立即停手、不得重试；解析到剩余次数 **≤ 1** 时
应硬性阻断重试路径。这条约束直接决定了凭据的处置方式（见 `CORE-SPEC.md` §6）。

> 本节事实取自用户既有工程 `D:\webvpn` 的实测记载（`TECHNICAL_REPORT.md` §3.7 / §4 / §6.4、
> `sudy_html.py`、`test_login_flow.py`）。本工作区**此前把「点击跳过」记成了
> `input.login_btn[value=点击跳过]`，与实测形态不符**，已按上面的更正改掉——代码当时是忠实实现了
> 这条错的事实，根因在文档这一层。

## 8. 与「导入课表」的边界

本协议只描述**打开这两个系统**所需的东西。课表接口
（`/student/for-std/course-table/get-data`）与 `.wakeup_schedule` 格式属于课钟项目的导入链路，
不在本工作区范围内。

## 9. 教务系统首屏的公告弹窗（实测）

2026-09-19 量于**真机 WebView**（远程调试）与**电脑浏览器**两处，两处结构一致。

进入 `/student/home` 后，站点会弹出一个**全屏模态公告窗**：

```
div.el-dialog__wrapper.notice-dialog          1300 × 2501（实测），铺满视口
  div.el-dialog
    div.el-dialog__header
      span.el-dialog__title                   ← 文字为空
      <!---->                                 ← 关闭按钮的槽位被注释掉：showClose = false
    div.el-dialog__body
      div.alert-notice
        div.alert-notice-item × 19            ← 每条公告一张卡片
          div.notice-public                   ← 「通知公告」角标
          div.alert-notice-content
          div.alert-notice-title
          div.alert-notice-time               ← 「发布时间：…」
          div.alert-to-read                   ← 「点击阅读」
```

同时，站点给 `body` 加上滚动锁 `el-popup-parent--hidden`，并显示遮罩层 `.v-modal`（display: block）。

**关键事实**：

- 这 19 张卡片**不在页面正文里**，而在这个弹窗里。按「找卡片 → 隐藏卡片容器」的做法会隐藏弹窗的内容，
  留下空弹窗 + 遮罩 + 滚动锁，用户看到的是**整页空白**。（上一版就是这么错的。）
- **站点没有给这个弹窗任何关闭入口**：`el-dialog__headerbtn` 不存在、没有 `.el-dialog__footer`，
  实测点遮罩、点弹窗外区域都不关。它是一扇只能靠切页离开的门。
- 因此「去掉它」只能是**整层摘掉**：`.el-dialog__wrapper.notice-dialog` + `.v-modal` +
  `body.el-popup-parent--hidden`，三者一起处理；原值记在元素属性上以便原样还原。
- 弹窗是前端渲染的，出现时机**晚于** `onPageFinished`（实测第一次注入时它还不在 DOM 里），
  必须靠 `MutationObserver` 盯着重渲染，并且**每次真的动手都要留日志**——
  否则会出现「日志说没找到、页面其实已经被改」这种情况。
- 页面上另有一套 **Bootstrap 风格**的模态（`div.modal.fade > .modal-content > .modal-footer`，
  带「我已阅读 / 关闭 / 确定」按钮），与公告弹窗无关，别混淆。
