"""Looks a function up in the older game's list, which gives full signatures (return and parameter types).

    python tools/ghidra/signature_of.py <part of a name> [...] [--tsv re_notes/engine/local/tf2_assert_names.tsv]

The older game (Transport Fever 2) was built with its assertions in as well, and there each assertion
carries the function's whole signature, not only its name. Much of the engine is the same code, so the
signature of a function there is the first thing to try for the same-named function of the newer game.
Prints each distinct signature whose text contains every given part, with its source file and where it
was seen in the older executable.
"""
import collections
import sys


def main():
    args = sys.argv[1:]
    tsv = 're_notes/engine/local/tf2_assert_names.tsv'
    if '--tsv' in args:
        i = args.index('--tsv')
        tsv = args[i + 1]
        del args[i:i + 2]
    found = collections.OrderedDict()
    for line in open(tsv, encoding='utf-8', errors='replace'):
        row = line.rstrip('\n').split('\t')
        if len(row) >= 5 and all(a in row[2] for a in args):
            entry = found.setdefault(row[2], [row[3], set(), set()])
            entry[1].add(row[0])
            entry[2].add(int(row[4]))
    for signature, (path, addresses, lines) in found.items():
        print(signature)
        print('    %s  lines %d-%d  at %s' % (path, min(lines), max(lines), ', '.join(sorted(addresses)[:4])))


if __name__ == '__main__':
    main()
