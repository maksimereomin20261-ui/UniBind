"""Static guard for the reported dangling Else; NOT an AutoHotkey parser."""
from pathlib import Path
import re

root = Path(__file__).resolve().parent.parent
problems = []
for source in root.rglob('*.ahk'):
    lines = source.read_text(encoding='utf-8-sig').splitlines()
    for i, line in enumerate(lines):
        if re.match(r'^\s*else\b', line, re.I):
            j = i - 1
            while j >= 0 and (not lines[j].strip() or lines[j].lstrip().startswith(';')):
                j -= 1
            if j >= 0 and re.match(r'^\s*try\b', lines[j], re.I):
                problems.append(f'{source.relative_to(root)}:{i + 1}')
if problems:
    raise SystemExit('Ambiguous unbraced if/try/else: ' + ', '.join(problems))
print('No ambiguous unbraced if/try/else found. Native AHK validation still required.')
