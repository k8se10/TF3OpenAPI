"""Writes native/src/build_version.inc: the text the main menu shows under the API version.
A release (the commit is tagged, e.g. v0.1.0) says "release v0.1.0"; anything else says "commit <short hash>",
with a "+" when the working tree has changes that are not committed. Run by the project's pre-build step;
without git the file says "build unknown".
"""
import os
import subprocess

root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def git(*args):
    return subprocess.run(['git', '-C', root] + list(args), capture_output=True, text=True, check=True).stdout.strip()


try:
    try:
        text = 'release ' + git('describe', '--tags', '--exact-match', 'HEAD')
    except Exception:
        text = 'commit ' + git('rev-parse', '--short=7', 'HEAD')
    if git('status', '--porcelain', '--untracked-files=no'):
        text += '+'
except Exception:
    text = 'build unknown'
path = os.path.join(root, 'native', 'src', 'build_version.inc')
old = open(path).read() if os.path.isfile(path) else ''
new = '"' + text + '"\n'
if old != new:
    open(path, 'w', newline='\n').write(new)
print('build version:', text)
