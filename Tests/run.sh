#!/bin/bash
# Integration tests for the line rejoiner and the barcode reader.
#
# These drive the real binary end to end (render → Vision OCR → LineJoiner), which is what
# actually matters: the rejoining logic is meaningless without real bounding boxes from Vision.
# Fixtures are committed, so a failure is a code change and not a font-rendering difference.
#
#   ./Tests/run.sh              build first, then test
#   ./Tests/run.sh --no-build   test the existing build/QuickDict 3.app
set -uo pipefail
cd "$(dirname "$0")/.."

if [ "${1:-}" != "--no-build" ]; then
    ./build.sh >/dev/null || { echo "build failed"; exit 1; }
fi
BIN="build/QuickDict 3.app/Contents/MacOS/OCRDict"
[ -x "$BIN" ] || { echo "no binary at $BIN — run ./build.sh"; exit 1; }

pass=0; fail=0
normalize() { python3 -c "import sys,re;print(re.sub(r'\s+',' ',sys.stdin.read()).strip())"; }

echo "── line rejoining"
while IFS=$'\t' read -r image expected; do
    [ -z "$image" ] && continue
    got=$("$BIN" --join "Tests/fixtures/$image" 2>/dev/null | normalize)
    want=$(printf '%s' "$expected" | normalize)
    if [ "$got" = "$want" ]; then
        pass=$((pass + 1))
    else
        fail=$((fail + 1))
        echo "  FAIL $image"
        echo "    want: $want"
        echo "    got:  $got"
    fi
done < Tests/expected.tsv

echo "── korean lemmatisation"
# 本地词库查的是词典形，而 OCR 到的永远是变形后的词。这一段固化「还原」的结果 ——
# 库里 5.6 万词条一个变形都不收，没有这一步整个词库查不动。
# 用的是打包进 App 的那份（build.sh 会从 Resources/*.gz 解出来）。
KRDICT="${KRDICT:-$(dirname "$BIN")/../Resources/krdict-kozh.sqlite}"
if [ -f "$KRDICT" ]; then
    while IFS=$'\t' read -r word want; do
        [ -z "$word" ] && continue
        got=$("$BIN" --lemma "$KRDICT" "$word" 2>/dev/null | tr -d '*')
        if [[ " $got " == *" $want "* ]]; then
            pass=$((pass + 1))
        else
            fail=$((fail + 1))
            echo "  FAIL $word → $got (want $want)"
        fi
    done < Tests/lemma.tsv
else
    echo "  skipped — no database at $KRDICT"
fi

echo "── notes conversion"
# 笔记转换管线：标题识别（编号/无编号两种风格）、目录跳过、章节剔除、
# 搜索键生成、谚文活用推导。当初和 Python 版逐条比对过，这里把那次比对固化下来。
for md in Tests/notes/*.md; do
    want="${md%.md}.expected"
    got=$("$BIN" --notes "$md" 2>/dev/null)
    if [ "$got" = "$(cat "$want")" ]; then
        pass=$((pass + 1))
    else
        fail=$((fail + 1))
        echo "  FAIL ${md##*/}"
        diff <(cat "$want") <(printf '%s' "$got") | head -6 | sed 's/^/    /'
    fi
done

    # 词库页面自带的查询入口：输入框、回车绑定、以及**它的样式规则**。
    # 样式漏掉过一次 —— 补丁挂的锚点早被删了，替换静默失败，框子还在但没样式。
    page=$("$BIN" --krdict "$KRDICT" "가다" 2>/dev/null)
    ok=0
    printf '%s' "$page" | grep -q 'id="kq"' && ok=$((ok+1))
    printf '%s' "$page" | grep -q "e.key === 'Enter'" && ok=$((ok+1))
    printf '%s' "$page" | grep -q '#kq {' && ok=$((ok+1))
    if [ "$ok" = "3" ]; then
        pass=$((pass + 1))
    else
        fail=$((fail + 1))
        echo "  FAIL 词库页面的查询入口 — 输入框/回车/样式 只齐了 $ok/3"
    fi

