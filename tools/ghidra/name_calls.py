"""Puts the recovered function names beside the addresses in a CallGraph.java output.

    python tools/ghidra/name_calls.py <callgraph output> [re_notes/engine/assert_names_40408.tsv]
"""
import collections
import sys


def names(path):
    best = collections.defaultdict(collections.Counter)
    for line in open(path, encoding='utf-8', errors='replace'):
        row = line.rstrip('\n').split('\t')
        if len(row) >= 4:
            best[row[0]][row[2] + '  [' + row[3].rsplit('/', 1)[-1] + ']'] += 1
    return {address: counts.most_common(1)[0][0] for address, counts in best.items()}


def main():
    table = names(sys.argv[2] if len(sys.argv) > 2 else 're_notes/engine/assert_names_40408.tsv')
    for line in open(sys.argv[1], encoding='utf-8', errors='replace'):
        parts = line.split()
        address = parts[1] if len(parts) > 1 else ''
        print(line.rstrip('\n') + ('    ' + table[address] if address in table else ''))


if __name__ == '__main__':
    main()
