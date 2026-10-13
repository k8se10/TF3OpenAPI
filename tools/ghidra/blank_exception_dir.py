"""Writes a copy of a 64-bit executable whose exception directory entry is emptied.

    python tools/ghidra/blank_exception_dir.py <in.exe> <out.exe>

Ghidra's import of the game's executable fails on its unwind information; with the directory entry set to
zero the import and the analysis go through (function starts are then found by analysis instead of from
the table). The copy is for analysis only: keep it outside the repository and never run it.
"""
import struct
import sys


def main():
    data = bytearray(open(sys.argv[1], 'rb').read())
    pe = struct.unpack_from('<I', data, 0x3c)[0]
    assert data[pe:pe + 4] == b'PE\0\0', 'not a PE file'
    optional = pe + 24
    assert struct.unpack_from('<H', data, optional)[0] == 0x20b, 'not a 64-bit image'
    entry = optional + 112 + 3 * 8          # data directory 3: exception table
    rva, size = struct.unpack_from('<II', data, entry)
    struct.pack_into('<II', data, entry, 0, 0)
    open(sys.argv[2], 'wb').write(data)
    print('exception directory was rva 0x%x size 0x%x; emptied in the copy' % (rva, size))


if __name__ == '__main__':
    main()
