# 自制OCR查词

菜单栏常驻的截图取词工具。按快捷键框选屏幕任意区域 → OCR → 判断语种 → 打开对应词典。
是原来那条快捷指令的原生实现版。

## 用法

两个输入源（截图 OCR / 读选中文字）× 三种动作（查词 / 转文字 / 扫码）：

| 快捷键 | 输入源 | 动作 |
|---|---|---|
| `⌃⌥9` | 框选截图 + OCR | 查词，自动判语种 |
| `⌘⌥0` | 框选截图 + OCR | **智能拼行后只放剪贴板**，不查词 |
| `⌘⌥8` | 框选截图 | **识别二维码/条码**，是网址就用默认浏览器打开 |
| `⌘⌥D` | 当前选中的文字 | 查词，自动判语种 |
| `⌘⌥N` | 当前选中的文字 | 查词 → Naver 韩中 |
| `⌘⌥P` | 当前选中的文字 | 查词 → Papago |
| `⌘⌥G` | 当前选中的文字 | 查词 → 谷歌翻译 |
| `⌘⌥Y` | 当前选中的文字 | 查词 → 有道 |

**截图取词**管图片、PDF 扫描件、视频字幕这些选不中的字；**划词取词**管能选中的文本，没有 OCR 误差、也不用框选，更快。

| 其他操作 | 说明 |
|---|---|
| 框选时按 esc | 取消截图 |
| `⌘1`…`⌘9` | 在结果窗口切换词典（`⌘5` 是 AI 释义，会跳浏览器） |
| `⌘L` | 聚焦词条输入框，改完按回车重查（OCR 认错字时用） |
| `esc` / `⌘W` | 关闭结果窗口 |
| 罗盘按钮 | 把当前查询丢到默认浏览器 |
| 图钉按钮 | 常驻置顶。不按的话窗口只在弹出时浮在最上面，你一点别的窗口它就自动沉下去 |

**记不住快捷键就按 `⌘?`**，或菜单栏 →「使用说明」。那份说明是**按当前配置实时生成**的，
改了快捷键或加了词典它会跟着变，不会出现文档和实际对不上的情况。

菜单栏图标里有：三个取词入口、快捷键设置、使用说明、编辑配置、重新载入配置、
清除浏览数据、开机自动启动、权限与识别语言自检。

## 改快捷键

菜单栏 →「**快捷键设置**」：点按键框进入录制，直接按下想要的组合（至少带一个修饰键，esc 取消）。
每行还能改取字方式（截图/划词）、动作（查词/转文字/扫码）、目标词典，也能增删。

几个实现上的细节：

- **打开设置窗口时会临时注销所有全局热键** —— 否则你按 ⌃⌥9 想录制，结果直接触发了截图。关窗时恢复。
- **保存时当场重新注册**，被别的程序占用的组合会立刻标红，而不是等你按下去才发现没反应。
- **不允许不带修饰键的组合** —— 那会把普通打字也吞掉。
- 同一个组合用两次会被拦下。

## 安装

```bash
./build.sh install
```

编译 → 组装 `.app` → 本地签名 → 装到 `/Applications` 并启动。
只想构建不安装就跑 `./build.sh`，产物在 `build/`。

**需要两个权限**，都在 系统设置 → 隐私与安全性 里勾选「自制OCR查词」，**勾完要重启这个 App**（macOS 的权限要重启进程才生效）：

| 权限 | 用途 | 不给会怎样 |
|---|---|---|
| 屏幕录制 | `screencapture` 框选截图 | 截图取词失败 |
| 辅助功能 | 读取其他 App 里选中的文字 | 划词取词失败 |

第一次按对应快捷键时会自动弹系统提示。菜单里的「权限与识别语言自检」可随时确认状态，
也可以跑 `自制OCR查词.app/Contents/MacOS/OCRDict --diag` 在终端里看。

> 每次 `./build.sh install` 重新编译后，App 的签名指纹会变，系统可能要求重新勾选一次屏幕录制权限。这是 macOS 对本地签名 App 的既定行为，不是 bug。

## 配置

`~/Library/Application Support/OCRDict/config.json`，改完在菜单里点「重新载入配置」即可生效，不用重启。

