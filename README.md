# QuickDict

**A macOS lookup tool for learners of Korean.** Grab any Korean text on screen — scanned textbooks,
PDFs, video subtitles, web pages, a screenshot someone sent you — and get a dictionary entry instantly.
All recognition runs on your Mac. No network, no telemetry, no history.

Works out of the box in **English, 中文, 日本語, 한국어, Русский and Tiếng Việt and Italiano** — the dictionary set is
chosen from your system language on first launch.

Languages: **English** · [中文](README.zh-CN.md) · [Русский](README.ru.md) · [Tiếng Việt](README.vi.md) · [日本語](README.ja.md) · [한국어](README.ko.md)

[Features in detail](FEATURES.md)

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

**28 committed integration tests**, all passing — real fixtures through real Vision OCR, across many
column widths including forced character-level wrapping.

The particle table is **extensible from the config file**, so if you spot a missing ending you can fix
it yourself without touching code or waiting for a release:

```jsonc
"koreanExtraParticles":  ["로부터", "에서부터"],
"koreanExtraStandalone": ["뭐"]
```

Your additions are *merged* with the built-in table, not substituted for it, so updates keep applying.

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

Plus direct keys per dictionary: `⌘⌥N` Naver, `⌘⌥K` 국어사전, `⌘⌥P` Papago, `⌘⌥G` Google Translate.
These are generated from whichever dictionaries your language actually has — no dead shortcuts.

**Result window** — `⌘1`…`⌘9` switch dictionary, `⌘L` fix a misrecognized character and search again,
`esc` to close, pin button to keep it on top. Without the pin it floats only while it appears, then
drops behind as soon as you click elsewhere.

**First-run setup** — picks your dictionary language from the system language, walks you through the two
permissions with live status, and detects the Gatekeeper quarantine flag if you downloaded a build.

**Configurable dictionaries** — a JSON array where `{q}` marks the query. Switch the whole set from the
menu bar, or add your own with one line.

**Visual shortcut editor** — click a field, press the combination. Combinations already taken by
another app are flagged in red the moment you save.

**Built-in guide** — `⌘?`, generated from your live config, so it can never drift out of date.

