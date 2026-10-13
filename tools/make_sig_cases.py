"""Writes test cases for tools/tests/sigscan_test.cpp from the recovered function names.

    python tools/make_sig_cases.py <assert_names.tsv> <out cases.tsv> [--every N] [--image-base HEX]

One case a function: its start (relative to the image base) and the texts that identify it - the function's
own name as its assertions give it, and up to two of its asserted conditions. Only functions with one name
are taken (a function with several names holds other functions' code, and its texts are theirs too).
"""
import collections
import sys


def main():
    args = sys.argv[1:]
    every, base = 1, 0x140000000
    paths = []
    while args:
        a = args.pop(0)
        if a == '--every':
            every = int(args.pop(0))
        elif a == '--image-base':
            base = int(args.pop(0), 16)
        else:
            paths.append(a)
    names = collections.defaultdict(set)
    conds = collections.defaultdict(list)
    for line in open(paths[0], encoding='utf-8', errors='replace'):
        row = line.rstrip('\n').split('\t')
        if len(row) < 6:
            continue
        names[row[0]].add(row[2])
        if row[5] and row[5] not in conds[row[0]] and '\\' not in row[5]:
            conds[row[0]].append(row[5])
    written = 0
    with open(paths[1], 'w', encoding='utf-8', newline='\n') as out:
        for index, address in enumerate(sorted(names)):
            if len(names[address]) != 1 or index % every:
                continue
            texts = [next(iter(names[address]))] + conds[address][:2]
            out.write('%x\t%s\n' % (int(address, 16) - base, '\t'.join(texts)))
            written += 1
    print(written, 'cases')


if __name__ == '__main__':
    main()
