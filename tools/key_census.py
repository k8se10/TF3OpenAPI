"""Census of every key the older games' models and materials use, against what the newer game knows.

    python -I tools/key_census.py --old <dir or zip> [...] --new <dir or zip> [...]
                                  --new-exe <TransportFever3.exe> --new-scripts <zip> [...]
                                  [--converter converter/convert.lua] [--out report.md] [--kind mdl|mtl]
                                  [--old-kind lua --new-kind bridge]

"Old" are files of Transport Fever 1 / 2 (the game's own archives and any old mods); "new" are the newer
game's own files of the same kind. Every file is read as a Lua table without running it, and each key is
taken with its path (metadata.railVehicle.configs[].axles). A path of the old files is then put in one of
these classes:

  same        the newer game's own files use the same path
  script      the path's last key is named in the newer game's load-time scripts (it is upgraded on load)
  exe         ... or in the newer game's executable (it is read natively)
  converter   ... or in the converter's rules
  NOWHERE     none of these: nothing in the newer game or the converter knows the key

The NOWHERE list is the converter's to-do; rerun this with a new old mod to see what of it would be lost.
"""
import collections
import os
import re
import sys
import zipfile

TOKEN = re.compile(r'''\s*(?:(--\[\[.*?\]\]|--[^\n]*)|("(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*')|(\[\[.*?\]\])|([A-Za-z_][A-Za-z0-9_]*)|(\d[\w.]*|\.\d[\w.]*)|(\.\.\.|\.\.|==|~=|<=|>=|.))''', re.S)


def tokens(text):
    pos, out = 0, []
    while pos < len(text):
        m = TOKEN.match(text, pos)
        if not m:
            break
        pos = m.end()
        if m.group(1):
            continue
        if m.group(2) or m.group(3):
            out.append(('s', m.group(2) or m.group(3)))
        elif m.group(4):
            out.append(('n', m.group(4)))
        elif m.group(5):
            out.append(('d', m.group(5)))
        elif m.group(6) and m.group(6).strip():
            out.append(('p', m.group(6)))
    return out


class Reader:
    def __init__(self, toks, sink, values):
        self.t, self.i, self.sink, self.values = toks, 0, sink, values

    def peek(self, k=0):
        return self.t[self.i + k] if self.i + k < len(self.t) else ('e', '')

    def table(self, path):
        # at '{'
        self.i += 1
        while self.i < len(self.t):
            kind, text = self.peek()
            if (kind, text) == ('p', '}'):
                self.i += 1
                return
            key = None
            if kind == 'n' and self.peek(1) == ('p', '='):
                key = text
                self.i += 2
            elif (kind, text) == ('p', '[') and self.peek(1)[0] in 'sd' and self.peek(2) == ('p', ']') and self.peek(3) == ('p', '='):
                raw = self.peek(1)
                key = raw[1].strip('"\'') if raw[0] == 's' else '[]'
                if not re.match(r'^[A-Za-z_][A-Za-z0-9_]*$', key):
                    key = '[]'
                self.i += 4
            here = path + ('.' + key if key and key != '[]' else '[]') if (key or True) else path
            if key and key != '[]':
                self.sink[here] += 1
            self.value(here)
            if self.peek() in (('p', ','), ('p', ';')):
                self.i += 1

    def value(self, path):
        kind, text = self.peek()
        if (kind, text) == ('p', '{'):
            self.table(path)
            self.skip_rest()
            return
        if kind == 's' and self.peek(1) in (('p', ','), ('p', '}'), ('p', ';')):
            word = text.strip('"\'')
            if re.match(r'^[A-Z][A-Z0-9_]{2,40}$', word):
                self.values[path + ' = ' + word] += 1
        self.skip_rest()

    def skip_rest(self):
        depth = 0
        while self.i < len(self.t):
            kind, text = self.peek()
            if kind == 'p':
                if text in '({[':
                    if text == '{' and depth == 0:
                        # a table inside an expression (a call's argument): read it too, without a key path
                        self.table('?')
                        continue
                    depth += 1
                elif text in ')}]':
                    if depth == 0:
                        return
                    depth -= 1
                elif text in ',;' and depth == 0:
                    return
            self.i += 1


def read_text(text, sink, values):
    toks = tokens(text)
    # the table that "function data() return { ... } end" returns: the first '{' after a 'return'
    for i, tok in enumerate(toks):
        if tok == ('n', 'return') and i + 1 < len(toks) and toks[i + 1] == ('p', '{'):
            reader = Reader(toks, sink, values)
            reader.i = i + 1
            reader.table('')
            return True
    return False


def sources(paths, kind):
    for path in paths:
        if os.path.isdir(path):
            for d, _, files in os.walk(path):
                for f in files:
                    full = os.path.join(d, f)
                    if f.lower().endswith('.zip'):
                        yield from sources([full], kind)
                    elif f.lower().endswith('.' + kind) or f.lower().endswith('.' + kind + '.lua'):
                        try:
                            yield full, open(full, encoding='utf-8', errors='replace').read()
                        except OSError:
                            pass
        elif path.lower().endswith('.zip'):
            try:
                z = zipfile.ZipFile(path)
            except Exception:
                continue
            for n in z.namelist():
                if n.lower().endswith('.' + kind) or n.lower().endswith('.' + kind + '.lua'):
                    yield path + '!' + n, z.read(n).decode('utf-8', 'replace')


