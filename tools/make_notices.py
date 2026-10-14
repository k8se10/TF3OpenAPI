"""Gives every TF3OpenAPI mod in mod/ its notice: content/gui/tf3api_notice/notice.script.lua + notice.res.lua, from
the template converter/notice.script.lua (the converter writes the same into converted mods). In the game the notice
opens one window when TF3OpenAPI's native layer is not running, naming the mods that need it.

Run from the repository root after changing the template or adding a mod:
    python tools/make_notices.py
"""
import json
import os
import re

root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
template = open(os.path.join(root, 'converter', 'notice.script.lua'), encoding='utf-8').read()


def lua_string(text):
    return '"' + text.replace('\\', '\\\\').replace('"', '\\"').replace('\n', '\\n') + '"'


RES = '''-- Mounts the TF3OpenAPI notice in the game bar (it draws nothing there; it opens a window when something is missing).
function data()
	return {
		type = "react-plugin ::GameBarInfoDisplayExtension",
		data = {
			filePath = "%s::/gui/tf3api_notice/notice.script@Host",
			priority = 10,
		}
	}
end
'''

for mod in sorted(os.listdir(os.path.join(root, 'mod'))):
    folder = os.path.join(root, 'mod', mod)
    info_path = os.path.join(folder, 'mod.json')
    if not mod.startswith('tf3api_') or not os.path.isfile(info_path):
        continue
    info = json.load(open(info_path, encoding='utf-8'))
    values = {
        '@MOD_ID@': lua_string(mod), '@MOD_NAME@': lua_string(info.get('name') or mod), '@KIND@': lua_string('api'),
        '@FOLDER@': lua_string(''), '@WRITER@': 'written by tools/make_notices.py',
    }
    text = re.sub(r'@[A-Z_]+@', lambda m: values[m.group(0)], template)
    out = os.path.join(folder, 'content', 'gui', 'tf3api_notice')
    os.makedirs(out, exist_ok=True)
    open(os.path.join(out, 'notice.script.lua'), 'w', encoding='utf-8', newline='\n').write(text)
    open(os.path.join(out, 'notice.res.lua'), 'w', encoding='utf-8', newline='\n').write(RES % mod)
    # a mod with a _content.json lists its files there: the game reads only those
    listing = os.path.join(folder, '_content.json')
    if os.path.isfile(listing):
        content = json.load(open(listing, encoding='utf-8'))
        files = content.get('files') or []
        for name in ('gui/tf3api_notice/notice.res.lua', 'gui/tf3api_notice/notice.script.lua'):
            if name not in files:
                files.append(name)
        content['files'] = sorted(files)
        open(listing, 'w', encoding='utf-8', newline='\n').write(json.dumps(content, indent=4) + '\n')
    print(mod + ': notice written')
