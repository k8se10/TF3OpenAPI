"""Prints the pointers stored at an address of the executable (a table of functions, for one).

    python tools/ghidra/read_pointers.py <exe> <address, hex> <count> [assert_names tsv]

With a list of recovered names, each pointer that is the start of a named function gets its name.
"""
import collections
import struct
import sys


def main():
    data = open(sys.argv[1], 'rb').read()
    address, count = int(sys.argv[2], 16), int(sys.argv[3])
    names = collections.defaultdict(collections.Counter)
    if len(sys.argv) > 4:
        for line in open(sys.argv[4], encoding='utf-8', errors='replace'):
            row = line.rstrip('\n').split('\t')
            if len(row) >= 3 and len(row[0]) == 9:
                names[row[0]][row[2]] += 1
    pe = struct.unpack_from('<I', data, 0x3c)[0]
    sections = struct.unpack_from('<H', data, pe + 6)[0]
    optional = struct.unpack_from('<H', data, pe + 20)[0]
    base = struct.unpack_from('<Q', data, pe + 24 + 24)[0]
    for i in range(sections):
        at = pe + 24 + optional + i * 40
        vsize, va, rsize, raw = struct.unpack_from('<IIII', data, at + 8)
        if va <= address - base < va + max(vsize, rsize):
            offset = raw + address - base - va
            for k in range(count):
                value = struct.unpack_from('<Q', data, offset + k * 8)[0]
                key = '%x' % value
                name = names[key].most_common(1)[0][0] if key in names else ''
                print('%x  +0x%02x  %x  %s' % (address + k * 8, k * 8, value, name))
            return
    print('address not in the file')


if __name__ == '__main__':
    main()
