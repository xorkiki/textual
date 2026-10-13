#!/usr/bin/env python3
"""Prevent screens from reintroducing private typography, palette, or native headers."""
from pathlib import Path
import re
import sys
root = Path(__file__).resolve().parents[1]
rules = {
    r"(?:systemName|systemImage):": "Use DesignSystemIcon through the shared icon registry.",
    r'\.(?:custom|system)\(\s*(?:"|size:)': 'Use DesignSystemFont or TextualIconStyle.',
    r'(?:UI)?Color\(\s*(?:hex|red|white|hue):': 'Add or reference a shared palette color.',
    r'\.navigationTitle\(': 'Use TextualHeader through the shared page/sheet modifiers.',
    r'UIFont\(name:': 'Keep font selection in Font+DesignSystem.swift.',
}
failures = []
for path in sorted((root / 'textual').rglob('*.swift')):
    if 'DesignSystem' in path.parts:
        continue
    for line_number, line in enumerate(path.read_text().splitlines(), 1):
        for pattern, message in rules.items():
            if re.search(pattern, line):
                failures.append(f'{path.relative_to(root)}:{line_number}: {message}')
if failures:
    print('\n'.join(failures))
    sys.exit(1)
print('Design-system boundaries passed: screen fonts, colors, and headers use shared definitions.')
