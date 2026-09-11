#!/usr/bin/env python3
"""Reject app-owned style literals outside lib/src/theme (stdlib only).

Zero geometry, responsive dimensions, protocol values, and transparent ownership
surfaces are not theme overrides. Strings and comments are not checked.
"""
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
# Preserve offsets so errors point to source lines, including multiline calls.
NON_CODE = re.compile(r'''//[^\n]*|/\*[\s\S]*?\*/|r?(?:\x27\x27\x27[\s\S]*?\x27\x27\x27|"""[\s\S]*?"""|\x27(?:\\.|[^\x27\\])*\x27|"(?:\\.|[^"\\])*")''')
NUMBER = re.compile(r'(?<![\w.])(?:\d+(?:\.\d+)?)(?![\w.])')
CALLS = re.compile(r'\b(?:EdgeInsets(?:Directional)?\.\w+|(?:BorderRadius|Radius)\.circular|Border\.all|BorderSide|TextStyle|StrutStyle|Icon|IconButton)\(')
RAW_RECIPE = re.compile(r'\b(?:FontWeight\.w\d+|Colors\.(?!transparent\b)\w+|Color(?:\.fromARGB|\.fromRGBO)?\s*\(|(?:\w+Button)\.styleFrom\s*\(|(?:ButtonStyle|MenuStyle|OutlineInputBorder|BoxShadow|LinearGradient|RadialGradient|SliderThemeData)\s*\()')
STYLE_VALUE = re.compile(r'\b(?:fontSize|fontWeight|letterSpacing|fontFamily|strokeWidth|decorationThickness|alpha|opacity|iconSize|cursorWidth|cursorHeight|minTileHeight|toolbarHeight)\s*[:=]\s*([^,;\n)]+)')


def call_end(code, start):
    depth = 0
    for i in range(code.index('(', start), len(code)):
        depth += (code[i] == '(') - (code[i] == ')')
        if not depth:
            return i + 1
    return len(code)


def violations(source):
    code = NON_CODE.sub(lambda m: re.sub(r'[^\n]', ' ', m[0]), source)
    hits = [(m.start(), 'local style recipe or color') for m in RAW_RECIPE.finditer(code)]
    for m in re.finditer(r'\bfontFamily:\s*', code):
        if source[m.start():].split(':', 1)[1].lstrip().startswith((chr(34), chr(39))):
            hits.append((m.start(), 'literal font family'))
    for m in STYLE_VALUE.finditer(code):
        if any(float(n[0]) != 0 for n in NUMBER.finditer(m[1])):
            hits.append((m.start(), 'literal style value'))
    for m in CALLS.finditer(code):
        block = code[m.start():call_end(code, m.start())]
        if block.startswith(('EdgeInsets', 'BorderRadius', 'Radius')):
            values = [block]
        elif block.startswith(('Border.', 'BorderSide')):
            values = re.findall(r'\bwidth:\s*([^,\n)]+)', block)
        elif block.startswith(('TextStyle', 'StrutStyle')):
            values = re.findall(r'\bheight:\s*([^,\n)]+)', block)
        else:
            values = re.findall(r'\b(?:size|iconSize):\s*([^,\n)]+)', block)
        if any(float(n[0]) != 0 for v in values for n in NUMBER.finditer(v)):
            hits.append((m.start(), 'literal spacing, shape, stroke, or text geometry'))
    return sorted(set((source.count('\n', 0, offset) + 1, reason) for offset, reason in hits))


def main():
    # Regression check: multiline and conditional overrides must not bypass this check.
    assert violations('TextStyle(\n fontSize: compact ? 11 : 12,\n)')
    assert violations('EdgeInsets.only(top: media.padding.top + 12)')
    assert violations("TextStyle(fontFamily: 'Arial')")
    assert violations('Color.fromARGB(255, 0, 0, 0)')
    assert not violations('// fontSize: 12\nTextStyle(fontSize: AppFontSizes.body)')
    assert not violations('Color.lerp(a, b, progress)')
    paths = sorted((ROOT / 'apps/mobile/lib').rglob('*.dart'))
    failures = []
    for path in paths:
        if (ROOT / 'apps/mobile/lib/src/theme') in path.parents:
            continue
        failures += [f'{path.relative_to(ROOT)}:{line}: {reason}' for line, reason in violations(path.read_text(encoding="utf-8"))]
    print('\n'.join(failures) if failures else f'Theme check passed ({len(paths)} Dart files scanned).')
    return bool(failures)


if __name__ == '__main__':
    sys.exit(main())
