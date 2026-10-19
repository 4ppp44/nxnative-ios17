#!/usr/bin/env python3
"""Independently compare changed archives and protect every unconverted texture."""
from pathlib import Path
import argparse, hashlib,json,struct
import zstandard
from texture_survey import bntx_textures,sarc_members

def verify(pack,original):
    m=json.loads((pack/'pack.json').read_text());stats={'files':0,'converted_instances':0,'unchanged_instances_in_overlay_files':0,'subresources':0}
    def compare(old,new):
        if old[:4]==b'\x28\xb5\x2f\xfd':
            assert new[:4]==old[:4];return compare(zstandard.decompress(old),zstandard.decompress(new))
        assert len(old)==len(new),'Uncompressed container size changed'
        if old[:4]==b'SARC':
            a=list(sarc_members(old));b=list(sarc_members(new));assert [n for n,x in a]==[n for n,x in b]
            e='<' if old[6:8]==b'\xff\xfe' else '>';header=struct.unpack_from(e+'H',old,4)[0]
            begin=struct.unpack_from(e+'I',old,12)[0];fat=struct.unpack_from(e+'H',old,header+4)[0];expected=bytearray(old)
            for i,((name,x),(name2,y)) in enumerate(zip(a,b)):
                compare(x,y);assert len(x)==len(y)
                lo=struct.unpack_from(e+'I',old,header+fat+i*16+8)[0];expected[begin+lo:begin+lo+len(x)]=y
            assert bytes(expected)==new,'Archive metadata outside members changed';return
        a=list(bntx_textures(old));b=list(bntx_textures(new));assert len(a)==len(b)
        expected=bytearray(old)
        for x,y in zip(a,b):
            for k in ['bntx_base','brti_offset','width','height','depth','layers','mips','image_bytes','alignment','channels','tile_mode','block_height_log2','mip_offsets','data_offset']:
                assert x[k]==y[k],k
            if x['format']==y['format']:
                assert x['sha256']==y['sha256'],'Unselected texture changed';stats['unchanged_instances_in_overlay_files']+=1
            else:
                assert x['format'] in [0x1e01,0x2001,0x2006]
                assert y['format']==(0x2d06 if x['format']==0x2006 else 0x2d01)
                stats['converted_instances']+=1;stats['subresources']+=x['mips']*x['layers']
                at=x['bntx_base']+x['data_offset'];n=x['image_bytes'];expected[at:at+n]=new[at:at+n]
                at=x['bntx_base']+x['brti_offset']+0x1c;expected[at:at+4]=new[at:at+4]
        assert bytes(expected)==new,'Bytes outside selected image payloads and format fields changed'
    for f in m['files']:
        a=(original/f['path']).read_bytes();b=(pack/f['path']).read_bytes()
        assert hashlib.sha256(a).hexdigest()==f['source_sha256'];assert hashlib.sha256(b).hexdigest()==f['sha256']
        compare(a,b);stats['files']+=1
    assert stats['converted_instances']==m['converted_texture_instances']
    return dict(stats,all_unconverted_textures_preserved=True,uncompressed_sizes_and_offsets_preserved=True,source_hashes_unchanged=True,scope='Container/content and CPU transcode validation; no device gameplay or performance proof')

if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('pack',type=Path);p.add_argument('original',type=Path);p.add_argument('report',type=Path);a=p.parse_args()
    result=verify(a.pack,a.original);a.report.write_text(json.dumps(result,indent=2)+'\n');print(json.dumps(result,indent=2))
