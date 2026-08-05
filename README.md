# QuickDict

**A macOS lookup tool for learners of Korean.** Grab any Korean text on screen — scanned textbooks,
PDFs, video subtitles, web pages, a screenshot someone sent you — and get a dictionary entry instantly.
All recognition runs on your Mac. No network, no telemetry, no history.

[中文说明](README.zh-CN.md) · [Features in detail](FEATURES.md)

---

## What makes it different

Every OCR dictionary tool can read text off the screen. This one **puts Korean words back together
after a line break.**

When you OCR a wrapped paragraph, words get cut in half at the end of a line. `이성적인` (*rational*)
becomes `이` + `성적인`, and naive joining produces `이 성적인` — which means something else entirely.
The space that used to be there was consumed by the line wrap; **it does not exist in the pixels.**

Getting this right took three dead ends:

| Attempt | Result |
|---|---|
| System Korean spell checker | ✗ Accepts any string of valid Hangul syllables — `그리느끼는` passes |
| NaturalLanguage Korean tokenizer | ✗ Splits on spaces only, no morphological analysis |
| Pure geometry (is the line flush right?) | △ Separates *wrapped* from *paragraph end*, but not *mid-word* from *at-space* |

The working solution combines three signals:

1. **The system Korean dictionary** (`DCSCopyTextDefinition`) — join the halves and check whether the
   longest dictionary-valid prefix **crosses the seam**. `이` + `성적인` → `이성적` is a word, length 3 >
   the 1 character before the seam → the word was broken.
2. **Line geometry** — Vision's per-line bounding boxes tell us whether a line was cut off or ended naturally.
3. **A Korean particle/ending table** — a dangling `은` / `는` / `로서` / `하며` / `진다고` at the start of a
   line can only be the tail of the previous word.

Latin script takes a different path: the English spell checker is a real dictionary, so
`jum` + `ps` = `jumps` is decided by lookup, not heuristics.

**45 of 47 test cases pass** (6 Korean passages plus English and Italian, across many column widths
including forced character-level wrapping). One failure is the OCR dropping a period; the other is
`의존 명사`, which is genuinely ambiguous — the compound `의존명사` is itself a dictionary entry.

### When it cannot know, it says so

`이성적인` (*rational*) and `이 성적인` (*this ~ual*) are **both valid Korean**. When the line break lands
exactly between them, no local signal can tell them apart — only context can, and that needs a language
model. So QuickDict merges by default (far more frequent) and **reports the spots it had to judge**:

```
Copied 87 characters
⚠️ Merged here, but could legitimately be separate words:
이성적인
```

Typically 0–1 flags per paragraph, so it stays useful rather than noisy.

---

## Features

**Two capture modes**

| | |
|---|---|
| `⌃⌥9` **Screenshot** | Images, scanned PDFs, video subtitles — text you *cannot select* |
| `⌘⌥D` **Selection** | Selectable text: no OCR errors, no dragging |

**Three actions on one capture**

| | |
|---|---|
| `⌃⌥9` | Look up — detect the language, open the right dictionary |
| `⌃⌥0` | To text — OCR, rejoin broken words, copy to clipboard (works fully offline) |
| `⌃⌥8` | Scan QR / barcode — open URLs in your browser, copy anything else |

**Result window** — `⌘1`…`⌘9` switch dictionary, `⌘L` fix a misrecognized character and search again,
`esc` to close, pin button to keep it on top. Without the pin it floats only while it appears, then
drops behind as soon as you click elsewhere.

**Configurable dictionaries** — a JSON array where `{q}` marks the query. Six by default
(Naver KO-ZH, 국어사전, Papago, Google Translate, Google, Google AI mode). Adding one is a single line.

**Visual shortcut editor** — click a field, press the combination. Combinations already taken by
another app are flagged in red the moment you save.

**Built-in guide** — `⌘?`, generated from your live config, so it can never drift out of date.

**Follows your system language** — English and Simplified Chinese. Adding a language means dropping a
`Localizable.strings` into `Resources/<code>.lproj/` — no code changes.

---

## Privacy

Recognition is entirely on-device: Vision OCR, Vision barcodes, NaturalLanguage detection, the system
dictionary, geometry. Measured over repeated runs, the process opens **zero network sockets**, and
`URLSession` appears **zero times** in the source.

Only opening a dictionary page needs the network — because that page *is* the network. The app records
no lookup history, and the embedded browser's cookies and localStorage are wiped on quit by default
(dictionary sites like to store "recent searches" there).

---

## Install

Requires **macOS 13+**. Universal binary — Apple Silicon and Intel.

```bash
git clone <this repo> && cd quickdict
./build.sh install
```

Only the Command Line Tools are needed; a full Xcode install is not. The build takes about a minute.

> Building from source avoids Gatekeeper entirely. If you download a prebuilt `.zip` instead, macOS will
> refuse to open it because the app is ad-hoc signed rather than notarized — clear the quarantine flag with
> `xattr -dr com.apple.quarantine /Applications/QuickDict.app`.

### Permissions

Both live in **System Settings → Privacy & Security**. **Restart the app after granting** — macOS only
applies permissions to a fresh process.

| Permission | Needed for | Without it |
|---|---|---|
| Screen Recording | Dragging a capture area | Screenshot shortcuts fail |
| Accessibility | Reading selected text in other apps | Selection shortcuts fail |

Menu bar → *Permissions & Languages* shows the current state, as does `OCRDict --diag`.

---

## Looking words up in your language

Defaults target Chinese. Switch by editing the Naver subdomain and the translator target code —
all Naver language pairs share the same path.

| Your language | Naver | Papago | Google Translate |
|---|---|---|---|
| English | `en.dict.naver.com` | `tk=en` | `tl=en` |
| Chinese | `zh.dict.naver.com` | `tk=zh-CN` | `tl=zh-CN` |
| Japanese | `ja.dict.naver.com` | `tk=ja` | `tl=ja` |

Config lives at `~/Library/Application Support/OCRDict/config.json`. Menu bar → *Reload Config* applies
changes without a restart.

---

## Debugging

```bash
QuickDict.app/Contents/MacOS/OCRDict --diag           # version, permissions, shortcuts, dictionaries
QuickDict.app/Contents/MacOS/OCRDict --join image.png # line-rejoining only
QuickDict.app/Contents/MacOS/OCRDict --ocr  image.png # full lookup pipeline
QuickDict.app/Contents/MacOS/OCRDict --qr   image.png # barcode detection only
```

## Source layout

2900 lines of Swift, no third-party dependencies.

| File | Role |
|---|---|
| `LineJoiner.swift` | Rejoining broken words — dictionary + geometry + particle table |
| `LanguageRouter.swift` | Script-based routing, then statistical detection for Latin |
| `OCR.swift` / `QRCode.swift` | Vision text and barcode recognition |
| `SelectionReader.swift` | Reading the selection: Accessibility first, `⌘C` fallback |
| `HotKeyManager.swift` | Carbon global hotkeys (no Accessibility permission needed) |
| `ResultWindow.swift` | Result window with embedded WebView |
| `HotKeyEditor.swift` | Shortcut recording UI |
| `HelpDocument.swift` | The guide, generated from live config |
| `Config.swift` | Config model, tolerant of missing fields |

## License

MIT
