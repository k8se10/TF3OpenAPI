"""Which named functions refer to a type's type_info: finds what handles a given component or resource type.

    python tools/ghidra/who_uses_type.py <exe> <part of the decorated type name> [assert_names tsv]

Example: who_uses_type.py TransportFever3.exe "AUTransportNetwork@component@ecs" lists every place that
takes the address of that type's type_info (or of the pointer in front of it), with the recovered name of
the function around it - so whether the component has a loader (ecs::ComponentManager::Load), which
systems ask for it, and so on.
"""
import collections
import struct
import sys


def main():
    data = open(sys.argv[1], 'rb').read()
    want = sys.argv[2].encode()
    tsv = sys.argv[3] if len(sys.argv) > 3 else 're_notes/engine/local/assert_names_40420.tsv'
    pe = struct.unpack_from('<I', data, 0x3c)[0]
    count = struct.unpack_from('<H', data, pe + 6)[0]
    optional_size = struct.unpack_from('<H', data, pe + 20)[0]
    base = struct.unpack_from('<Q', data, pe + 24 + 24)[0]
    sections = []
    for i in range(count):
        at = pe + 24 + optional_size + i * 40
        vsize, va, rsize, raw, _, _, _, _, flags = struct.unpack_from('<IIIIIIHHI', data, at + 8)
        sections.append((va, vsize, rsize, raw, flags))

    def to_va(offset):
        for va, vsize, rsize, raw, _ in sections:
            if raw <= offset < raw + rsize:
                return base + va + offset - raw
        return None

    targets = {}
    at = data.find(want)
    while at >= 0:
        start = data.rfind(b'\0', 0, at) + 1
        if data[start:start + 2] == b'.?':
            name = data[start:data.index(b'\0', start)].decode('ascii', 'replace')
            info = to_va(start - 16)
            if info:
                targets[info] = name
                targets[info - 8] = name + '  (the pointer before it)'
        at = data.find(want, at + 1)
    functions = []
    names = collections.defaultdict(collections.Counter)
    for line in open(tsv, encoding='utf-8', errors='replace'):
        row = line.rstrip('\n').split('\t')
        if len(row) >= 3 and len(row[0]) == 9 and row[1].isdigit():
            names[int(row[0], 16)][row[2]] += 1
            functions.append((int(row[0], 16), int(row[1])))
    functions = sorted(set(functions))
    hits = collections.defaultdict(list)
    for va, vsize, rsize, raw, flags in sections:
        if not flags & 0x20000000:
            continue
        code = data[raw:raw + rsize]
        for i in range(len(code) - 7):
            if code[i + 1] == 0x8D and (code[i] & 0xFB) == 0x48 and (code[i + 2] & 0xC7) == 0x05:
                target = base + va + i + 7 + struct.unpack_from('<i', code, i + 3)[0]
                if target in targets:
                    hits[targets[target]].append(base + va + i)
    for name in sorted(hits):
        print(name)
        seen = collections.Counter()
        for site in hits[name]:
            owner = next((start for start, size in functions if start <= site < start + size), None)
            seen[('%x  %s' % (owner, ', '.join(n for n, _ in names[owner].most_common(2)))) if owner else 'unnamed code'] += 1
        for text, n in seen.most_common(40):
            print('   %3d  %s' % (n, text[:150]))


if __name__ == '__main__':
    main()
