"""Lists the recovered function names of the source files whose path contains any of the given texts.

    python tools/ghidra/names_in.py <text> [<text> ...] [--conds N] [--tsv path]

One line a function: address, size, name, first-last asserted line, and up to N of its asserted conditions.
"""
import collections
import sys


def main():
    args = sys.argv[1:]
    conds, tsv, wants = 2, 're_notes/engine/assert_names_40408.tsv', []
    while args:
        a = args.pop(0)
        if a == '--conds':
            conds = int(args.pop(0))
        elif a == '--tsv':
            tsv = args.pop(0)
        else:
            wants.append(a)
    files = collections.defaultdict(lambda: collections.defaultdict(list))
    for line in open(tsv, encoding='utf-8', errors='replace'):
        row = line.rstrip('\n').split('\t')
        if len(row) < 6 or not any(w in row[3] for w in wants):
            continue
        files[row[3]][(row[0], row[1], row[2])].append((int(row[4]), row[5]))
    for path in sorted(files):
        print('## ' + path)
        for (address, size, name), sites in sorted(files[path].items(), key=lambda item: min(s[0] for s in item[1])):
            sites = sorted(set(sites))
            shown = ' ;; '.join(c[:70] for _, c in sites[:conds] if c)
            print('  %s %6s %s  L%d-%d%s' % (address, size, name, sites[0][0], sites[-1][0], ' | ' + shown if shown else ''))


if __name__ == '__main__':
    main()
