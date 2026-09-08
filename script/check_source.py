#!/usr/bin/env python3
"""Lightweight local package checks; not a release acceptance certificate."""
from pathlib import Path
import ast
import json
import plistlib
import re

root = Path(__file__).resolve().parent.parent
for name in ['README.md', 'SETUP-PROMPT.md', 'PRIVACY.md', 'SECURITY.md', 'LICENSE', 'LICENSE-STATUS.md', 'docs/STATUS.md']:
    assert (root / name).is_file(), name
for folder in ['script', 'integrations']:
    for path in (root / folder).rglob('*.py'):
        ast.parse(path.read_text(), filename=str(path))
for path in (root / 'Resources').glob('*.plist'):
    plistlib.loads(path.read_bytes())
paths = [p for p in root.iterdir() if p.is_file()]
for folder in ['App', 'Sources', 'Tests', 'Resources', 'integrations', 'script', 'docs', '.codex', '.github', 'Longhaul.xcodeproj']:
    paths.extend((root / folder).rglob('*'))
for path in paths:
    if not path.is_file() or path.suffix in {'.icns', '.png', '.pyc'}: continue
    if 'xcuserdata' in path.parts or '__pycache__' in path.parts: continue
    text = path.read_text(errors='replace')
    assert not re.search(r'/Users/[A-Za-z0-9_.-]+/', text), f'Personal path: {path}'
    assert ('BEGIN ' + 'PRIVATE KEY') not in text, f'Private key marker: {path}'
    assert not re.search(r'gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{40,}', text), f'Credential pattern: {path}'
print('Source presence, Python syntax, plist and basic privacy checks passed.')
