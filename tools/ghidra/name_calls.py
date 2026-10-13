"""Puts the recovered function names beside the addresses in a CallGraph.java output.

    python tools/ghidra/name_calls.py <callgraph output> [re_notes/engine/assert_names_40420.tsv]

A function can carry several names: its own, and those of small functions the compiler put inside it.
The name shown is the one found at the fewest addresses of the whole program (a helper put inside many
functions is found at many), then one from a .cpp file before one from a header, then the one with the
most assertion sites here. "+n" after it says how many other names the function carries.
"""
import collections
import sys


def names(path):
    per_address = collections.defaultdict(collections.Counter)
    files = {}
    spread = collections.defaultdict(set)
    for line in open(path, encoding='utf-8', errors='replace'):
        row = line.rstrip('\n').split('\t')
        if len(row) >= 4:
            per_address[row[0]][row[2]] += 1
            files[(row[0], row[2])] = row[3]
            spread[row[2]].add(row[0])
    out = {}
    for address, counts in per_address.items():
        best = min(counts, key=lambda n: (len(spread[n]), not files[(address, n)].endswith('.cpp'), -counts[n], n))
        more = len(counts) - 1
        out[address] = '%s  [%s]%s' % (best, files[(address, best)].rsplit('/', 1)[-1], '  +%d' % more if more else '')
    return out


def main():
    table = names(sys.argv[2] if len(sys.argv) > 2 else 're_notes/engine/assert_names_40420.tsv')
    for line in open(sys.argv[1], encoding='utf-8', errors='replace'):
        parts = line.split()
        address = parts[1] if len(parts) > 1 else ''
        print(line.rstrip('\n') + ('    ' + table[address] if address in table else ''))


if __name__ == '__main__':
    main()
