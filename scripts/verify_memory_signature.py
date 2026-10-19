#!/usr/bin/env python3
"""Read actual Mach-O signature blobs; never treat a sidecar plist as proof."""
import json
import plistlib
import struct
import sys
from pathlib import Path

MEMORY_ENTITLEMENTS = {
    'com.apple.developer.kernel.extended-virtual-addressing': True,
    'com.apple.developer.kernel.increased-memory-limit': True,
}

def inspect_signature(binary):
    if struct.unpack_from('<I', binary)[0] != 0xfeedfacf:
        raise ValueError('Expected thin arm64 Mach-O')
    at = 32
    signatures = []
    for _ in range(struct.unpack_from('<I', binary, 16)[0]):
        cmd, size = struct.unpack_from('<II', binary, at)
        if size < 8 or at + size > len(binary):
            raise ValueError('Invalid Mach-O command')
        if cmd == 0x1d:
            signatures.append(struct.unpack_from('<II', binary, at + 8))
        at += size
    if not signatures:
        return {'signed': False, 'entitlements': {}, 'der_entitlements': False}
    if len(signatures) != 1:
        raise ValueError('Ambiguous code signature')
    offset, length = signatures[0]
    blob = binary[offset:offset + length]
    if len(blob) != length or length < 12:
        raise ValueError('Truncated signature')
    magic, total, count = struct.unpack_from('>III', blob)
    if magic != 0xfade0cc0 or total > length or 12 + count * 8 > total:
        raise ValueError('Invalid signature superblob')
    slots = {}
    for i in range(count):
        slot, start = struct.unpack_from('>II', blob, 12 + i * 8)
        if start + 8 > total or slot in slots:
            raise ValueError('Invalid signature slot')
        kind, size = struct.unpack_from('>II', blob, start)
        if size < 8 or start + size > total:
            raise ValueError('Invalid slot range')
        slots[slot] = (kind, blob[start:start + size])
    entitlements = {}
    if 5 in slots and slots[5][0] == 0xfade7171:
        entitlements = plistlib.loads(slots[5][1][8:])
    return {
        'signed': 0 in slots,
        'ad_hoc': 0 in slots and len(slots[0][1]) > 8 and slots[0][1][8:16] == bytes(8),
        'entitlements': entitlements,
        'der_entitlements': 7 in slots and slots[7][0] == 0xfade7172
    }

def require_memory_signature(binary):
    report = inspect_signature(binary)
    if not report['signed'] or not report['ad_hoc']:
        raise ValueError('Missing ad-hoc signature')
    if not report['der_entitlements']:
        raise ValueError('Missing DER entitlements')
    for key, value in MEMORY_ENTITLEMENTS.items():
        if report['entitlements'].get(key) != value:
            raise ValueError(f'Missing entitlement: {key}')
    return report

if __name__ == '__main__':
    print(json.dumps(require_memory_signature(Path(sys.argv[1]).read_bytes()), indent=2))
