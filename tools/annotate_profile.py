"""Label the game-exe functions in a tf3opt_profile.txt.

The game exe has no symbols, so the in-game profiler reports its functions as TransportFever3.exe+0xRVA.
This script appends a label to each such line, from two sources:

  1. names already established by reverse engineering (--names, default re_notes/renderer/function_names.txt:
     one "0xRVA  name" per line, '#' comments allowed);
  2. the strings the function references (source-file paths, assert texts, profiler zone names), read
     from the exe on disk.

Usage:  python annotate_profile.py <TransportFever3.exe> <tf3opt_profile.txt> [--names file] [-o out.txt]
Needs:  pip install pefile capstone
"""
import argparse
import bisect
import os
import re
import sys

import pefile
from capstone import Cs, CS_ARCH_X86, CS_MODE_64
from capstone.x86 import X86_OP_MEM, X86_REG_RIP

MAX_FUNC_BYTES = 0x8000   # don't disassemble more than this per function
MAX_LABEL = 110


class Exe:
    def __init__(self, path):
        self.pe = pefile.PE(path, fast_load=True)
        self.pe.parse_data_directories(directories=[pefile.DIRECTORY_ENTRY['IMAGE_DIRECTORY_ENTRY_EXCEPTION']])
        self.data = open(path, 'rb').read()
        self.funcs = sorted((r.struct.BeginAddress, r.struct.EndAddress) for r in self.pe.DIRECTORY_ENTRY_EXCEPTION)
        self.starts = [f[0] for f in self.funcs]
        self.md = Cs(CS_ARCH_X86, CS_MODE_64)
        self.md.detail = True
        self.cache = {}

    def read(self, rva, n):
        for s in self.pe.sections:
            if s.VirtualAddress <= rva < s.VirtualAddress + s.SizeOfRawData:
                o = s.PointerToRawData + rva - s.VirtualAddress
                return self.data[o:o + n]
        return b''

    def bounds(self, rva):
        i = bisect.bisect_right(self.starts, rva) - 1
        if i >= 0 and self.funcs[i][0] <= rva < self.funcs[i][1]:
            return self.funcs[i]
        return None

    def strings(self, rva):
        if rva in self.cache:
            return self.cache[rva]
        found = []
        f = self.bounds(rva)
        if f:
            code = self.read(f[0], min(f[1] - f[0], MAX_FUNC_BYTES))
            for ins in self.md.disasm(code, f[0]):
                for op in ins.operands:
                    if op.type == X86_OP_MEM and op.mem.base == X86_REG_RIP:
                        raw = self.read(ins.address + ins.size + op.mem.disp, 160).split(b'\0')[0]
                        if len(raw) >= 5 and all(32 <= c < 127 for c in raw):
                            text = raw.decode('ascii')
                            if text not in found:
                                found.append(text)
        self.cache[rva] = found
        return found


def score(text):
    """Higher = more useful as a label."""
    if re.search(r'\.(cpp|h|hpp|inl)$', text):
        return 3
    if '::' in text:
        return 3
    if re.fullmatch(r'[A-Za-z_][\w ]{3,40}', text):
        return 2
    return 1


def label(exe, names, rva):
    if rva in names:
        return names[rva]
    strs = sorted(exe.strings(rva), key=lambda t: -score(t))
    if not strs:
        return ''
    out = ' | '.join(os.path.basename(s) if re.search(r'[\\/]', s) else s for s in strs[:3])
    return '~ ' + out[:MAX_LABEL]


def load_names(path):
    names = {}
    if not path or not os.path.exists(path):
        return names
    for line in open(path, encoding='utf-8'):
        line = line.split('#')[0].strip()
        if not line:
            continue
        addr, _, name = line.partition(' ')
        names[int(addr, 16)] = name.strip()
    return names


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('exe')
    ap.add_argument('profile')
    ap.add_argument('--names', default=os.path.join(here, '..', 're_notes', 'renderer', 'function_names.txt'))
    ap.add_argument('-o', '--out')
    args = ap.parse_args()

    exe = Exe(args.exe)
    names = load_names(args.names)
    exe_name = re.escape(os.path.basename(args.exe))
    pattern = re.compile(exe_name + r'\+0x([0-9a-fA-F]+)\s*$', re.IGNORECASE)

    lines = []
    for line in open(args.profile, encoding='utf-8', errors='replace'):
        line = line.rstrip('\n')
        m = pattern.search(line)
        if m:
            text = label(exe, names, int(m.group(1), 16))
            if text:
                line = f'{line}  {text}'
        lines.append(line)

    out = args.out or os.path.splitext(args.profile)[0] + '_annotated.txt'
    open(out, 'w', encoding='utf-8').write('\n'.join(lines) + '\n')
    print(out)


if __name__ == '__main__':
    sys.exit(main())
