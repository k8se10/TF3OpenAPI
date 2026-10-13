"""Matches functions between two builds of the game by what their assertions say.

    python tools/ghidra/match_builds.py <assert_names of build A> <assert_names of build B> [--out pairs.tsv]

A function's identity is the set of (name, asserted condition) pairs found in it - texts that do not change
when the code is compiled anew. A function of build A is matched when exactly one function of build B has
the same identity and no other function of build A shares it. Prints how many functions match one-to-one,
how many are the same in several places (generic code compiled many times), and how many exist in one
build only. With --out, writes the pairs: address in A, address in B, a name.
"""
import collections
import sys


def identities(path):
    sets = collections.defaultdict(set)
    for line in open(path, encoding='utf-8', errors='replace'):
        row = line.rstrip('\n').split('\t')
        if len(row) >= 6:
            sets[row[0]].add((row[2], row[5]))
    by_identity = collections.defaultdict(list)
    for address, identity in sets.items():
        by_identity[frozenset(identity)].append(address)
    return by_identity


def main():
    args = sys.argv[1:]
    out = None
    if '--out' in args:
        i = args.index('--out')
        out = args[i + 1]
        del args[i:i + 2]
    a, b = identities(args[0]), identities(args[1])
    functions_a = sum(len(v) for v in a.values())
    functions_b = sum(len(v) for v in b.values())
    pairs, repeated, only_a = [], 0, 0
    for identity, addresses in a.items():
        others = b.get(identity)
        if others is None:
            only_a += len(addresses)
        elif len(addresses) == 1 and len(others) == 1:
            pairs.append((addresses[0], others[0], sorted(identity)[0][0]))
        else:
            repeated += len(addresses)
    only_b = sum(len(v) for identity, v in b.items() if identity not in a)
    print('build A: %d functions with assertions; build B: %d' % (functions_a, functions_b))
    print('matched one-to-one: %d (%.1f%% of A)' % (len(pairs), 100.0 * len(pairs) / max(1, functions_a)))
    print('same texts in several functions (not matched singly): %d' % repeated)
    print('only in A: %d; only in B: %d' % (only_a, only_b))
    if pairs:
        shifts = collections.Counter(int(q, 16) - int(p, 16) for p, q, _ in pairs)
        print('most common address shifts: ' + ', '.join('%+#x x%d' % item for item in shifts.most_common(5)))
    if out:
        with open(out, 'w', encoding='utf-8', newline='\n') as f:
            for p, q, name in sorted(pairs):
                f.write('%s\t%s\t%s\n' % (p, q, name))


if __name__ == '__main__':
    main()