def normal(path, values):
    """Parts nested in parts are one path; the events a part moves on are values, not keys."""
    path = re.sub(r'(\.children\[\])+', '.children[]', path)
    m = re.search(r'\.animations\.([A-Za-z_0-9]+)', path)
    if m:
        values['(event a part moves on) = ' + m.group(1)] += 0   # counted once a file below
        values['(event a part moves on) = ' + m.group(1)] = 1
        path = path[:m.start()] + '.animations.<event>' + path[m.end():]
    return path


def census(paths, kind):
    keys, values, files, failed = collections.Counter(), collections.Counter(), 0, 0
    per_file = collections.Counter()
    for name, text in sources(paths, kind):
        sink, vals = collections.Counter(), collections.Counter()
        if read_text(text, sink, vals):
            files += 1
            merged = collections.Counter()
            for k in sink:
                merged[normal(k, vals)] += sink[k]
            for k in merged:
                keys[k] += merged[k]
                per_file[k] += 1
            for v in vals:
                values[v] += 1
        else:
            failed += 1
    return keys, per_file, values, files, failed


def words_of(paths):
    found = set()
    for path in paths:
        if path.lower().endswith('.zip'):
            try:
                z = zipfile.ZipFile(path)
            except Exception:
                continue
            for n in z.namelist():
                if n.lower().endswith(('.lua', '.tl')) and not n.lower().endswith(('.mdl', '.mtl')):
                    found.update(re.findall(r'[A-Za-z_][A-Za-z0-9_]{2,60}', z.read(n).decode('utf-8', 'replace')))
        elif os.path.isfile(path):
            data = open(path, 'rb').read()
            found.update(m.decode() for m in re.findall(rb'(?<![A-Za-z0-9_])[A-Za-z_][A-Za-z0-9_]{2,60}(?![A-Za-z0-9_])', data))
    return found


def main():
    args = sys.argv[1:]
    opts = collections.defaultdict(list)
    current = None
    for a in args:
        if a.startswith('--'):
            current = a[2:]
        else:
            opts[current].append(a)
    kind = (opts.get('kind') or ['mdl'])[0]
    # the two games may keep the same thing under different file endings (bridge types: .lua and .bridge)
    old_kind = (opts.get('old-kind') or [kind])[0]
    new_kind = (opts.get('new-kind') or [kind])[0]
    old_keys, old_files, old_values, n_old, bad_old = census(opts['old'], old_kind)
    new_keys, new_files, new_values, n_new, bad_new = census(opts['new'], new_kind)
    scripts = words_of(opts.get('new-scripts', []))
    exe = words_of(opts.get('new-exe', []))
    converter = words_of(opts.get('converter', []))
    lines = ['# Key census: .%s files' % kind, '',
             'Old files read: %d (%d could not be read as a plain table). New files read: %d (%d not).' % (n_old, bad_old, n_new, bad_new),
             'Distinct key paths: %d in the old files, %d in the new.' % (len(old_keys), len(new_keys)), '']
    classes = collections.defaultdict(list)
    for path in sorted(old_keys):
        last = re.split(r'[.\[\]]+', path.strip('.'))
        last = [p for p in last if p][-1] if any(last) else path
        if path in new_keys:
            where = 'same'
        elif last in scripts:
            where = 'script'
        elif last in exe:
            where = 'exe'
        elif last in converter:
            where = 'converter'
        else:
            where = 'NOWHERE'
        classes[where].append((old_files[path], path))
    for where in ('NOWHERE', 'converter', 'script', 'exe', 'same'):
        items = sorted(classes[where], reverse=True)
        lines.append('## %s (%d paths)' % (where, len(items)))
        lines.append('')
        for count, path in items[:400 if where == 'NOWHERE' else 150]:
            lines.append('- `%s` - %d files' % (path.lstrip('.'), count))
        if len(items) > (400 if where == 'NOWHERE' else 150):
            lines.append('- ... and %d more' % (len(items) - (400 if where == 'NOWHERE' else 150)))
        lines.append('')
    gone_values = sorted(((n, v) for v, n in old_values.items() if v not in new_values and v.split(' = ')[1] not in exe and v.split(' = ')[1] not in scripts), reverse=True)
    lines.append('## Values (words in capitals) the old files use that the newer game does not know (%d)' % len(gone_values))
    lines.append('')
    for n, v in gone_values[:200]:
        lines.append('- `%s` - %d files' % (v.lstrip('.'), n))
    text = '\n'.join(lines) + '\n'
    out = (opts.get('out') or [None])[0]
    if out:
        open(out, 'w', encoding='utf-8', newline='\n').write(text)
        print('\n'.join(lines[:6]))
        print({k: len(v) for k, v in classes.items()}, 'values gone:', len(gone_values))
    else:
        sys.stdout.write(text)


if __name__ == '__main__':
    main()
