#!/usr/bin/env python3
"""Read-only BNTX inventory, including embedded BFRES and nested SARC/Zstandard.

Only metadata is written. Original game archives are never modified or expanded
onto disk. The private inventory belongs under work/, outside source control.
Field layout references: BNTX-Injector structs.py and 3DSkit doc/BNTX.md.
"""
from pathlib import Path
import argparse, collections, hashlib, json, struct
import zstandard

NAMES = {0x1a:'BC1',0x1b:'BC2',0x1c:'BC3',0x1d:'BC4',0x1e:'BC5',0x1f:'BC6H',0x20:'BC7',
         0x0b:'RGBA8',0x0c:'BGRA8',0x02:'R8',0x09:'RG8'}
ASTC = [(4,4),(5,4),(5,5),(6,5),(6,6),(8,5),(8,6),(8,8),(10,5),(10,6),(10,8),(10,10),(12,10),(12,12)]

def format_name(fmt):
    hi, lo = fmt >> 8, fmt & 255
    name = ('ASTC%dx%d' % ASTC[hi-0x2d]) if 0x2d<=hi<0x2d+len(ASTC) else NAMES.get(hi, 'fmt_%02x'%hi)
    return name + ('_sRGB' if lo==6 else '_SNORM' if lo==2 else '_HDR' if lo in (5,10) and hi==0x1f else '_linear')

def bntx_textures(data):
    start = 0
    while True:
        base = data.find(b'BNTX\0\0\0\0', start)
        if base<0:return
        start=base+8
        if base+0x50>len(data) or data[base+12:base+14]!=b'\xff\xfe':continue
        size=struct.unpack_from('<I',data,base+28)[0]
        if size<0x50 or base+size>len(data):continue
        count=struct.unpack_from('<I',data,base+36)[0]
        ptr=struct.unpack_from('<Q',data,base+40)[0]
        if count>65536 or ptr+count*8>size:continue
        for idx in range(count):
            at=struct.unpack_from('<Q',data,base+ptr+idx*8)[0]
            if at+0x78>size or data[base+at:base+at+4]!=b'BRTI':raise ValueError('Invalid BRTI pointer')
            q=base+at;fmt=struct.unpack_from('<I',data,q+0x1c)[0]
            w,h,d,layers=struct.unpack_from('<4I',data,q+0x24)
            mips=struct.unpack_from('<H',data,q+0x16)[0]
            image_size,alignment,channels=struct.unpack_from('<3I',data,q+0x50)
            mip_ptr=struct.unpack_from('<Q',data,q+0x70)[0]
            if not (0<w<=16384 and 0<h<=16384 and 0<d<=2048 and 0<layers<=2048 and 0<mips<=16):raise ValueError('Invalid BRTI dimensions')
            if mip_ptr+mips*8>size:raise ValueError('Invalid mip table')
            offsets=list(struct.unpack_from('<'+'Q'*mips,data,base+mip_ptr))
            if offsets[0]+image_size>size or any(x<offsets[0] or x>=offsets[0]+image_size for x in offsets):raise ValueError('Invalid image bounds')
            raw=data[base+offsets[0]:base+offsets[0]+image_size]
            yield {'bntx_base':base,'brti_offset':at,'format':fmt,'format_name':format_name(fmt),'width':w,'height':h,'depth':d,'layers':layers,'mips':mips,'image_bytes':image_size,'alignment':alignment,'channels':channels,'tile_mode':struct.unpack_from('<H',data,q+0x12)[0],'block_height_log2':struct.unpack_from('<I',data,q+0x34)[0]&7,'mip_offsets':[x-offsets[0] for x in offsets],'data_offset':offsets[0],'sha256':hashlib.sha256(raw).hexdigest()}

def sarc_members(data):
    if len(data)<32 or data[:4]!=b'SARC':return
    endian='<' if data[6:8]==b'\xff\xfe' else '>'
    header=struct.unpack_from(endian+'H',data,4)[0]
    size,begin=struct.unpack_from(endian+'II',data,8)
    if size>len(data) or data[header:header+4]!=b'SFAT':raise ValueError('Invalid SARC')
    fat_size,count=struct.unpack_from(endian+'HH',data,header+4)
    nodes=header+fat_size;names=nodes+count*16
    if data[names:names+4]!=b'SFNT':raise ValueError('Invalid SFNT')
    names+=struct.unpack_from(endian+'H',data,names+4)[0]
    for i in range(count):
        _,attr,lo,hi=struct.unpack_from(endian+'IIII',data,nodes+i*16)
        if hi<lo or begin+hi>size:raise ValueError('Invalid SARC entry')
        at=names+(attr&0xffffff)*4
        name=data[at:data.find(b'\0',at)].decode('utf-8','replace') if attr>>24 else str(i)
        yield name,data[begin+lo:begin+hi]

def scan_blob(data, path, errors, depth=0):
    if depth>12:raise ValueError('Nested archive limit')
    if data[:4]==b'\x28\xb5\x2f\xfd':
        try:data=zstandard.ZstdDecompressor().decompress(data,max_output_size=512<<20)
        except zstandard.ZstdError as exc:
            errors.append({'path':path,'error':str(exc)});return
    if data[:4]==b'SARC':
        for name,payload in sarc_members(data):yield from scan_blob(payload,path+'!'+name,errors,depth+1)
    else:
        for row in bntx_textures(data):yield dict(path=path,**row)

def survey(root, output):
    rows=[];errors=[];files=0
    for p in sorted(root.rglob('*')):
        if p.is_file() and p.suffix in ('.zs','.bntx','.bfres','.sarc','.pack','.blarc'):
            files+=1
            try:rows.extend(scan_blob(p.read_bytes(),str(p.relative_to(root)),errors))
            except (ValueError,struct.error) as exc:errors.append({'path':str(p.relative_to(root)),'error':str(exc)})
            if files%500==0:print('SURVEY',files,'files',len(rows),'textures',len(errors),'errors',flush=True)
    unique={}
    for x in rows:unique.setdefault((x['format'],x['width'],x['height'],x['depth'],x['layers'],x['mips'],x['sha256']),x)
    def aggregate(items):
        stats={}
        for x in items:
            v=stats.setdefault(x['format_name'],{'textures':0,'stored_bytes':0})
            v['textures']+=1;v['stored_bytes']+=x['image_bytes']
        return stats
    result={'source_root':str(root),'files_scanned':files,'instances':len(rows),'unique_textures':len(unique),'formats_instances':aggregate(rows),'formats_unique':aggregate(unique.values()),'errors':errors,'rows':rows}
    output.parent.mkdir(parents=True,exist_ok=True);output.write_text(json.dumps(result,indent=2)+'\n')
    print(json.dumps({k:v for k,v in result.items() if k not in ('rows','errors')},indent=2));print('ERRORS',len(errors))

if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('root',type=Path);p.add_argument('output',type=Path);a=p.parse_args();survey(a.root,a.output)
