#!/usr/bin/env python3
"""sims_smoke.py <app binary> <unwrapped Sims.exe> <game folder> [--data DIR] [--frames N] [--seconds S]

A first check of a build (Linux SimsLinux or macOS SimsNative): runs the game in test mode with a fresh data folder
(first run: the template neighbourhood is copied), takes a screenshot of a presented frame and checks that it is the
neighbourhood screen: the navy frame around a picture with many colours (grass, roads, houses). Exit status 0 = pass.
"""
import argparse, os, shutil, struct, subprocess, sys, tempfile, zlib

def png_rgb(path):
    d = open(path, 'rb').read(); i = 8; w = h = 0; idat = b''
    while i < len(d):
        n = struct.unpack('>I', d[i:i + 4])[0]; t = d[i + 4:i + 8]
        if t == b'IHDR': w, h = struct.unpack('>II', d[i + 8:i + 16])
        if t == b'IDAT': idat += d[i + 8:i + 8 + n]
        i += 12 + n
    raw = zlib.decompress(idat); rows = []
    for y in range(h):
        r = raw[y * (3 * w + 1):(y + 1) * (3 * w + 1)]
        assert r[0] == 0, 'filtered PNG rows are not expected (written by vulkan.c)'
        rows.append(r[1:])
    return w, h, rows

def main():
    ap = argparse.ArgumentParser(); ap.add_argument('app'); ap.add_argument('exe'); ap.add_argument('game')
    ap.add_argument('--data'); ap.add_argument('--frames', type=int, default=1500); ap.add_argument('--seconds', type=int, default=90)
    a = ap.parse_args()
    data = a.data or tempfile.mkdtemp(prefix='sims-smoke-')
    shots = tempfile.mkdtemp(prefix='sims-shot-'); prefix = os.path.join(shots, 'f')
    env = dict(os.environ, DS_TEST='1', W32_AUDIO_MUTE='1', W32_VK_SHOT=prefix, W32_VK_SHOT_AT=str(a.frames), DS_EXIT_AFTER=str(a.seconds))
    log = os.path.join(data, 'smoke.log'); os.makedirs(data, exist_ok=True)
    try:
        with open(log, 'w') as lf:
            subprocess.run([a.app, '--exe', a.exe, '--game', a.game, '--data', data], env=env, stdout=lf, stderr=subprocess.STDOUT,
                           stdin=subprocess.DEVNULL, timeout=a.seconds + 30)
    except subprocess.TimeoutExpired:
        pass
    text = open(log, errors='replace').read()
    for bad in ('fault:', 'unimplemented import', 'unhandled'):
        if bad in text: print('FAIL: the game stopped:', [l for l in text.splitlines() if bad in l][:3]); return 1
    shot = prefix + '%d.png' % a.frames
    if not os.path.exists(shot):
        print('FAIL: no frame %d was presented (see %s)' % (a.frames, log)); print('\n'.join(text.splitlines()[-15:])); return 1
    w, h, rows = png_rgb(shot)
    corner = rows[h // 20][3 * (w // 40):3 * (w // 40) + 3]             # the frame around the neighbourhood: navy
    navy = corner[2] > 60 and corner[0] < 40 and corner[1] < 40
    mid = set()
    for y in range(h // 4, 3 * h // 4, 7):
        r = rows[y]
        for x in range(w // 4, 3 * w // 4, 7): mid.add(bytes(r[3 * x:3 * x + 3]))
    print('frame %d: %dx%d, corner %s, %d colours in the middle' % (a.frames, w, h, tuple(corner), len(mid)))
    if not navy or len(mid) < 500:
        print('FAIL: not the neighbourhood screen (%s)' % shot); return 1
    print('PASS (%s)' % shot)
    if not a.data: shutil.rmtree(data, ignore_errors=True)
    return 0

if __name__ == '__main__': sys.exit(main())