```jsonc
{
  // 每条绑定 = 按键 + 修饰键 + 输入源 + 目标词典
  //   key        写键名即可（"9" "N" "F5" "space"），也可以用 keyCode 写虚拟键码
  //   source     "screenshot"（框选 OCR）或 "selection"（读选中文字）
  //   dictionary "auto"（按语种自动选）或某个词典的 id
  //   action     "lookup"（默认，查词）/ "clipboard"（拼行后复制）/ "qrcode"（扫码）
  "hotkeys": [
    { "key": "9", "control": true, "option": true, "source": "screenshot", "dictionary": "auto" },
    { "key": "0", "command": true, "option": true, "source": "screenshot", "action": "clipboard" },
    { "key": "8", "command": true, "option": true, "source": "screenshot", "action": "qrcode" },
    { "key": "D", "command": true, "option": true, "source": "selection",  "dictionary": "auto" },
    { "key": "N", "command": true, "option": true, "source": "selection",  "dictionary": "naver" },
    { "key": "P", "command": true, "option": true, "source": "selection",  "dictionary": "papago" },
    { "key": "G", "command": true, "option": true, "source": "selection",  "dictionary": "gtrans" },
    { "key": "Y", "command": true, "option": true, "source": "selection",  "dictionary": "youdao" }
  ],

  // 让 Vision 自动挑识别模型。建议保持 true —— 见下面「为什么必须开自动识别」
  "autoDetectLanguage": true,
  // 语言提示；自动识别落空时会拿这个列表逐个重试
  "ocrLanguages": ["en-US", "ko-KR", "it-IT", "zh-Hans", "ja-JP"],

  // 拉丁字母判不准时回落到哪个语言
  "defaultLatinLanguage": "en",
  // 低于这个置信度就认为判定不可靠，语种标签会变橙色加问号
  "latinConfidenceThreshold": 0.65,

  // true: 连续空白折叠成一个空格（词组安全）；false: 全部删掉
  "collapseWhitespaceToSpace": true,
  // true: 所有词典都不弹内置窗口，一律丢给默认浏览器
  "openInBrowser": false,
  // true = 窗口一直置顶（等于图钉默认按下）。false 时按弹出/失焦自动升降，见下文
  "alwaysOnTop": false,
  // 退出时清空内嵌 WebView 的 Cookie / localStorage / 缓存
  "clearDataOnQuit": true,
  // 二维码里的链接打开前先弹窗确认（二维码肉眼读不出来，想稳一点就开）
  "qrConfirmBeforeOpen": false,

  "windowWidth": 900,
  "windowHeight": 680,

  "dictionaries": [
    { "id": "naver",  "name": "Naver 韩中", "languages": ["ko"], "url": "https://zh.dict.naver.com/#/search?query={q}" },
    { "id": "youdao", "name": "有道",       "languages": ["en"], "url": "https://www.youdao.com/result?lang=en&word={q}" },
    { "id": "yihan",  "name": "意汉",       "languages": ["it"], "url": "https://www.yihan.it/{q}" },
    { "id": "google", "name": "Google",     "languages": ["*"],  "url": "https://www.google.com/search?q={q}", "suffix": " 中文意思" },
    { "id": "googleai", "name": "AI 释义", "languages": [], "external": true,
      "url": "https://www.google.com/search?q={q}&udm=50",
      "suffix": " 这个词是什么意思？请用中文说明词义、词性、常见搭配，并给两个例句。" }
  ]
}
```

- `{q}`：URL 编码后的查询词
- `suffix`：编码**之前**拼到词后面的内容
- `languages`：命中的语言代码，`"*"` 是兜底，**空数组 `[]` 表示永不自动命中、只能手动切过去**
- `external`：`true` = 用系统默认浏览器打开，不在内嵌 WebView 里加载。这类标签在按钮上带 `↗` 标记
- 词典的顺序就是结果窗口里按钮的顺序，也决定了 `⌘1`…`⌘9` 的编号

## 隐私与查询记录

