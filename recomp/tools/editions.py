"""Address layouts verified against specific, player-supplied executables."""
import hashlib
import json
from pathlib import Path

GOG_23 = 'c17e1cc9e01b5d2439a92e06b905040379ad4bb8618b822582c46f5fa29db4e2'
BROKEN_WORLD_23 = '5e82a52aac1bc23bd174bf837a7181af7a7d84dcc76aae7c27ab4bb08df37ba7'
FNV_GOG = '89e7020487e80f20ddc92ea641c4433b2c6839a82f45a076e414d167d11dd0fe'
PROFILES = {
    'fnv': dict(name='Fallout: New Vegas GOG 1.4.0.525', sha256=FNV_GOG, hooks=(), overrides=()),
    'gog': dict(name='GOG 2.3', sha256=GOG_23, hooks=(0x544df0, 0x544ee5, 0x90a076),
                overrides=(0x67aeb6, 0x7663b0)),
    'broken-world': dict(name='Broken World 2.30.0.4277', sha256=BROKEN_WORLD_23,
                        hooks=(0x553450, 0x553545, 0x921f86), overrides=(0x68e24c,)),
}


def digest(path):
    with Path(path).open('rb') as f:
        return hashlib.file_digest(f, 'sha256').hexdigest()


def identify(path, prepared=False):
    path = Path(path)
    sha = digest(path)
    for key, profile in PROFILES.items():
        if sha == profile['sha256']:
            return key
    if prepared:
        manifest = path.with_suffix('.native.json')
        if manifest.is_file():
            record = json.loads(manifest.read_text())
            if (record.get('edition') == 'broken-world' and
                    record.get('source_sha256') == BROKEN_WORLD_23 and
                    record.get('sha256') == sha and record.get('format') == 1):
                return 'broken-world'
    raise ValueError(f'Unsupported executable layout: SHA-256 {sha}')