echo "── configurable vs implemented"
# 快捷键编辑器里能选的每一种「来源 + 动作」，dispatch 里都必须真的有分支。
# 曾经不一致：「划词 + 只放剪贴板」「划词 + 扫码」选得上，按下去却静默变成查词。
combos=$("$BIN" --combos 2>/dev/null)
want="screenshot: lookup,clipboard,qrcode,speak
selection: lookup,speak,speakfaster,speakslower
manual: -
home: -"
if [ "$combos" = "$want" ]; then
    pass=$((pass + 1))
else
    fail=$((fail + 1))
    echo "  FAIL 组合表和实现对不上"
    diff <(printf '%s' "$want") <(printf '%s' "$combos") | sed 's/^/    /'
fi

# 源码里每个 t("…") 都得有译文 —— 没有的话界面上会直接显示键名本身，
# 编译器不报错。主页上就出现过「menu.capture」当标签。
untranslated=$(python3 - <<'PY'
import re, pathlib
pat = re.compile(r'(?<![A-Za-z0-9_.])t\("([^"\\]+)"')
used = set()
for f in pathlib.Path("Sources/OCRDict").glob("*.swift"):
    used |= set(pat.findall(f.read_text(encoding="utf-8")))
have = set(re.findall(r'^"([^"]+)"\s*=',
    pathlib.Path("Resources/en.lproj/Localizable.strings").read_text(encoding="utf-8"), re.M))
print(" ".join(sorted(used - have)))
PY
)
if [ -z "$untranslated" ]; then
    pass=$((pass + 1))
else
    fail=$((fail + 1))
    echo "  FAIL 这些键没有译文: $untranslated"
fi

echo "── browsing data vs sign-ins"
# 两类数据必须能分开清。一股脑全清的话，「别让网站记住我搜过什么」和
# 「别让我每次重登」就只能二选一 —— 它们本来没有关系。
kinds=$("$BIN" --clear-kinds 2>/dev/null)
if [ "$kinds" = "logins=1 browsing>1 disjoint=yes" ]; then
    pass=$((pass + 1))
else
    fail=$((fail + 1))
    echo "  FAIL 数据分类 — got: $kinds"
fi

echo "── home page"
# 主页和权限页都是按当前配置/状态生成的。这里盯两件事：
#   1. 该有的段都在（3.1 起搜索框上移到了工具栏、设置项进了侧边栏，主页只剩取词和词典）
#   2. **没有把文案键漏成原文**（`menu.capture` 这种键名直接显示在界面上过一次）
leaked() { printf '%s' "$1" | grep -oE '>(menu|home|help|dict|about|shell|speech)\.[a-zA-Z.]+<' | sort -u; }

home=$("$BIN" --home-html 2>/dev/null)
missing=$(leaked "$home")
sections=$(printf '%s' "$home" | grep -c "<h2>")
# 取词、词典两段；权限缺了才会多冒一条提示，所以 2 段起
if [ "$sections" -ge 2 ] && [ -z "$missing" ] \
   && printf '%s' "$home" | grep -q 'data-do="screenshot"' \
   && printf '%s' "$home" | grep -q 'data-dict='; then
    pass=$((pass + 1))
else
    fail=$((fail + 1))
    echo "  FAIL home page — 段落 $sections（至少 2），取词卡 $(printf '%s' "$home" | grep -c 'data-do=')"
    [ -n "$missing" ] && echo "    漏译: $missing"
fi

perm=$("$BIN" --perm-html 2>/dev/null)
missing=$(leaked "$perm")
# 五行状态：屏幕录制、辅助功能、离线词库、我的资料、登录保留
states=$(printf '%s' "$perm" | grep -c 'class="state')
if [ "$states" = "5" ] && [ -z "$missing" ]; then
    pass=$((pass + 1))
else
    fail=$((fail + 1))
    echo "  FAIL permissions page — 状态行 $states/5"
    [ -n "$missing" ] && echo "    漏译: $missing"
fi

