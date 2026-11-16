#!/usr/bin/env python3
"""Dựng site/en/index.html từ site/index.html.

    python3 scripts/site-i18n/build-en.py

vi-runs.json: các cụm chữ tiếng Việt trên trang (cụm thứ i), en_runs.py: bản dịch (EN[i]).
Sửa trang tiếng Việt mà thêm hoặc đổi câu thì thêm cặp tương ứng vào hai file này rồi chạy lại.
Cuối cùng script in ra những chữ tiếng Việt còn sót để bổ sung.
"""
import json, os, re
HERE = os.path.dirname(os.path.abspath(__file__))
SITE = os.path.join(HERE, '..', '..', 'site')
ns = {}
exec(open(os.path.join(HERE, 'en_runs.py'), encoding='utf-8').read(), ns)
EN = [e.replace("'", "’") for e in ns['EN']]  # nháy cong: không làm vỡ chuỗi JS bọc nháy đơn
VI_RUNS = json.load(open(os.path.join(HERE, 'vi-runs.json'), encoding='utf-8'))
assert len(VI_RUNS) == len(EN), (len(VI_RUNS), len(EN))

src = open(os.path.join(SITE, 'index.html'), encoding='utf-8').read()
en = src.replace('<a class="lang" href="en/" hreflang="en" lang="en">EN</a>',
                 '<a class="lang" href="../" hreflang="vi" lang="vi">VI</a>', 1)
en = en.replace('<html lang="vi">', '<html lang="en">', 1)
en = en.replace('<title>Roost: notch cho MacBook</title>', '<title>Roost: your MacBook notch, doing more</title>', 1)
# Chỗ đặc biệt: chuỗi ghép biến, ngày tháng và chữ không dấu (bộ lọc theo dấu bỏ sót).
PRE = [('`còn ${left} giây`', '`${left}s left`'), ('T2 16 thg 11', 'Mon Nov 16'),
       ("'Pin', 'Giờ'", "'Battery', 'Giờ'"), ('<span class="wait">khay</span>', '<span class="wait">files</span>')]
# Chữ không dấu: thay SAU các cụm, không thì cắt ngang câu dài chứa nó (vd "Khay file kéo thả").
POST = [('Xem demo →', 'See demo →'), ('Khay file', 'File tray'), ("'Tab Khay'", "'Tray tab'"),
        ("'Chung'", "'General'"), ('hop-…ng.pdf', 'contract.pdf'), ('ghi-…hu.txt', 'notes.txt')]
for a, b in PRE:
    en = en.replace(a, b)
for d, e in zip(['T6', 'T7', 'CN', 'T2', 'T3', 'T4', 'T5'], ['Fri', 'Sat', 'Sun', 'Mon', 'Tue', 'Wed', 'Thu']):
    en = en.replace(f'>{d}<', f'>{e}<')
for v, e in sorted(zip(VI_RUNS, EN), key=lambda p: -len(p[0])):
    if v in ('còn', 'giây'):
        continue
    en = en.replace(v, e)
for a, b in POST:
    en = en.replace(a, b)
for q in ['"', "'", '(', '`']:
    en = en.replace(q + 'assets/', q + '../assets/')
# Ảnh SVG minh hoạ có chữ: dựng bản tiếng Anh trong assets/en/ rồi cho trang /en/ trỏ vào đó.
from xml.sax.saxutils import escape
ns2 = {}
exec(open(os.path.join(HERE, 'svg_en.py'), encoding='utf-8').read(), ns2)
SVG_EN = ns2['SVG_EN']
AS = os.path.join(SITE, 'assets')
os.makedirs(os.path.join(AS, 'en'), exist_ok=True)
svg_names = []
for name in sorted(os.listdir(AS)):
    if not name.endswith('.svg'):
        continue
    svg = open(os.path.join(AS, name), encoding='utf-8').read()
    def sub(m):
        raw = m.group(1); t = raw.strip()
        return '>' + raw.replace(t, escape(SVG_EN[t])) + '<' if t in SVG_EN else m.group(0)
    out = re.sub(r'>([^<>]+)<', sub, svg)
    if out != svg:
        open(os.path.join(AS, 'en', name), 'w', encoding='utf-8').write(out)
        svg_names.append(name)
for name in svg_names:
    en = en.replace('../assets/' + name, '../assets/en/' + name)
en = en.replace("'../assets/' + src", "'../assets/en/' + src")
os.makedirs(os.path.join(SITE, 'en'), exist_ok=True)
open(os.path.join(SITE, 'en', 'index.html'), 'w', encoding='utf-8').write(en)

VI = set('àáạảãâầấậẩẫăằắặẳẵèéẹẻẽêềếệểễìíịỉĩòóọỏõôồốộổỗơờớợởỡùúụủũưừứựửữỳýỵỷỹđ'
         'ÀÁẠẢÃÂẦẤẬẨẪĂẰẮẶẲẴÈÉẸẺẼÊỀẾỆỂỄÌÍỊỈĨÒÓỌỎÕÔỒỐỘỔỖƠỜỚỢỞỠÙÚỤỦŨƯỪỨỰỬỮỲÝỴỶỸĐ')
body = re.sub(r'<!--.*?-->|/\*.*?\*/', '', en, flags=re.S)
body = re.sub(r'(?m)^\s*//.*$', '', body)
left = sorted({t.strip() for t in re.findall(r"[^'\"`<>{}()\[\];=\n|$]+", body)
               if any(c in VI for c in t) and 'Tiếng Việt' not in t})
print('site/en/index.html đã dựng.', 'Còn sót:' if left else 'Không còn chữ tiếng Việt.', *left, sep='\n')
