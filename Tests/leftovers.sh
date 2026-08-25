#!/bin/bash
# 收尾自检：有没有留下不该留的进程和临时文件。
#
# **这个脚本是拿教训换来的**：一次工作里我留了四个空转的等待循环，
# 其中一个跑了十五分钟才被发现 —— 条件里带了个会过期的时间窗
# （`find -newermt '-3 minutes'`），过了那个窗口就永远不可能为真。
# 光靠「记得清理」是不行的，得有个东西替你数。
#
#   ./Tests/leftovers.sh          # 报告
#   ./Tests/leftovers.sh --strict # 有遗留就退出码非零（给收尾把关用）
#
# **故意不并进 `Tests/run.sh`。** 试过，当场就红了 —— 抓到的是我自己另一个
# 终端里正在跑的等待循环。它没报错，是我放错了地方：那套测试验的是代码，
# 而这个验的是机器现在的状态，把两者混在一起，只会让人学会无视这条。
# 收尾的时候单独跑一次，见 Tests/CHECKLIST.md 第十一节。
#
# 判定规则：
#   - App 本体和它自己拉起来的边车：**应该在**，不算遗留
#   - 测试用的边车（token 是 sidecartest / clonetest 之类）：跑完就该没了
#   - shell 的等待循环、裸 sleep：一律算遗留
#   - 本脚本自己和它的子进程：不算（不然永远报一个假阳性）
set -uo pipefail

STRICT=0
[ "${1:-}" = "--strict" ] && STRICT=1

SELF=$$
found=0

# 自己这条命令的整棵进程树，用来排除自匹配
mine() {
    local pid=$1 hop=0
    while [ "$pid" != "1" ] && [ "$pid" != "0" ] && [ -n "$pid" ] && [ "$hop" -lt 8 ]; do
        [ "$pid" = "$SELF" ] && return 0
        pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
        hop=$((hop + 1))
    done
    return 1
}

report() {
    printf '  \033[33m%s\033[0m  pid %s\n    %s\n' "$1" "$2" "$3"
    found=$((found + 1))
}

echo "==> 裸 sleep（等待循环的尾巴）"
for p in $(pgrep -x sleep 2>/dev/null); do
    mine "$p" && continue
    report "sleep" "$p" "$(ps -o command= -p "$p" 2>/dev/null | cut -c1-100)"
done
[ "$found" = 0 ] && echo "    没有"

before=$found
echo "==> 测试用的边车（跑完该自己退）"
for p in $(pgrep -f "server\.py.*--token (sidecartest|clonetest)" 2>/dev/null); do
    mine "$p" && continue
    report "测试边车" "$p" "$(ps -o command= -p "$p" 2>/dev/null | cut -c1-100)"
done
for p in $(pgrep -f "Tests/speech/sidecar\.py" 2>/dev/null); do
    mine "$p" && continue
    report "测试脚本" "$p" "$(ps -o command= -p "$p" 2>/dev/null | cut -c1-100)"
done
[ "$found" = "$before" ] && echo "    没有"

echo "==> 本该在的（不算遗留）"
app=0
for p in $(pgrep -f "QuickDict 3.app" 2>/dev/null); do
    printf '    pid %-7s %s\n' "$p" "$(ps -o comm= -p "$p" 2>/dev/null | xargs basename)"
    app=$((app + 1))
done
[ "$app" = 0 ] && echo "    App 没在跑"

echo
if [ "$found" = 0 ]; then
    echo "干净：没有遗留进程"
else
    echo "发现 $found 个遗留 —— 上面每个都该杀掉"
fi
[ "$STRICT" = 1 ] && exit $((found > 0 ? 1 : 0))
exit 0
