#!/usr/bin/env python3
"""Render a reviewable cask; never publish or fetch an artifact."""
import argparse
import re
from pathlib import Path
from urllib.parse import urlparse

p = argparse.ArgumentParser()
p.add_argument('--version', required=True)
p.add_argument('--sha256', required=True)
p.add_argument('--url', required=True)
p.add_argument('--homepage', required=True)
p.add_argument('--output', type=Path, required=True)
a = p.parse_args()
if not re.fullmatch(r'\d+\.\d+\.\d+(?:[-.][A-Za-z0-9]+)*', a.version):
    p.error('Use an explicit release version')
if not re.fullmatch(r'[a-fA-F0-9]{64}', a.sha256):
    p.error('Use the verified SHA-256 of the released artifact')
for value in (a.url, a.homepage):
    parsed = urlparse(value)
    if parsed.scheme != 'https' or not parsed.netloc or any(c in value for c in ['"', '\\', '\n', '#{']):
        p.error('Use a literal HTTPS URL')
if a.output.exists():
    p.error('Output exists; choose a fresh draft path')
text = f'''cask "longhaul" do
  version "{a.version}"
  sha256 "{a.sha256.lower()}"

  url "{a.url}"
  name "Longhaul"
  desc "Keep supported jobs awake and retain recovery checkpoints"
  homepage "{a.homepage}"

  depends_on arch: :arm64
  depends_on macos: ">= :tahoe"

  app "Longhaul.app"

  uninstall quit: "space.exlumina.longhaul",
            launchctl: "space.exlumina.longhaul.companion"
end
'''
a.output.parent.mkdir(parents=True, exist_ok=True)
a.output.write_text(text)
print(f'Draft cask written to {a.output}. Artifact/install verification remains required.')
