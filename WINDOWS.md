# Windows 版交接文档

写给「在 Windows 上开一个新会话来做移植」的场景。那边的会话读不到 macOS 版的开发过程，
这份文档负责把**读代码看不出来的判断**交接过去。

先读 [README.zh-CN.md](README.zh-CN.md) 了解产品是什么，再读这里。

---

## 一句话目标

在 Windows 上做出功能等价的版本。**配置文件格式保持一致**，这样同一个人在两台机器上能用同一份配置。

---

## ⚠️ 最重要的一节：三条死路，别再走一遍

macOS 版的核心功能是**把换行切断的韩语词拼回去**。这件事我试了三个方向，前三个都不成立。
Windows 上对应的方案可能不同，但**失败的原因是语言学层面的，跨平台同样成立**：

### 死路一：拼写检查器判不了

macOS 的韩语拼写检查对 `그리느끼는`、`걷는길에서` 这种随便拼的都判「成词」——
它只检查谚文音节是否合法，不查词典。

→ **Windows 上如果打算用 Hunspell 的韩语词典，先做同样的测试再决定是否依赖它。**
（Hunspell 有词缀规则，理论上可能比 macOS 那个强，但**必须实测验证**，别假设。
测试方法：喂 10 个真词 + 10 个随便拼的，看能不能区分。区分不了就换方案。）

### 死路二：分词器不做形态素切分

macOS 的 `NLTokenizer` 设成韩语后，`느끼는그리움` 原样返回一个 token——**只按空格切**。

→ Windows 上没有系统级韩语分词器，这条路本来就不存在。

### 死路三：纯几何分不清「断在空格」和「断在词中间」

Vision 给了每行的 bounding box，能判断这行是被挤断的还是自然结束。
但**顶满右边缘的行里，断点落在空格上和落在词中间，像素表现完全一样**——
CJK 默认允许在任意两字之间断行。

→ 这一条是物理事实，换什么 OCR 引擎都一样。

**结论：单一信号都不够，必须组合。**

---

## 实际可用的算法

按顺序短路判断，处理相邻两行 `A` / `B`：

```
0. 行距 > 1.9 × 行高          → 换段，保留换行
1. A 以连字符结尾              → 断了，去掉连字符直接连         ← 确定
2. 韩语强信号命中              → 断了，直接连                   ← 见下
3. A 末尾空出 > 0.6 字宽       → 没断，加空格                   ← 几何
4. A 顶满右边缘 → 按文字种类：
     韩语   → 没断，加空格（默认值）
     中日   → 直接连（本来无词间空格）
     拉丁文 → 查英语拼写词典决定
```

### 韩语强信号（命中任意一条即判定断词）

| 条 | 规则 | 例 |
|---|---|---|
| 1 | 下一行开头是助词/词尾表里的词 | `그리움` \| **`은`** |
| 2 | **拼起来能在韩语词典里查到跨接缝的词** | `이` + `성적인` → `이성적` |
| 3 | 下一行开头是不能独立成词的单音节 | `띄` \| **`어`** |
| 4 | 上一行末尾是单音节碎片**且**下一行开头本身不成词 | 아니**`아`** \| `니하며` |

第 4 条的后半句不能省——`할` \| `때` 两边都是正经词，漏了这个把关会误连成 `할때`。

### 两条靠实测定下来、不要凭直觉改的参数

- **第 4 步韩语默认「加空格」而不是「不加」。** 试过反过来，准确率从 28/33 掉到 21/33。
- **第 2 步（词典）优先于第 3 步（几何）。** 语言学信号足够强时不用等几何表态。

### 判不了的情况：标出来，不要猜

`이성적인`（理性的）和 `이 성적인`（这个性方面的）**都是合法韩语**。
断行落在中间时没有任何本地信号能分辨——只有上下文能判，那需要语言模型。

做法：**默认合并**（频率高得多），但把「由词典判据促成、且上半截本身也成词」的位置报给用户。
实测每段文本报 0~1 处，不是噪音。

---

## Windows 上最大的空缺

**`DCSCopyTextDefinition` 没有对应物。** macOS 自带韩语词典（새국어사전），
上面算法的第 2 条强信号完全依赖它。Windows 没有内置韩语词典。

候选方案，**按建议评估顺序**：

1. **Hunspell 韩语词典**（`ko_KR`）—— 反正英语拼写检查也要用 Hunspell，一并解决最省事。
   但必须先做「死路一」那个测试，确认它不是同样宽松。
2. **打包一份开放韩语词表** —— 体积可控，离线，可复现。缺点是要自己维护。
3. **국립국어원开放 API** —— 释义最权威，但**要联网**，直接毁掉「全程本地」这个卖点。不推荐。

选定之后，**用本仓库的测试集重新验一遍准确率**（见下节）。

---

## API 对照表

以下 Windows 侧的 API 名称我**没有在 Windows 上验证过**，是按公开文档写的，实现时以实际为准。

