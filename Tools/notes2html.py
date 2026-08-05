#!/usr/bin/env python3
"""把自己整理的 Markdown 资料转成 QuickDict 能查的本地词典。

生成一个**自包含的 HTML** —— 数据、样式、搜索全在一个文件里，不联网、不依赖任何库。
QuickDict 里加一条词典指向它就能用：

    file:///路径/韩语语法.html?q={q}

## 为什么不是简单的锚点跳转

韩语语法查的是**变形后的词**。看到 `먹었거든요` 要能找到 `-거든(요)` 这一条 ——
词典式的精确匹配在这里没用，得反过来：**在查询词里找出包含了哪些语法形式**。
所以每条语法都要预先算出一组「真正会出现在句子里的字面片段」作为搜索键，
匹配时看查询词包不包含它们，按长度排序。

## 支持的标题格式

    ## 001｜A/V-거든(요)        ← 编号｜形式
    ### 1. V-자마자             ### 编号. 形式

两种都认。`## 正文` 之前的索引部分整个跳过（那些是目录，不是内容）。

用法：
    python3 notes2html.py 输出.html 资料1.md 资料2.md ...
"""

import html
import re
import sys
import json
from pathlib import Path

# ── 条目标题：## 001｜形式   或   ### 1. 形式
# 编号可能带连字符（0-1.），句号后可能没空格（### 11.【增补】…）
ENTRY_H2 = re.compile(r'^##\s+(\d+)｜(.+?)\s*$')
ENTRY_H3 = re.compile(r'^###\s+([\d-]+)[.)]\s*(.+?)\s*$')
# 正文里 **分类**：X　｜　**释义**：Y
META = re.compile(r'\*\*分类\*\*：\s*(.+?)\s*[　|｜]+\s*\*\*释义\*\*：\s*(.+?)\s*$')
HANGUL = re.compile(r'[가-힣]')

# ── 词干活用
#
# 语法标签写词典形（-기로 하다），句子里出现的是活用形（-기로 했어요）。
# 不补活用形，查「가기로 했어요」就找不到「V-기로 하다」。
#
# 规则形的元音缩合可以直接按谚文音节算（리→렸/려、주→줬/줘），
# 不规则的（하→해、되→돼）单独列表。

_CHO, _JUNG, _JONG = 588, 28, 1
_SSANG_SIOT = 20                                    # 终声 ㅆ 的索引

# 中声索引 → 与「어/아」缩合后的中声。缩合后一律可加终声 ㅆ 构成过去式。
_CONTRACT = {
    20: 6,      # ㅣ → ㅕ    버리 → 버려/버렸
    13: 14,     # ㅜ → ㅝ    주   → 줘/줬
    8: 9,       # ㅗ → ㅘ    오   → 와/왔
    0: 0,       # ㅏ → ㅏ    가   → 가/갔
    4: 4,       # ㅓ → ㅓ    서   → 서/섰
    1: 1,       # ㅐ → ㅐ    보내 → 보내/보냈
    5: 5,       # ㅔ → ㅔ    세   → 세/셌
}

# 不规则：하다（여变则）、되다、이다
_IRREGULAR = {'하': ['했', '해'], '되': ['됐', '돼'], '이': ['였', '이었']}


def conjugations(stem: str) -> set[str]:
    """给词干补出「过去式」和「아/어形」两种最常见的活用形。"""
    if not stem:
        return set()
    if stem[-1] in _IRREGULAR:
        return {stem[:-1] + f for f in _IRREGULAR[stem[-1]]}

    code = ord(stem[-1]) - 0xAC00
    if not 0 <= code < 11172:
        return set()
    cho, jung, jong = code // _CHO, (code // _JUNG) % 21, code % _JUNG
    if jong or jung not in _CONTRACT:                # 有终声（먹、있）本身就能接词尾，不用补
        return set()

    merged = _CONTRACT[jung]
    base = stem[:-1]
    return {
        base + chr(0xAC00 + cho * _CHO + merged * _JUNG),                   # 아/어形
        base + chr(0xAC00 + cho * _CHO + merged * _JUNG + _SSANG_SIOT),     # 过去式
    }


# ═══════════════════════════════════════════ 搜索键