**本 App 自身不记录任何查询历史** —— 源码里唯一的写文件操作是配置文件，日志只记错误不含查询词，
框选的截图写到临时目录后用 `defer` 立即删除（`ScreenCapture.swift`）。

**但内嵌 WebView 会落盘**。WKWebView 默认用持久化存储，词典网站会往 localStorage 里塞自己的「最近搜索」
（实测有道有 `historyList` 键），加上缓存，两三天就能涨到 100MB+：

```
~/Library/WebKit/com.poterus.ocrdict/    Cookie、localStorage、ServiceWorker
~/Library/Caches/com.poterus.ocrdict/    网页缓存
```

所以默认**退出时自动清空**（`clearDataOnQuit: true`）。菜单栏里另有「清除浏览数据」可随时手动清，
标题上直接显示当前占用了多少。实测 130MB → 0.9MB，剩下的是空的数据库外壳，无 localStorage、无 Cookie。

> 注意：自动清除依赖 `applicationWillTerminate`，走菜单「退出」或 ⌘Q 才会触发。
> 被 `kill -9` 强杀不会执行，那种情况下手动点一次「清除浏览数据」即可。

跳浏览器的 `external` 词典（比如 `⌘5` AI 释义）走的是你自己的浏览器，记录归浏览器管，本 App 管不着。

## 窗口层级

不是简单的「置顶 / 不置顶」二选一，而是跟着焦点走：

- **弹出瞬间**抬到 `.floating`，压在所有窗口之上。这一步是必须的——本 App 是 `LSUIElement` 类型，
  macOS 26 下 `NSApp.activate()` 抢不到前台，只用普通层级的话窗口会开在别的窗口后面，等于没弹出来。
- **一旦失去焦点**（你点了别的窗口 / ⌘Tab 切走）立刻沉回 `.normal`，不再挡路。
- **按下图钉**则一直保持 `.floating`，适合一边查一边抄写。`alwaysOnTop: true` 等于默认按下图钉。

## 关于 AI 查询

`AI 释义`（`⌘5`）指向 Google AI 模式（`&udm=50`），并且标了 `external: true`，所以是**跳系统默认浏览器**打开。

这不是偷懒，是必须的：**AI 模式依赖 Google 账号登录态，而内嵌 WebView 有独立于浏览器的 Cookie 空间**。
实测把 `udm=50` 直接丢进悬浮窗，页面会降级成普通搜索结果，连「AI 模式」标签都不出现。
想靠「在窗口里登录 Google」绕过也走不通——Google 从 2016 年起就屏蔽了嵌入式 WebView 的账号登录。
跳到浏览器就用上了你已有的登录态，AI 模式正常工作。

`suffix` 就是提问模板，想换问法（加「词源」「近义词辨析」「敬语等级」「动词变位」之类）直接改这一行，不用动代码。

> 用的是**系统默认浏览器**。如果你的 Google 只在某个特定浏览器里登录了，把那个设成默认浏览器即可。

同理，任何依赖登录态的站点（ChatGPT、Claude、各家 AI）都可以照这个模式加，只要标上 `external: true`。

加一个新词典只要往 `dictionaries` 里多写一项。比如加德语 Pons：

```json
{ "id": "pons", "name": "Pons 德汉", "languages": ["de"], "url": "https://zh.pons.com/翻译/德语-中文/{q}" }
```

手改配置时快捷键直接写 `"key": "N"` 就行，不用查键码表；少数没名字的键才需要 `"keyCode": 25`。
不过一般用不着手改——菜单栏「快捷键设置」里录制更省事。

## 截图转文字（⌘⌥0）：断词是怎么还原的

OCR 出来的是一行一行的，一个词被换行切成两半时，直接拼会变成 `그리 움은` 或 `inter national`。
这件事没有一个 API 能直接解决，得组合三种信号（实现在 `LineJoiner.swift`）：

| 信号 | 作用 | 可靠度 |
|---|---|---|
| **连字符** | 拉丁文 `inter-\nnational` → 去掉连字符直接连 | 确定 |
| **系统词典**（`DCSCopyTextDefinition`） | 把两半拼起来，看最长成词前缀有没有**越过接缝** | 高 |
| **几何**（Vision 给的每行 bounding box） | 这行是顶满右边缘（被挤断的）还是空出一截（自然结束） | 高 |
| **词尾表** | 行首是不是悬空的韩语助词/变位词尾 | 中 |

