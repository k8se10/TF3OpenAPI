"""Compile the overlay shaders and regenerate native/src/overlay_shaders.h.

Needs glslc from the Vulkan SDK (on PATH, or under %VULKAN_SDK%\\Bin). The generated header is committed, so
this only has to be run after editing native/shaders/overlay.vert or overlay.frag.

Usage:  python build_shaders.py
"""
import os
import shutil
import struct
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
SHADERS = os.path.join(HERE, '..', 'native', 'shaders')
OUT = os.path.join(HERE, '..', 'native', 'src', 'overlay_shaders.h')


def find_glslc():
    found = shutil.which('glslc')
    if found:
        return found
    sdk = os.environ.get('VULKAN_SDK')
    if sdk and os.path.exists(os.path.join(sdk, 'Bin', 'glslc.exe')):
        return os.path.join(sdk, 'Bin', 'glslc.exe')
    sys.exit('glslc not found - install the Vulkan SDK or put glslc on PATH')


def main():
    glslc = find_glslc()
    lines = ['// Generated from native/shaders/overlay.vert and overlay.frag by glslc (Vulkan SDK). Do not edit;',
             '// rebuild with tools/build_shaders.py.', '#pragma once', '', '#include <cstdint>', '']
    with tempfile.TemporaryDirectory() as tmp:
        for stage in ('vert', 'frag'):
            spv = os.path.join(tmp, stage + '.spv')
            subprocess.run([glslc, '-O', os.path.join(SHADERS, 'overlay.' + stage), '-o', spv], check=True)
            data = open(spv, 'rb').read()
            words = struct.unpack(f'<{len(data) // 4}I', data)
            lines.append(f'inline constexpr uint32_t kOverlay{stage.capitalize()}Spv[] = {{')
            for i in range(0, len(words), 10):
                lines.append('    ' + ', '.join(f'0x{w:08x}' for w in words[i:i + 10]) + ',')
            lines += ['};', '']
    open(OUT, 'w', newline='\n').write('\n'.join(lines))
    print('wrote', os.path.normpath(OUT))


if __name__ == '__main__':
    main()
