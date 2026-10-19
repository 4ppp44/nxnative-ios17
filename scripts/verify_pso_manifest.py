#!/usr/bin/env python3
"""Validate a private device warmup manifest against the selected shader chain."""
from pathlib import Path
import hashlib, json, re, sys, collections

def verify(manifest, libraries):
    rows = [x for x in Path(manifest).read_text().splitlines() if x and not x.startswith('#')]
    counts = collections.Counter()
    sizes = set()
    keys = set()
    for line in rows:
        c = line.split('\t')
        counts[c[0]] += 1
        if c[0] == 'S':
            if len(c) != 3 or c[2] not in ('0', '1', '2', '3', '4', '5'):
                raise ValueError('Invalid shader stage')
            names = [c[1]]
        elif c[0] == 'C':
            if len(c) != 2:
                raise ValueError('Invalid compute entry')
            names = [c[1]]
        elif c[0] == 'R':
            if len(c) != 2 or not re.fullmatch('[0-9a-f]+', c[1]):
                raise ValueError('Invalid render key')
            raw = bytes.fromhex(c[1])
            sizes.add(len(raw))
            if len(raw) < 96:
                raise ValueError('Truncated saved pipeline key')
            names = [raw[:24].split(b'\0')[0].decode(), raw[24:48].split(b'\0')[0].decode()]
            if raw[48] > 5 or raw[49] > 5 or raw[50] > 1 or raw[51] > 1:
                raise ValueError('Unsupported saved shader state')
            # pso_skey's three runtime object pointers are zeroed before saving.
            if raw[88:104] != bytes(16):
                raise ValueError('Serialized runtime pointers in pipeline key')
        else:
            raise ValueError('Unknown warmup row')
        for key in names:
            if not key:
                continue
            if not re.fullmatch('[0-9a-f]{16}_b(?:_[A-Za-z0-9_]+)?', key):
                raise ValueError('Unsafe shader key: ' + key)
            if not (Path(libraries) / (key + '.metallib')).is_file():
                raise ValueError('Manifest shader absent from selected chain: ' + key)
            keys.add(key)
    if len(sizes) > 1:
        raise ValueError('Mixed pipeline serialization layouts')
    return {
        'rows': len(rows),
        'unique_rows': len(set(rows)),
        'kinds': dict(counts),
        'shader_keys_checked': len(keys),
        'saved_pipeline_bytes': list(sizes),
        'sha256': hashlib.sha256(Path(manifest).read_bytes()).hexdigest(),
        'scope': 'Structural and chain-resource check; not a GPU pipeline replay'
    }

if __name__ == '__main__':
    print(json.dumps(verify(*sys.argv[1:]), indent=2))
