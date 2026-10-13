"""Says, for each byte signature of the native code, which recovered function it lands in.

    python tools/check_signatures.py <exe> > sigs.txt
    python tools/ghidra/name_signatures.py sigs.txt [assert_names tsv] [functions_by_source tsv]

A signature whose function carries assertion texts can also be found by those texts when its bytes change
(sigscan::FindByTexts); this lists which do, and how many distinct conditions each such function has.
"""
import collections
import re
import sys

BASE = 0x140000000


def main():
    names_path = sys.argv[2] if len(sys.argv) > 2 else 're_notes/engine/local/assert_names_40420.tsv'
    source_path = sys.argv[3] if len(sys.argv) > 3 else 're_notes/engine/local/functions_by_source_40420.tsv'
    functions = {}
    for line in open(names_path, encoding='utf-8', errors='replace'):
        row = line.rstrip('\n').split('\t')
        if len(row) >= 6:
            entry = functions.setdefault(int(row[0], 16), [int(row[1]), collections.Counter(), set()])
            entry[1][row[2]] += 1
            entry[2].add(row[5])
    by_source = collections.defaultdict(set)
    for line in open(source_path, encoding='utf-8', errors='replace'):
        row = line.rstrip('\n').split('\t')
        if len(row) >= 3:
            by_source[int(row[1], 16)].add((row[0], int(row[2])))
    for line in open(sys.argv[1], encoding='utf-8', errors='replace'):
        m = re.search(r'at \+0x([0-9a-f]+)\s+(\S+)', line)
        if not m:
            continue
        address = BASE + int(m.group(1), 16)
        named = [(start, f) for start, f in functions.items() if start <= address < start + f[0]]
        if named:
            start, f = named[0]
            where = 'at its start' if start == address else '+%#x into it' % (address - start)
            print('%-22s %#x  %s (%s; %d conditions, %d names)' % (m.group(2), address, f[1].most_common(1)[0][0], where, len(f[2]), len(f[1])))
            continue
        files = sorted(set(path.rsplit('/', 1)[-1] for start, entries in by_source.items() for path, size in entries if start <= address < start + size))
        print('%-22s %#x  %s' % (m.group(2), address, 'in a function of ' + ', '.join(files) if files else 'no recovered name'))


if __name__ == '__main__':
    main()
