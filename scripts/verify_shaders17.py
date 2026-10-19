#!/usr/bin/env python3
"""Reject partial shader builds and pre-iOS17-port cache metadata."""
import json, sys, re
from pathlib import Path

def verify(ios, chain, game):
    root = Path(__file__).resolve().parents[1]
    ios = Path(ios) / ('b-' + chain)
    mac = ios.parent.parent / 'cache' / ('b-' + chain)
    results = json.loads((mac / '_b_build.json').read_text())
    failed = [r for r in results if r['st'] != 'ok']
    if failed:
        raise ValueError(f'{len(failed)} shader translation/compilation failures: {failed[:3]}')
    expected = set()
    shader_map = root / 'dm/games' / game / 'shader_map.tsv'
    for line in shader_map.read_text().splitlines():
        if line.startswith('#') or line.startswith('package\t') or not line:
            continue
        expected.add(line.split('\t')[3])
    present = {p.name[:-len('_b.metallib')] for p in ios.glob('*_b.metallib')}
    if expected - present:
        raise ValueError(f'{len(expected - present)} missing iOS shader libraries')
    metas = list(ios.glob('*.json'))
    for path in metas:
        m = json.loads(path.read_text())
        if m.get('chain') != chain or '-mios-version-min=17.0' not in m.get('chain_metal', ''):
            raise ValueError(f'Wrong shader chain/OS target: {path.name}')
    libraries = list(ios.glob('*.metallib'))
    targets = set()
    for path in libraries:
        found = re.findall(rb'air64[^\x00\s-]*-apple-ios([0-9.]+)', path.read_bytes())
        if not found or any(version != b'17.0.0' for version in found):
            raise ValueError(f'Unexpected compiled AIR target: {path.name}: {found}')
        targets.update(v.decode() for v in found)
    report = {
        'air_minimum_os_targets': sorted(targets),
        'game': game,
        'chain': chain,
        'expected_shaders': len(expected),
        'ios_main_libraries': len(present),
        'ios_all_libraries': len(list(ios.glob('*.metallib'))),
        'reflection_files': len(metas),
        'build_failures': len(failed),
        'minimum_os': '17.0',
        'device_runtime_verified': False
    }
    report_dir = root / 'artifacts/ios17-feasibility' if (root / 'artifacts').exists() else root / 'build'
    report_dir.mkdir(parents=True, exist_ok=True)
    (report_dir / f'shaders-{game}.json').write_text(json.dumps(report, indent=2))
    print(json.dumps(report))
    return report

if __name__ == '__main__':
    verify(*sys.argv[1:])