### 词典判据是怎么工作的

`이` + `성적인` → 拼成 `이성적인`，词典里查到 **`이성적`**，长度 3 > 上一行末尾的 1 → 越过接缝 → 判定断词。
`조용히` + `머물러` → 查不到任何跨接缝的词 → 本来就是两个词。

macOS 装了韩语词典（새국어사전），`DCSCopyTextDefinition` 对韩语有效，单次判定 0.1ms。
依赖「词典」App 里启用了韩语词典；没启用时这条判据恒为假，退化成纯启发式，不会出错。

### 几点实测结论，都是撞过墙才定下来的

- **系统的韩语拼写检查用不了** —— `그리느끼는`、`걷는길에서` 这种随便拼的它都判成词，只查谚文音节合法性。
- **NaturalLanguage 的韩语分词器也不做形态素切分** —— 只按空格切，`느끼는그리움` 原样返回一个 token。
- **几何能分辨「换行」和「段落结束」，但分辨不了顶满的行里断点落在空格还是词中间** ——
  CJK 默认允许在任意两字之间断行，两种情况的像素表现完全一样。
- **顶满的韩语行默认加空格**。试过反过来（默认不加），准确率从 28/33 掉到 21/33 —— 断点落在词边界仍是多数。
- **单音节碎片规则要用词典把关**。`할 | 때` 两边都是正经词，光看「上一行结尾是单音节」会误连成 `할때`。

### 有一类情况本地判不了，所以只标不猜

`이성적인`（理性的）和 `이 성적인`（这个性方面的）**都是合法的韩语**。断行正好落在中间时，
两种读法在本地没有任何信号能分辨：

- 几何？空格被换行吃掉了，像素上不存在
- 词典？两种读法的词都在词典里
- 语法？`이`（这）+ `성적인`（…性的）+ 名词 是合语法的

只有语义和上下文能判，那需要语言模型，本地没有。

所以做法是：**默认合并**（`이성적인` 这类合起来的用法频率高得多），但把这种「合了、可拆开也讲得通」的地方
**报出来**——⌃⌥0 之后的提示里会列出具体位置：

```
已复制 87 字
뇌 과학자들의 설명에 의하면 이성적인 힘이…

⚠️ 这些地方合并了，但拆开写也讲得通：
이성적인
```

判定条件是「由词典判据促成合并，且上半截本身也成词」。助词表和单音节碎片那些不报——
黏着语素不可能独立成词，那些是确定的。实测每段文本报 0~1 处，不会变成噪音。

### 准确率

6 段韩语 + 英语 + 意大利语、多种栏宽（含强制逐字断行）共 **47 个用例，通过 45 个**。两个失败：

- 一个是 **OCR 自己漏读了句尾的句号**，与拼行无关
- 一个是 `의존 명사` —— `의존명사` 本身就是词典词条，而正字法要求分写，**这是真歧义**

结果直接进剪贴板而不是自作主张替你改文档，粘贴前扫一眼。

自己验证：

```bash
/Applications/自制OCR查词.app/Contents/MacOS/OCRDict --join 某张图.png
```

## 扫二维码（⌘⌥8）

框选包含二维码的区域，用 Vision 的 `VNDetectBarcodesRequest` 识别。除了二维码也认 Aztec、DataMatrix、
PDF417、EAN、Code128 等一维码，扫商品条码不用换快捷键。

- 载荷是 **http/https 链接** → 用系统默认浏览器打开，HUD 里亮出实际打开的域名
- 载荷是**别的东西**（`WIFI:`、`mailto:`、纯文本）→ 不打开，直接复制到剪贴板

二维码肉眼读不出内容，扫到什么网址事先不知道。介意的话把 `qrConfirmBeforeOpen` 设成 `true`，
打开前会弹窗显示完整网址，可以选「打开 / 只复制 / 取消」。

```bash
/Applications/自制OCR查词.app/Contents/MacOS/OCRDict --qr 某张图.png
```