def search_keys(form: str) -> list[str]:
    """从「A/V-거든(요) / A/V-거든」这样的标签里，抽出真正会出现在句子里的片段。

    标签是给人读的，含词性标记（A/V-）、可选成分（(요)）和音变标记（(으)ㄹ），
    这些都不会原样出现在文本里。把它们剥掉，剩下的才能用来做子串匹配。
    """
    candidates: set[str] = set()

    # 【增补】【总览】这类栏目标记不是语法内容
    form = re.sub(r'【[^】]*】', ' ', form)

    # 顶层用「 / 」分隔备选形式；括号内用「/」分隔的也要拆出来
    parts = re.split(r'\s+/\s+', form)
    for group in list(parts):
        for inner in _parenthesised(group):
            if '-' in inner:
                parts.extend(re.split(r'/', inner))

    for raw in parts:
        raw = raw.strip()
        if not raw:
            continue
        # 词性标记有带分隔符的（A/V-거든）也有直接贴着的（N마다、N(이)나）
        raw = re.sub(r'^(A/V|V/A|A|V|N)(\s*[-\s]\s*|(?=[（(가-힣]))', '', raw)
        raw = raw.lstrip('-').strip()

        # 剥掉词性标记后剩下的「/」才是真正的备选形式（-ㄴ/는다、-아/어서）
        for alt in re.split(r'/', raw):
            _expand(alt, candidates)

    return sorted(candidates, key=len, reverse=True)


def _parenthesised(text: str) -> list[str]:
    r"""按深度取出最外层括号里的内容。

    用正则 `\([^)]*\)` 会在遇到第一个右括号就截断 ——
    `(-다고/-(으)라고/-냐고/-자고 하다)` 会只拿到 `-다고/-(으`，后面三个备选全丢。
    """
    out, depth, buffer = [], 0, ''
    for c in text:
        if c in '(（':
            depth += 1
            if depth == 1:
                buffer = ''
                continue
        if c in ')）':
            depth -= 1
            if depth == 0:
                out.append(buffer)
            continue
        if depth > 0:
            buffer += c
    return out


def _expand(raw: str, candidates: set[str]) -> None:
    """展开可选括号，剥掉不会字面出现的成分，收集能用来匹配的片段。"""
    raw = raw.strip().lstrip('-').strip()
    if not raw:
        return

    # (요) 这类可选成分：带上和去掉各生成一份
    variants = {raw}
    for _ in range(3):                          # 最多三层嵌套括号
        grown = set()
        for v in variants:
            m = re.search(r'[（(]([^）()]*)[）)]', v)
            if m:
                grown.add(v[:m.start()] + m.group(1) + v[m.end():])
                grown.add(v[:m.start()] + v[m.end():])
        if not grown:
            break
        variants |= grown

    for v in variants:
        # 开头的孤立字母（ㄹ ㄴ ㅁ…）和 으 在真实文本里是合进前一个音节的，去掉
        v = re.sub(r'^[ㄱ-ㅎㅏ-ㅣ으]+\s*', '', v.strip()).strip()
        _collect(v, candidates)
        # 「-(으)ㄹ 거예요」这类，空格后的部分才是能字面匹配的
        if ' ' in v:
            _collect(v.split(' ', 1)[1], candidates)


def _collect(value: str, out: set[str]) -> None:
    """只收纯谚文（可含空格）的片段。

    单音节也收 —— `-겠-`、`A-게` 这些本身就是一个音节，丢掉它们等于整条查不到。
    噪音由排序兜底：匹配得分按键长算，单音节命中排在最后。
    """
    value = value.strip(' -·?!.？！。')
    if not value or not HANGUL.search(value):
        return
    if not re.fullmatch(r'[가-힣\s]+', value):
        return
    out.add(value)
    # 标签写的是词典形（-수밖에 없다），文本里出现的是活用形（없어요、없었다…）。
    # 去掉词典形的 -다 留下词干，才接得上后面的各种词尾。
    if value.endswith('다') and len(value) >= 3:
        stem = value[:-1]
        out.add(stem)
        out.update(conjugations(stem))


# ═══════════════════════════════════════════ Markdown → HTML

