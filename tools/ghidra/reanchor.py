"""Rewrites the function addresses in notes from one build to another.

    python tools/ghidra/reanchor.py <pairs.tsv from match_builds.py> <old assert_names> <new assert_names> <file.md> [...]

An address is replaced when match_builds paired its function; failing that, when the old function's names
all point at one function of the new build. What cannot be carried over is listed and left as it is.
"""
import collections
import re
import sys


def load(path):
    names = collections.defaultdict(set)
    for line in open(path, encoding='utf-8', errors='replace'):
        row = line.rstrip('\n').split('\t')
        if len(row) >= 3:
            names[row[0]].add(row[2])
    return names


def main():
    pairs = dict(line.split('\t')[:2] for line in open(sys.argv[1], encoding='utf-8') if '\t' in line)
    old, new = load(sys.argv[2]), load(sys.argv[3])
    where = collections.defaultdict(set)
    for address, names in new.items():
        for name in names:
            where[name].add(address)
    for path in sys.argv[4:]:
        text = open(path, encoding='utf-8', newline='').read()
        missed, moved = [], 0

        def swap(match):
            nonlocal moved
            address = match.group(1).lower()
            target = pairs.get(address)
            if target is None and address in old:
                candidates = None
                for name in old[address]:
                    found = where.get(name, set())
                    candidates = found if candidates is None else candidates & found
                if candidates and len(candidates) == 1:
                    target = next(iter(candidates))
            if target is None:
                missed.append(address)
                return match.group(0)
            moved += 1
            return '0x' + target

        text = re.sub(r'0x(14[0-9a-fA-F]{7})\b', swap, text)
        open(path, 'w', encoding='utf-8', newline='').write(text)
        print('%s: %d addresses carried over, %d not: %s' % (path, moved, len(missed), ' '.join(sorted(set(missed)))))


if __name__ == '__main__':
    main()
