"""Write the in-game copy of the street-map viewer page.

The HTML viewer lives in tools/road_map.py (PAGE). The road-names mod can write the same page straight from
the game; for that it needs the page as a Lua module. This script regenerates
mod/tf3api_road_names/content/road_names/viewer_page.lua from PAGE. Run it after changing the viewer.

Usage:  python build_viewer.py
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import road_map  # noqa: E402

OUT = os.path.join(HERE, '..', 'mod', 'tf3api_road_names', 'content', 'road_names', 'viewer_page.lua')


def main():
    page = road_map.PAGE
    level = 3
    while ']' + '=' * level + ']' in page:
        level += 1
    text = ('-- Generated from PAGE in tools/road_map.py by tools/build_viewer.py. Do not edit; rebuild instead.\n'
            '-- The street-map viewer page; __TITLE__ and __DATA__ are filled in by the naming script.\n'
            'return { page = [' + '=' * level + '[\n' + page + ']' + '=' * level + '] }\n')
    open(OUT, 'w', encoding='utf-8', newline='\n').write(text)
    print('wrote', os.path.normpath(OUT), len(text), 'bytes')


if __name__ == '__main__':
    main()