**Follows your system language** — English and Simplified Chinese UI. Adding a language means dropping a
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
git clone https://github.com/lpoterus-commits/quickdict.git && cd quickdict
./build.sh install
```

Only the Command Line Tools are needed; a full Xcode install is not. The build takes about a minute.

**Windows?** Not yet. Every capability here is an Apple framework, so it is a rewrite rather than a port — and the Korean line-rejoining leans on the system dictionary macOS ships and Windows does not. [WINDOWS.md](WINDOWS.md) is a handoff brief for anyone attempting it: the algorithm, the three approaches that failed, an API mapping, and the test corpus (which is plain data and transfers as-is). Written in Chinese.

> The app installs as **QuickDict 3.app** so it can coexist with an older v2 install. Change `APP_NAME`
> in `build.sh` if you would rather it be plain `QuickDict`.

### If the app will not open

Once a `.zip` has been downloaded, macOS blocks apps that Apple has not notarized. You will see
*"QuickDict 3 is damaged and can't be opened."* **The app is not damaged** — macOS flags everything that
arrives from the internet. Notarization costs $99 a year, which this project does not spend.

Three ways around it:

**1. Build it yourself** (the command above). Files you compile locally are never flagged. Cleanest option.

**2. Download it, then run one command.** Paste this into Terminal once, then open the app as usual:

```bash
xattr -dr com.apple.quarantine "/Applications/QuickDict 3.app"
```

Once is enough — the flag never comes back. Removing it does not modify or weaken the app in any way:
the code signature stays valid and every feature works exactly as if you had compiled it yourself.

**3. Have someone hand it to you.** The flag is added by browsers, mail and AirDrop. A copy from a USB
stick or an external drive carries no flag at all and opens on a double-click — no Terminal needed.

### Permissions

Both live in **System Settings → Privacy & Security**. **Restart the app after granting** — macOS only
applies permissions to a fresh process. The setup window walks you through both and shows live status.

| Permission | Needed for | Without it |
|---|---|---|
| Screen Recording | Dragging a capture area | Screenshot shortcuts fail |
| Accessibility | Reading selected text in other apps | Selection shortcuts fail |

---

## Dictionary languages

Chosen automatically from your system language on first launch; switch any time from the menu bar
(**Look Words Up In**). Seven presets ship by default:

| | Naver dictionary | Translators |
|---|---|---|
| English | `en.dict.naver.com` | Papago, Google Translate → `en` |
| 中文 | `zh.dict.naver.com` | → `zh-CN` |
| 日本語 | `ja.dict.naver.com` | → `ja` |
| 한국어 | `ko.dict.naver.com` | → `ko` |
| Русский | `dict.naver.com/rukodict` | → `ru` |
| Tiếng Việt | `dict.naver.com/vikodict` | → `vi` |
| Italiano | `dict.naver.com/itkodict` | → `it` |

### Choosing your own dictionaries

Two axes decide what opens:

- **Look words up in** — one language, where definitions land. Menu bar → *Look Words Up In*.
- **Also look up** — which foreign languages you meet. Menu bar → *Also Look Up*, tick as many as you like.

Korean goes to Naver's bilingual dictionary. Every other language you tick gets a Glosbe entry
(`glosbe.com/<from>/<to>/<word>`), which covers essentially any pair. Select an Italian word and the
Italian dictionary opens; select a Korean one and Naver opens. No manual switching.

**Prefer a different site? Claim the language yourself.** Menu bar → **Dictionaries…** opens a window with
one row per dictionary: name, address, which languages it opens for, and whether it opens in your browser.
Add a row, fill in two fields, save. Anything that claims a language *replaces* the generated default for it.

`{q}` in the address is where the word goes; leave *Opens for* empty for manual only, or put `*` to catch
everything else. The same thing in the config file, if you prefer text:

```jsonc
{
  "id": "wordreference",                        // any unique name
  "name": "WordReference",                      // shown on the button
  "languages": ["fr"],                          // French now goes here, not to Glosbe
  "url": "https://www.wordreference.com/fren/{q}"   // {q} is where the query goes
}
```

Then **Reload Config**. Optional fields:

| Field | Meaning |
|---|---|
| `languages` | Which detected languages open it automatically. `"*"` is the fallback; `[]` means manual only |
| `suffix` | Appended to the query *before* URL-encoding — useful for search engines and AI prompts |
| `external` | `true` opens it outside the built-in window, so sites needing your login work |

**Your entries survive everything** — changing your language, ticking a new source language, none of it
touches what you added.

### Using a dictionary app instead of a website

If you have a dictionary app installed, lookups can open it directly rather than a web page. Menu bar →
**Local Dictionary Apps** lists the ones actually installed on your Mac and lets you tick them; apps that
are not installed are not shown.

This works because such apps register their own URL scheme, and anything marked `external` is handed to
the system rather than loaded in the built-in window:

```jsonc
{ "id": "local-eudic", "name": "Eudic", "languages": ["en"],
  "url": "eudic://dict/{q}", "external": true }
```

Ticking one adds it as **manual only** — a dictionary app usually handles many languages, and which one
it should own is your call. Give it a `languages` list to make it automatic; it then takes over that
language completely.

### Adding a language to the presets

Naver Dictionary covers 67 languages, but the URL comes in **two shapes** — this trips people up:

- **English, Chinese, Japanese, Korean** — a dedicated subdomain: `https://<code>.dict.naver.com/#/search?query={q}`
- **Everything else** — a path on the shared domain: `https://dict.naver.com/<code>kodict/#/search?query={q}`

Add one entry to `DictionaryPresets.all` and nothing else changes — the dictionary set, the per-dictionary
shortcuts and the built-in guide all follow. If Naver has no pair for your language, use `.none` for the
Naver form: the Korean-Korean dictionary takes over automatic routing and Google Translate covers the rest.

---

## Debugging

```bash
"QuickDict 3.app/Contents/MacOS/OCRDict" --diag           # version, language, permissions, shortcuts
"QuickDict 3.app/Contents/MacOS/OCRDict" --join image.png # line-rejoining only
"QuickDict 3.app/Contents/MacOS/OCRDict" --ocr  image.png # full lookup pipeline
"QuickDict 3.app/Contents/MacOS/OCRDict" --qr   image.png # barcode detection only
./Tests/run.sh                                            # 28 integration tests
```

## Source layout

~3300 lines of Swift, no third-party dependencies.

| File | Role |
|---|---|
| `LineJoiner.swift` | Rejoining broken words — dictionary + geometry + particle table |
| `DictionaryPresets.swift` | Per-language dictionary sets and their default shortcuts |
| `Onboarding.swift` | First-run setup, permission walkthrough, Gatekeeper check |
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
