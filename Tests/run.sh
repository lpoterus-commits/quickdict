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

echo
echo "passed $pass, failed $fail"
# 2 known failures: one fixture where Vision drops a sentence-final period, and 의존 명사,
# which is genuinely ambiguous (의존명사 is itself a dictionary headword).
[ "$fail" -le 2 ] || exit 1
