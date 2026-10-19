#!/usr/bin/env python3
"""Verify retained iOS libraries against a hash-pinned, published IPA.

This packaging-only path does not invent deleted translation-build results.
Source chain checks remain in build_ipa.sh; every actual library/reflection file
must also match the prior release and still declare an iOS 17 AIR target.
"""
import hashlib
import json
import re
import sys
import zipfile
from pathlib import Path


def verify(ios, chain, game, reference, output):
    root = Path(__file__).resolve().parents[3]
    directory = Path(ios) / ('b-' + chain)
    reference = Path(reference)
    metadata = json.loads(reference.with_suffix('.json').read_text())
    assert metadata['game'] == game and metadata['minimum_os'] == '17.0'
    assert metadata['crc_pass'] and metadata['mach_o_ios17'] and not metadata['metal4_dependencies']
    sha = hashlib.sha256()
    with reference.open('rb') as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b''):
            sha.update(block)
    assert sha.hexdigest() == metadata['sha256'], 'Reference IPA hash mismatch'
    expected = set()
    for line in (root / 'dm/games' / game / 'shader_map.tsv').read_text().splitlines():
        if line and not line.startswith(('#', 'package\t')):
            expected.add(line.split('\t')[3])
    actual = {p.name for p in directory.iterdir() if p.suffix in ('.json', '.metallib')}
    present = {name[:-len('_b.metallib')] for name in actual if name.endswith('_b.metallib')}
    assert expected <= present, 'Missing mapped shader libraries'
    prefix = f'Payload/DmIOS.app/msl/b-{chain}/'
    aggregate = hashlib.sha256()
    with zipfile.ZipFile(reference) as package:
        retained = {name[len(prefix):] for name in package.namelist()
                    if name.startswith(prefix) and name.endswith(('.json', '.metallib'))}
        assert actual == retained, 'Retained/reference shader sets differ'
        for name in sorted(actual):
            content = (directory / name).read_bytes()
            assert content == package.read(prefix + name), f'Retained shader differs: {name}'
            aggregate.update(name.encode() + b'\0' + hashlib.sha256(content).digest())
            if name.endswith('.json'):
                info = json.loads(content)
                assert info.get('chain') == chain and '-mios-version-min=17.0' in info.get('chain_metal', ''), name
            else:
                targets = re.findall(rb'air64[^\x00\s-]*-apple-ios([0-9.]+)', content)
                assert targets and all(t == b'17.0.0' for t in targets), name
    report = dict(game=game, chain=chain, verification_mode='retained-published-ipa-byte-comparison',
                  reference_ipa=reference.name, reference_sha256=sha.hexdigest(),
                  expected_shaders=len(expected), ios_main_libraries=len(present),
                  ios_all_libraries=sum(n.endswith('.metallib') for n in actual),
                  reflection_files=sum(n.endswith('.json') for n in actual),
                  aggregate_sha256=aggregate.hexdigest(), air_minimum_os_targets=['17.0.0'],
                  original_translation_cache_present=False, device_runtime_verified=False)
    Path(output).write_text(json.dumps(report, indent=2))
    print(json.dumps(report))


if __name__ == '__main__':
    verify(*sys.argv[1:])