def render(lines: list[str]) -> str:
    """只处理这些文档实际用到的语法：标题、表格、列表、引用、加粗、行内代码。"""
    out: list[str] = []
    i = 0
    while i < len(lines):
        line = lines[i]

        if not line.strip():
            i += 1
            continue

        # 表格：连续的 | ... | 行，第二行是分隔线
        if line.lstrip().startswith('|') and i + 1 < len(lines) and \
                re.match(r'^\s*\|[\s:|-]+\|\s*$', lines[i + 1]):
            head = _cells(line)
            i += 2
            body = []
            while i < len(lines) and lines[i].lstrip().startswith('|'):
                body.append(_cells(lines[i]))
                i += 1
            out.append('<table><thead><tr>'
                       + ''.join(f'<th>{inline(c)}</th>' for c in head)
                       + '</tr></thead><tbody>'
                       + ''.join('<tr>' + ''.join(f'<td>{inline(c)}</td>' for c in row) + '</tr>'
                                 for row in body)
                       + '</tbody></table>')
            continue

        if m := re.match(r'^(#{3,6})\s+(.+)$', line):
            level = min(len(m.group(1)) + 1, 6)
            out.append(f'<h{level}>{inline(m.group(2))}</h{level}>')
            i += 1
            continue

        if line.lstrip().startswith('>'):
            block = []
            while i < len(lines) and lines[i].lstrip().startswith('>'):
                block.append(lines[i].lstrip()[1:].strip())
                i += 1
            out.append(f'<blockquote>{inline(" ".join(block))}</blockquote>')
            continue

        if re.match(r'^\s*[-*]\s+', line):
            items = []
            while i < len(lines) and re.match(r'^\s*[-*]\s+', lines[i]):
                items.append(re.sub(r'^\s*[-*]\s+', '', lines[i]))
                i += 1
            out.append('<ul>' + ''.join(f'<li>{inline(x)}</li>' for x in items) + '</ul>')
            continue

        if re.match(r'^\s*\d+[.)]\s+', line):
            items = []
            while i < len(lines) and re.match(r'^\s*\d+[.)]\s+', lines[i]):
                items.append(re.sub(r'^\s*\d+[.)]\s+', '', lines[i]))
                i += 1
            out.append('<ol>' + ''.join(f'<li>{inline(x)}</li>' for x in items) + '</ol>')
            continue

        if re.match(r'^\s*---+\s*$', line):
            i += 1
            continue

        para = []
        while i < len(lines) and lines[i].strip() and \
                not re.match(r'^\s*([-*]\s|\d+[.)]\s|>|\||#{2,})', lines[i]):
            para.append(lines[i].strip())
            i += 1
        if para:
            out.append(f'<p>{inline("<br>".join(para))}</p>')
        else:
            i += 1

    return ''.join(out)


def _cells(line: str) -> list[str]:
    return [c.strip() for c in line.strip().strip('|').split('|')]


def inline(text: str) -> str:
    text = html.escape(text, quote=False)
    text = re.sub(r'`([^`]+)`', r'<code>\1</code>', text)
    text = re.sub(r'\*\*([^*]+)\*\*', r'<strong>\1</strong>', text)
    text = re.sub(r'(?<!\*)\*([^*]+)\*(?!\*)', r'<em>\1</em>', text)
    # 内部锚点链接在单文件里没有意义，只留文字
    text = re.sub(r'\[([^\]]+)\]\(#[^)]*\)', r'\1', text)
    text = text.replace('&lt;br&gt;', '<br>').replace('&amp;lt;', '&lt;')
    return text


# ═══════════════════════════════════════════ 解析

def parse(path: Path) -> list[dict]:
    raw = path.read_text(encoding='utf-8').splitlines()
    source = path.stem

    # 索引部分是目录，跳过；没有「## 正文」就整篇都算正文
    start = next((n + 1 for n, l in enumerate(raw) if l.strip() == '## 正文'), 0)

    entries: list[dict] = []
    current: dict | None = None
    body: list[str] = []

    def flush():
        if current is not None:
            current['html'] = render(body)
            entries.append(current)

    for line in raw[start:]:
        m2, m3 = ENTRY_H2.match(line), ENTRY_H3.match(line)
        if m2 or m3:
            flush()
            num, form = (m2 or m3).groups()
            current, body = {
                'form': form,
                'num': num,
                'source': source,
                'cat': '',
                'gloss': '',
                'keys': search_keys(form),
            }, []
            continue
        if current is None:
            continue                                  # 章节标题等，正文开始前的内容
        if m := META.search(line):
            current['cat'], current['gloss'] = m.group(1), m.group(2)
            continue
        body.append(line)

    flush()
    return entries


