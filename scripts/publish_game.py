#!/usr/bin/env python3
"""Validate and publish an iOS 17 IPA with external resources."""
import hashlib, json, os, plistlib, re, sys, zipfile, struct
from pathlib import Path
from verify_memory_signature import inspect_signature, require_memory_signature

def publish(staged, output, romfs, aoc, game, build, package):
    root = Path(__file__).resolve().parents[1]
    staged, output, romfs = map(Path, (staged, output, romfs))
    output = output.resolve()
    output.parent.mkdir(parents=True, exist_ok=True)
    if output.exists() or output.with_suffix('.json').exists():
        raise FileExistsError(f"Output already exists: {output}")

    with zipfile.ZipFile(staged) as z:
        if z.testzip():
            raise ValueError('IPA CRC failure')
        info = plistlib.loads(z.read('Payload/DmIOS.app/Info.plist'))
        if info['MinimumOSVersion'] != '17.0' or str(info['CFBundleVersion']) != build:
            raise ValueError(f"Wrong OS target ({info['MinimumOSVersion']}) or build ({info['CFBundleVersion']})")
        if any('/romfs/' in n or '/aoc/' in n for n in z.namelist()):
            raise ValueError('Game resources must stay external')
        binary = z.read('Payload/DmIOS.app/' + info['CFBundleExecutable'])
        signature = inspect_signature(binary)
        if os.environ.get('NX_TROLLSTORE') == '1':
            signature = require_memory_signature(binary)
            if info.get('NXSigningMode') != 'trollstore-adhoc-memory':
                raise ValueError('Missing TrollStore signing mode metadata')
            if 'Payload/DmIOS.app/_CodeSignature/CodeResources' not in z.namelist():
                raise ValueError('Missing signed resource seal')
        warmup = z.read('Payload/DmIOS.app/dm/pso_manifest.tsv')
        warmup_report = {
            'rows': sum(bool(x) and not x.startswith(b'#') for x in warmup.splitlines()),
            'sha256': hashlib.sha256(warmup).hexdigest()
        }
        overlay_descriptor = None
        if os.environ.get('NX_A16_PACK'):
            overlay_descriptor = json.loads(z.read('Payload/DmIOS.app/dm/a16_texture_pack.json'))
            manifest = (Path(os.environ['NX_A16_PACK']) / 'pack.json').read_bytes()
            if hashlib.sha256(manifest).hexdigest() != overlay_descriptor['manifest_sha256']:
                raise ValueError('Bundled overlay descriptor does not match external pack')
        if struct.unpack_from('<I', binary)[0] != 0xfeedfacf:
            raise ValueError('Expected thin arm64 Mach-O')
        offset = 32
        versions = []
        for _ in range(struct.unpack_from('<I', binary, 16)[0]):
            cmd, size = struct.unpack_from('<II', binary, offset)
            if cmd == 0x32:
                versions.append(struct.unpack_from('<III', binary, offset + 8))
            offset += size
        if not any(platform == 2 and minimum == 0x110000 for platform, minimum, sdk in versions):
            raise ValueError('Executable does not target iOS17')
        for selector in [b'newMTL4CommandQueue', b'newResidencySet', b'beginCommandBufferWithAllocator', b'MTL4ArgumentTable']:
            if selector in binary:
                raise ValueError('Metal4/new residency dependency in binary')
        if not any(n.endswith('_b.metallib') for n in z.namelist()):
            raise ValueError('No actual game shaders')

    resources_dir = output.parent / 'resources' / game / package
    resources_dir.mkdir(parents=True, exist_ok=True)
    paths = {}
    for label, src in [('romfs', romfs), ('aoc', Path(aoc) if aoc else None)]:
        if src is None or not src.is_dir():
            continue
        dst = resources_dir / label
        if src.resolve() == dst.resolve():
            pass
        elif dst.exists():
            pass
        else:
            if src.is_symlink():
                raise ValueError('Unexpected resource symlink outside releases')
            try:
                os.rename(src, dst)
                src.symlink_to(dst, target_is_directory=True)
            except OSError:
                pass
        paths[label] = str(dst)

    report = {
        'ipa': str(output),
        'version': '1.0.0',
        'build': build,
        'game': game,
        'package': package,
        'minimum_os': '17.0',
        'sha256': hashlib.sha256(staged.read_bytes()).hexdigest(),
        'bytes': staged.stat().st_size,
        'resources': paths,
        'crc_pass': True,
        'mach_o_ios17': True,
        'metal4_dependencies': False,
        'device_installed': False,
        'device_gameplay_verified': False,
        'signature': signature,
        'pipeline_warmup': warmup_report
    }
    if overlay_descriptor:
        report['a16_overlay'] = {'path': os.environ['NX_A16_PACK'], 'descriptor': overlay_descriptor}

    # Write output IPA
    try:
        os.link(staged, output)
    except OSError:
        import shutil
        shutil.copy2(staged, output)

    with output.with_suffix('.json').open('w') as f:
        json.dump(report, f, indent=2)

    entitlements_src = root / 'dm/ios/Sources/DmIOS.entitlements'
    if entitlements_src.exists():
        entitlements = output.with_suffix('.entitlements.plist')
        entitlements.write_bytes(entitlements_src.read_bytes())

    print(json.dumps(report, indent=2))

if __name__ == '__main__':
    publish(*sys.argv[1:])
