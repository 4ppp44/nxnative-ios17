#!/usr/bin/env python3
"""Validate an immutable external texture overlay and write its bundle descriptor."""
import hashlib, json, sys
from pathlib import Path, PurePosixPath

def verify(pack, romfs, descriptor):
    pack, romfs, descriptor = map(Path, (pack, romfs, descriptor))
    raw = (pack / 'pack.json').read_bytes()
    m = json.loads(raw)
    if m.get('schema') != 1 or m.get('game') != '010015100B514000' or m.get('package') != 'v327680' or m.get('test_only_partial'):
        raise ValueError('Wrong or partial texture pack')
    if not m['files'] or m['converted_texture_instances'] <= 0:
        raise ValueError('Empty texture pack')
    seen = set()
    for f in m['files']:
        p = PurePosixPath(f['path'])
        if p.is_absolute() or '..' in p.parts or f['path'] in seen:
            raise ValueError('Unsafe/duplicate overlay path')
        seen.add(f['path'])
        for root, size_key, hash_key in [(pack, 'bytes', 'sha256'), (romfs, 'source_bytes', 'source_sha256')]:
            data = (root / f['path']).read_bytes()
            if len(data) != f[size_key] or hashlib.sha256(data).hexdigest() != f[hash_key]:
                raise ValueError('Texture/source digest mismatch')
    d = {
        'schema': 1,
        'game': m['game'],
        'package': m['package'],
        'manifest_sha256': hashlib.sha256(raw).hexdigest(),
        'files': len(seen),
        'texture_instances': m['converted_texture_instances'],
        'policy': m['policy']
    }
    descriptor.parent.mkdir(parents=True, exist_ok=True)
    descriptor.write_text(json.dumps(d, indent=2) + '\n')
    return d

if __name__ == '__main__':
    print(json.dumps(verify(*sys.argv[1:]), indent=2))