# ═══════════════════════════════════════════ 输出

PAGE = """<!doctype html>
<meta charset="utf-8">
<title>%(title)s</title>
<style>
:root { color-scheme: light dark; --bg:#fff; --fg:#1a1a1a; --dim:#666; --line:#e2e2e2;
        --card:#fafafa; --hit:#fff3cd; --accent:#0a68d8; }
@media (prefers-color-scheme: dark) {
  :root { --bg:#1c1c1e; --fg:#e8e8ea; --dim:#98989d; --line:#3a3a3c;
          --card:#252528; --hit:#4a3f16; --accent:#4da3ff; } }
* { box-sizing: border-box; }
body { margin:0; padding:0 16px 40px; background:var(--bg); color:var(--fg);
       font:15px/1.7 -apple-system, "PingFang SC", "Apple SD Gothic Neo", sans-serif; }
#bar { position:sticky; top:0; background:var(--bg); padding:12px 0 8px; z-index:9;
       border-bottom:1px solid var(--line); }
#q { width:100%%; padding:9px 12px; font-size:15px; border:1px solid var(--line);
     border-radius:8px; background:var(--card); color:var(--fg); }
#count { color:var(--dim); font-size:12px; padding:6px 2px 0; }
.entry { border:1px solid var(--line); border-radius:10px; padding:14px 16px;
         margin:14px 0; background:var(--card); }
.form { font-size:17px; font-weight:600; margin:0 0 2px; }
.meta { color:var(--dim); font-size:12px; margin-bottom:10px; }
.tag { border:1px solid var(--line); border-radius:4px; padding:1px 6px; margin-right:6px; }
mark { background:var(--hit); color:inherit; border-radius:3px; padding:0 2px; }
h4,h5,h6 { margin:14px 0 6px; font-size:13px; color:var(--accent);
           letter-spacing:.03em; font-weight:600; }
table { border-collapse:collapse; margin:8px 0; font-size:13px; display:block;
        overflow-x:auto; max-width:100%%; }
th,td { border:1px solid var(--line); padding:5px 9px; text-align:left; vertical-align:top; }
th { background:rgba(128,128,128,.10); font-weight:600; }
blockquote { margin:8px 0; padding:6px 12px; border-left:3px solid var(--accent);
             background:rgba(128,128,128,.07); color:var(--dim); }
ul,ol { margin:6px 0; padding-left:22px; }
li { margin:3px 0; }
p { margin:6px 0; }
code { background:rgba(128,128,128,.15); padding:1px 5px; border-radius:4px; font-size:.9em; }
.empty { color:var(--dim); text-align:center; padding:40px 0; }
.more { color:var(--dim); font-size:13px; padding:8px 2px; }
.more a { color:var(--accent); cursor:pointer; text-decoration:none; margin-right:12px; }
</style>

<div id="bar">
  <input id="q" placeholder="%(placeholder)s" autofocus>
  <div id="count"></div>
</div>
<div id="out"></div>

<script>
const DATA = %(data)s;
const out = document.getElementById('out');
const box = document.getElementById('q');
const count = document.getElementById('count');
const LIMIT = 12;

/* 查询词里可能带标点和词尾，先剥干净 */
function clean(s) {
  return (s || '').replace(/[.,!?;:"'()\\[\\]{}…·、。，！？；：「」『』〈〉《》]/g, ' ')
                  .replace(/\\s+/g, ' ').trim();
}

/* 打分：查询词**包含**语法形式 = 强匹配（这是主用法：把变形词丢进来找语法点）；
   语法形式包含查询词 = 弱匹配（用户在敲形式的一部分）。 */
function score(entry, q) {
  let best = 0, hit = '';
  for (const k of entry.keys) {
    if (q.includes(k))            { const s = k.length * 3; if (s > best) { best = s; hit = k; } }
    else if (q.length >= 2 && k.includes(q)) { const s = q.length * 2; if (s > best) { best = s; hit = k; } }
  }
  if (entry.form.includes(q) && q.length >= 2) best = Math.max(best, q.length * 2 + 1);
  if (q.length >= 2 && (entry.gloss.includes(q) || entry.cat.includes(q)))
    best = Math.max(best, q.length);
  return { best, hit };
}

function esc(s) { return s.replace(/[&<>]/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;'}[c])); }

function render(q) {
  q = clean(q);
  if (!q) {
    count.textContent = DATA.length + ' 条语法 · 输入韩语单词或语法形式';
    out.innerHTML = '<div class="empty">把变形后的词直接丢进来，<br>比如 먹었거든요 会找到 -거든(요)</div>';
    return;
  }
  const ranked = DATA.map((e, i) => ({ e, i, ...score(e, q) }))
                     .filter(r => r.best > 0)
                     .sort((a, b) => b.best - a.best || a.i - b.i);
  if (!ranked.length) {
    count.textContent = '没有匹配';
    out.innerHTML = '<div class="empty">没找到「' + esc(q) + '」<br>'
                  + '<span style="font-size:13px">试试只输入词尾部分，或用中文搜释义</span></div>';
    return;
  }
  count.textContent = ranked.length + ' 条匹配' + (ranked.length > LIMIT ? '（显示前 ' + LIMIT + ' 条）' : '');
  out.innerHTML = ranked.slice(0, LIMIT).map(r => {
    const e = r.e;
    const title = r.hit ? esc(e.form).replace(esc(r.hit), '<mark>' + esc(r.hit) + '</mark>')
                        : esc(e.form);
    return '<div class="entry"><div class="form">' + title + '</div><div class="meta">'
         + (e.cat ? '<span class="tag">' + esc(e.cat) + '</span>' : '')
         + '<span class="tag">' + esc(e.source) + ' #' + e.num + '</span>'
         + esc(e.gloss) + '</div>' + e.html + '</div>';
  }).join('') + (ranked.length > LIMIT
      ? '<div class="more">还有 ' + (ranked.length - LIMIT) + ' 条：'
        + ranked.slice(LIMIT).map(r => '<a onclick="box.value=' + JSON.stringify(r.e.form).replace(/"/g, '&quot;')
        + ';render(box.value)">' + esc(r.e.form) + '</a>').join('') + '</div>'
      : '');
}

box.addEventListener('input', () => render(box.value));

/* 查询词优先看 ?q=，没有再看 #q= —— file:// 下不同宿主对查询串的处理不一致，两种都认 */
function queryFromURL() {
  const search = new URLSearchParams(location.search).get('q');
  if (search) return search;
  const hash = location.hash.replace(/^#/, '');
  if (hash.startsWith('q=')) return decodeURIComponent(hash.slice(2));
  return '';
}
const initial = queryFromURL();
box.value = initial;
render(initial);
addEventListener('hashchange', () => { box.value = queryFromURL(); render(box.value); });
</script>
"""


def main() -> int:
    if len(sys.argv) < 3:
        print(__doc__)
        return 1

    target = Path(sys.argv[1])
    entries: list[dict] = []
    for arg in sys.argv[2:]:
        path = Path(arg)
        found = parse(path)
        entries += found
        keyed = sum(1 for e in found if e['keys'])
        print(f'  {path.name}: {len(found)} 条，其中 {keyed} 条有搜索键')

    if not entries:
        print('没有解析到任何条目 —— 检查标题格式是不是 "## 001｜形式" 或 "### 1. 形式"')
        return 1

    target.write_text(PAGE % {
        'title': target.stem,
        'placeholder': '输入韩语单词或语法形式，例如 먹었거든요',
        'data': json.dumps(entries, ensure_ascii=False, separators=(',', ':')),
    }, encoding='utf-8')

    size = target.stat().st_size / 1024 / 1024
    print(f'\n共 {len(entries)} 条 → {target}  ({size:.1f} MB)')
    print(f'\nQuickDict 里加一条词典，网址填：\n  file://{target.resolve()}?q={{q}}')
    return 0


if __name__ == '__main__':
    sys.exit(main())
