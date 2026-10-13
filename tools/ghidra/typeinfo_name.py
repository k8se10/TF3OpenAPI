"""Prints the type name stored in a type_info object of the executable.

    python tools/ghidra/typeinfo_name.py <exe> <address of the type_info, hex> [...]

A function that handles one type of component refers to that type's type_info; the decorated name stands
16 bytes into it (".?AUTransportNetwork@component@ecs@@" = struct ecs::component::TransportNetwork).
"""
import struct
import sys


def main():
    data = open(sys.argv[1], 'rb').read()
    pe = struct.unpack_from('<I', data, 0x3c)[0]
    count = struct.unpack_from('<H', data, pe + 6)[0]
    optional_size = struct.unpack_from('<H', data, pe + 20)[0]
    base = struct.unpack_from('<Q', data, pe + 24 + 24)[0]
    sections = []
    for i in range(count):
        at = pe + 24 + optional_size + i * 40
        vsize, va, rsize, raw = struct.unpack_from('<IIII', data, at + 8)
        sections.append((va, max(vsize, rsize), raw))
    for text in sys.argv[2:]:
        rva = int(text, 16) - base
        for va, size, raw in sections:
            if va <= rva < va + size:
                at = raw + rva - va + 16
                end = data.index(b'\0', at)
                print(text, data[at:end].decode('ascii', 'replace'))
                break
        else:
            print(text, 'not in the file')


if __name__ == '__main__':
    main()