## 划词取词是怎么读到文字的

两条路，先试第一条，拿不到再回落：

1. **Accessibility API 直接读 `kAXSelectedText`** —— 不碰剪贴板、无固定延迟。
2. **模拟 ⌘C 再读剪贴板** —— 兼容性更好（Chrome 未开 `AXManualAccessibility` 时、部分 Electron App），
   代价是短暂占用剪贴板。读完**立刻**原样还原，而且整条剪贴板（含图片、富文本）都存下来再恢复，
   不是只存纯文本——否则会把你剪贴板里的图片弄丢。

> 如果之前用的是 Hammerspoon 那套 `⌘C` + `hs.timer.doAfter(1.0)` 还原的写法，注意那 1 秒空窗期内
> 按 ⌘V 粘出来的是刚查的词。这里没有那个窗口期。

## 语种判定是怎么做的

分两级，因为这两类问题的性质完全不同：

1. **按字符集硬路由**。谚文 → 韩语，假名 → 日语，汉字 → 中文，西里尔 → 俄语。这些是确定性的，不需要统计模型，一个字符就能定。
2. **拉丁字母才跑统计识别**。用 `NLLanguageRecognizer`，并且只在配置里真实用到的拉丁语种之间做选择（候选越少越准）。置信度低于阈值时回落到 `defaultLatinLanguage`，同时把语种标签标成橙色加问号 —— 这时候直接 `⌘1`…`⌘9` 手动切就行。

单个拉丁词的语种识别本质上就是不可靠的（`radio`、`via`、`piano` 这类词在英语和意语里都成立），所以设计上不追求猜对，而是**猜错时让你一眼看出来、一键改过来**。

## 为什么必须开自动识别

Vision 的 `recognitionLanguages` 里如果同时放拉丁语和 CJK，对 CJK 会直接返回空。本机实测：

| 配置 | `사랑` | `词典` | `beautiful` |
|---|---|---|---|
| `["en-US","ko-KR","it-IT","zh-Hans"]` | 空 | 空 | ✓ |
| `["ko-KR"]` | ✓ | 空 | — |
| `automaticallyDetectsLanguage = true` | ✓ | ✓ | ✓ |

所以正确做法是让 Vision 自己选模型。`autoDetectLanguage` 设成 `false` 会退化成逐语言尝试，慢且不一定更准。

## 调试

```bash
/Applications/自制OCR查词.app/Contents/MacOS/OCRDict --ocr 某张图.png
```

对一张图跑完整链路并打印：识别文本、判定语种、置信度、选中的词典、最终链接。改词典配置时很好用。

```bash
/Applications/自制OCR查词.app/Contents/MacOS/OCRDict --test 사랑
```

跳过截图直接开结果窗口。

## 代码结构

| 文件 | 职责 |
|---|---|
| `main.swift` | 入口 + 两个调试子命令 |
| `AppDelegate.swift` | 菜单栏、主菜单、取词主流程 |
| `Config.swift` | 配置模型与读写（缺字段自动回落默认值） |
| `ScreenCapture.swift` | 调 `/usr/sbin/screencapture -i` 框选 |
| `OCR.swift` | Vision 文字识别 + 空白清洗 |
| `LanguageRouter.swift` | 字符集硬路由 + 拉丁语统计识别 + 词典匹配与 URL 拼装 |
| `HelpDocument.swift` | 使用说明的 HTML，从当前配置实时生成 |
| `HelpWindow.swift` | 说明窗口 |
| `HotKeyEditor.swift` | 快捷键录制与编辑界面 |
| `LineJoiner.swift` | 智能拼行：连字符 + 几何 + 语言学三信号还原断词 |
| `QRCode.swift` | 二维码/条码识别 |
| `SelectionReader.swift` | 读选中文字：AX 直读 + ⌘C 回落 |
| `HotKeyManager.swift` | Carbon 全局热键，支持多组绑定 |
| `ResultWindow.swift` | 结果窗口：词条编辑 + 词典切换 + 内嵌 WebView |
| `HUD.swift` | 屏幕中央的短提示 |
| `WebData.swift` | 内嵌 WebView 落盘数据的统计与清除 |
