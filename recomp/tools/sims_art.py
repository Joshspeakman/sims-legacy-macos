#!/usr/bin/env python3
"""sims_art.py <art folder> [<game folder>]

The launch window's art (install.sh), written to the data folder's art/ and a copy in the app (never to this project),
from Steam's store page for The Sims Legacy Collection (app 3314060):
  logo.png      the game's logo, with transparency
  backdrop.jpg  the store page's background (a dark blue house plan): the window's background
  shot.jpg      the library banner (Sims in front of coloured panels): the right of the window's banner
  portrait.jpg  the library capsule (600x900): the framed portrait
  slide-<n>.jpg the store page's screenshots: the backdrop's slides
With the game folder, from the player's own copy: setup.png, the game's loading screen (UIGraphics/Logos/setup.bmp,
converted with macOS's sips): a slide, and the backdrop offline.
Each one that can't be downloaded is left out; without the logo the window writes the title. Standard library only.
"""
import json, os, subprocess, sys, urllib.request

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
    if download(CDN.replace('cdn.cloudflare.steamstatic.com/steam', 'shared.akamai.steamstatic.com/store_item_assets/steam') + 'library_600x900_2x.jpg',
                os.path.join(out, 'portrait.jpg'), b'\xff\xd8\xff'): got.append('portrait.jpg')
    try:
        with urllib.request.urlopen('https://store.steampowered.com/api/appdetails?appids=3314060&filters=screenshots', timeout=20) as r:
            shots = [x['path_full'].split('?')[0] for x in json.load(r)['3314060']['data']['screenshots']]
    except Exception:
        shots = []
    for k, u in enumerate(shots[:6]):
        if download(u, os.path.join(out, 'slide-%d.jpg' % (k + 1)), b'\xff\xd8\xff'): got.append('slide-%d.jpg' % (k + 1))
    if len(sys.argv) > 2:
        bmp = os.path.join(sys.argv[2], 'UIGraphics', 'Logos', 'setup.bmp')
        if os.path.exists(bmp) and subprocess.run(['/usr/bin/sips', '-s', 'format', 'png', bmp, '--out', os.path.join(out, 'setup.png')], capture_output=True).returncode == 0:
            got.append('setup.png')
    print('art: %s' % (', '.join(got) if got else 'none (no connection?): the launch window writes the title'))

if __name__ == '__main__':
    main()
