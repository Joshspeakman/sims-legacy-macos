#!/usr/bin/env python3
"""sims_art.py <art folder>

The launch window's art (install.sh), written to the data folder's art/ and a copy in the app (never to this project),
from Steam's store page for The Sims Legacy Collection (app 3314060):
  logo.png      the game's logo, with transparency
  backdrop.jpg  the store page's background (a dark blue house plan): the window's background
  shot.jpg      the library banner (Sims in front of coloured panels): the right of the window's banner
Each one that can't be downloaded is left out; without the logo the window writes the title. Standard library only.
"""
import os, sys, urllib.request

CDN = 'https://cdn.cloudflare.steamstatic.com/steam/apps/3314060/'
ART = (('logo.png', 'logo.png', b'\x89PNG'), ('backdrop.jpg', 'page_bg_generated_v6b.jpg', b'\xff\xd8\xff'),
       ('shot.jpg', 'library_hero.jpg', b'\xff\xd8\xff'))

def download(url, path, magic, least=8000):
    try:
        with urllib.request.urlopen(url, timeout=20) as r: data = r.read()
    except Exception:
        return False
    if not data.startswith(magic) or len(data) < least: return False
    with open(path + '.part', 'wb') as f: f.write(data)
    os.replace(path + '.part', path); return True

def main():
    out = sys.argv[1]; os.makedirs(out, exist_ok=True); got = []
    for name, remote, magic in ART:
        if download(CDN + remote, os.path.join(out, name), magic): got.append(name)
    print('art: %s' % (', '.join(got) if got else 'none (no connection?): the launch window writes the title'))

if __name__ == '__main__':
    main()
