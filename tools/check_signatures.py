"""Check every signature in the native sources against a game executable on disk.

For each pattern found in native/src/*.cpp (strings made only of hex bytes and ?? wildcards) this reports
how many times it matches in the exe and where. A usable signature matches exactly once. Run it after
writing a new signature and against every new game build.

Usage:  python check_signatures.py <TransportFever3.exe> [source dir]
Needs:  pip install pefile
"""
import glob
import os
import re
import sys

import pefile

PATTERN = re.compile(r'"((?:[0-9A-Fa-f]{2}|\?\?)(?: (?:[0-9A-Fa-f]{2}|\?\?))* ?)"')


def signatures(path):
    """Yield (line number, pattern text) for each signature literal, joining adjacent string pieces."""
    text = open(path, encoding='utf-8').read()
    # adjacent C string literals are one string: "AA BB " "CC" -> "AA BB CC"
    joined = re.sub(r'"\s*\n\s*"', '', text)
    offset_to_line = lambda pos: joined.count('\n', 0, pos) + 1
    for m in PATTERN.finditer(joined):
        pattern = m.group(1).strip()
        if len(pattern.split()) >= 8:
            yield offset_to_line(m.start()), pattern


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    exe = sys.argv[1]
    here = os.path.dirname(os.path.abspath(__file__))
    src = sys.argv[2] if len(sys.argv) > 2 else os.path.join(here, '..', 'native', 'src')
    pe = pefile.PE(exe, fast_load=True)
    data = open(exe, 'rb').read()

    def rva_of(offset):
        for s in pe.sections:
            if s.PointerToRawData <= offset < s.PointerToRawData + s.SizeOfRawData:
                return s.VirtualAddress + offset - s.PointerToRawData
        return None

    bad = 0
    for path in sorted(glob.glob(os.path.join(src, '*.cpp'))):
        for line, pattern in signatures(path):
            rx = re.compile(b''.join(b'.' if t == '??' else re.escape(bytes([int(t, 16)])) for t in pattern.split()), re.S)
            hits = [m.start() for m in rx.finditer(data)]
            where = ', '.join(f'+0x{rva_of(h):x}' for h in hits[:4]) if hits else '-'
            status = 'ok ' if len(hits) == 1 else 'BAD'
            bad += len(hits) != 1
            print(f'{status} {len(hits)} match(es) at {where:<14} {os.path.basename(path)}:{line}  ({len(pattern.split())} bytes)')
    print(f'\n{"all signatures match exactly once" if bad == 0 else str(bad) + " signature(s) do not match exactly once"}')
    return 1 if bad else 0


if __name__ == '__main__':
    sys.exit(main())