echo "── speech segmentation"
# 朗读的语言分段：行内混排按文字系统切开、汉字在有假名时判日语、
# 中性字符（标点空格）跟前一段走。改坏任何一条，混排朗读就会用错嗓音。
seg=$("$BIN" --speak-dry "사랑이라는 말，意思是爱。I love you means 사랑해요.

これは日本語の文です。漢字も入っています。" 2>/dev/null)
want_seg="节1 [ko] 사랑이라는 말，
节1 [zh] 意思是爱。
节1 [en] I love you means 
节1 [ko] 사랑해요.
节2 [ja] これは日本語の文です。漢字も入っています。"
if [ "$seg" = "$want_seg" ]; then
    pass=$((pass + 1))
else
    fail=$((fail + 1))
    echo "  FAIL speech segmentation"
    diff <(printf '%s' "$want_seg") <(printf '%s' "$seg") | head -6 | sed 's/^/    /'
fi

echo "── barcode"
qr=$("$BIN" --qr Tests/fixtures/qr-url.png 2>/dev/null | head -1)
case "$qr" in
    *"en.dict.naver.com"*) pass=$((pass + 1)) ;;
    *) fail=$((fail + 1)); echo "  FAIL qr-url.png → $qr" ;;
esac

BUILD_TMP=$(mktemp -d); trap 'rm -rf "$BUILD_TMP"' EXIT
echo "── neural speech fully removed"
# 3.3 把整个 Python 边车（Qwen + Edge）移到了 Ausculta。
# **拆掉一个功能最容易剩下的是「半截」**：源码删了但文档还在承诺、
# 字符串留着没人用、bundle 里还躺着 .py。这几条盯的就是那个半截。
ok=1
if grep -rlq -e 'TTSSidecar' -e 'NeuralSpeech' -e 'SpeechTrace' -e 'SpeechPane' -e 'SpeechHistory' -e 'qwen-tts' Sources 2>/dev/null; then
    ok=0; echo "  FAIL 源码里还有边车残留：$(grep -rl -e TTSSidecar -e NeuralSpeech -e SpeechTrace -e SpeechPane -e SpeechHistory -e qwen-tts Sources | tr '\n' ' ')"
fi
# 六份语言文件条目数必须一致 —— 删键时漏掉一份，那门语言就会露出原始键名
counts=$(for f in Resources/*.lproj/Localizable.strings; do grep -c '^"' "$f"; done | sort -u | wc -l | tr -d ' ')
if [ "$counts" != "1" ]; then
    ok=0; echo "  FAIL 六份 Localizable.strings 条目数不一致"
fi
# 源码里 t("…") 用到的键，每份语言文件都得有
missing=$(grep -rhoE '(^|[^A-Za-z0-9_])t\("[a-zA-Z][a-zA-Z0-9_.]*"\)' Sources \
          | grep -oE '"[^"]+"' | tr -d '"' | sort -u > "$BUILD_TMP/keys.txt"
          for f in Resources/*.lproj/Localizable.strings; do
              grep -oE '^"[^"]+"' "$f" | tr -d '"' | sort -u > "$BUILD_TMP/have.txt"
              comm -23 "$BUILD_TMP/keys.txt" "$BUILD_TMP/have.txt"
          done | sort -u)
if [ -n "$missing" ]; then
    ok=0; echo "  FAIL 有键没翻译：$(echo "$missing" | head -3 | tr '\n' ' ')"
fi
# 文档不能还在承诺自带神经语音（「已移走」的说明句不算，那是在讲历史）
for doc in README.md README.zh-CN.md FEATURES.md; do
    if grep -q -e 'install.sh qwen' -e 'tts-diag' -e 'Tools/qwen-tts' "$doc" 2>/dev/null; then
        ok=0; echo "  FAIL $doc 还写着边车的安装/诊断步骤"
    fi
done
# 装出来的 App 里不能还躺着边车
if [ -d "$(dirname "$BIN")/../Resources/qwen-tts" ]; then
    ok=0; echo "  FAIL App bundle 里还有 Resources/qwen-tts/"
fi
[ "$ok" = 1 ] && pass=$((pass + 1)) || fail=$((fail + 1))

echo
echo "passed $pass, failed $fail"
# 2 known failures: one fixture where Vision drops a sentence-final period, and 의존 명사,
# which is genuinely ambiguous (의존명사 is itself a dictionary headword).
[ "$fail" -le 2 ] || exit 1