| 能力 | macOS 现状 | Windows 候选 |
|---|---|---|
| OCR | `VNRecognizeTextRequest` | `Windows.Media.Ocr.OcrEngine`（WinRT，可从 .NET 调） |
| 行的 bounding box | `VNRecognizedTextObservation.boundingBox` | `OcrLine.Words[].BoundingRect` 求并集 —— **注意 OcrLine 本身没有 rect** |
| 二维码/条码 | `VNDetectBarcodesRequest` | ZXing.Net |
| 判语种 | `NLLanguageRecognizer` | 无系统 API。字符集硬路由自己写（谚文/假名/汉字/西里尔都是确定性的）；只有拉丁文需要统计库 |
| 韩语词典 | `DCSCopyTextDefinition` | **见上一节，最大的坑** |
| 英语拼写 | `NSSpellChecker` | Hunspell（`WeCantSpell.Hunspell` 等） |
| 全局热键 | Carbon `RegisterEventHotKey` | user32 `RegisterHotKey` |
| 读选中文字 | `AXUIElement` + `kAXSelectedText` | UI Automation `TextPattern.GetSelection()`；回落方案同样是模拟 Ctrl+C **并立刻还原整条剪贴板** |
| 框选截图 | `screencapture -i` | 无内置，需自绘全屏遮罩窗口 |
| 内嵌浏览器 | WKWebView | WebView2 |
| 菜单栏常驻 | `NSStatusItem` + `LSUIElement` | 系统托盘 `NotifyIcon` |
| 本地化 | `.lproj/Localizable.strings` | `.resx` |
| 分发拦截 | Gatekeeper（ad-hoc 签名被判「已损坏」） | SmartScreen（未签名报「Windows 已保护你的电脑」）—— **同类问题，同样需要在 README 里给绕过说明** |

### OCR 引擎的一个已知差异

macOS 的 Vision 有个陷阱：`recognitionLanguages` 里同时放拉丁语和 CJK，**对 CJK 会直接返回空**，
必须开 `automaticallyDetectsLanguage`。

Windows 的 `OcrEngine` 是**一个引擎一种语言**（`TryCreateFromLanguage`），模型不同，
但要注意：**用户系统里必须装了对应的 OCR 语言包**，否则 `TryCreateFromLanguage` 返回 null。
首次启动向导里应该检测并提示，就像 macOS 版检测两个权限那样。

---

## 测试集可以直接复用

```
Tests/fixtures/     28 张 PNG
Tests/expected.tsv  图片名 \t 期望文本
Tests/run.sh        macOS 版的跑法，Windows 上重写成 .ps1
```

**这些是纯数据，跨平台通用。** 韩、英、意三种语言，多种栏宽，含强制逐字断行。

### 诊断顺序很重要

Windows 版跑不过用例时，**先分清是 OCR 的问题还是拼行的问题**：

1. 先只看 OCR 的原始分行输出，和 macOS 版的对比
2. OCR 输出一致 → 问题在拼行算法
3. OCR 输出就不一样 → 先解决 OCR（语言包？引擎参数？），拼行的锅还轮不到

macOS 版当前 28/28。**Windows 版如果 OCR 质量不同，期望文本可能达不到——那不一定是算法错了。**
建议先测出 Windows OCR 的原始准确率作为基线。

---

## 配置格式保持一致

`Config.swift` 定义的 JSON 结构就是契约，Windows 版原样实现。位置换成 Windows 惯例：

```
macOS:   ~/Library/Application Support/com.quickdict.app/config.json
Windows: %APPDATA%\QuickDict\config.json
```

关键字段的语义（细节见 README 的「配置」一节）：

- `dictionaryLanguage` —— 母语，释义落在哪
- `sourceLanguages` —— 要查的外语，多选
- `dictionaries[]` —— `{q}` 是查询词位置；`languages` 决定自动命中（`"*"` 兜底，`[]` 仅手动）；
  `external: true` 交给系统打开而不是内嵌窗口
- `koreanExtraParticles` / `koreanExtraStandalone` —— 用户补充的韩语词尾表，**与内置表合并而非替换**

**用户自己加的词典（id 不属于预设）在任何设置变更下都必须保留** —— 这是 macOS 版踩过的坑，
最初换语言会把用户手配的词典整个冲掉。

---

## 建议的实现顺序

按「能独立验证」排，不要一上来做 UI：

1. **OCR + 分行 + bounding box** —— 命令行工具，输入图片输出每行文本和坐标。先跑通这个
2. **拼行算法** —— 用 `Tests/` 里的用例验收，跑到通过率可接受为止
3. **语种路由 + 词典 URL 拼装** —— 纯逻辑，好测
4. **全局热键 + 框选截图** —— 开始碰系统 API
5. **托盘图标 + 结果窗口（WebView2）**
6. **划词取词** —— UI Automation，最容易遇到各家 App 行为不一致
7. **首次启动向导 + 设置窗口**

前三步做完就已经有价值了（等于 macOS 版的 `⌃⌥0` 截图转文字），可以先给人用。

---

## 不要做的事

- **不要为了省事把韩语词典换成在线 API。** 「识别全程本地」是这个软件的卖点之一，
  macOS 版实测过运行期间零网络连接。破坏它等于换了个产品。
- **不要跳过测试集直接调参数。** 断词还原的每一个参数都是实测定的，凭直觉改会退化。
- **不要假设 Windows OCR 的行为和 Vision 一样。** 先测再写。
