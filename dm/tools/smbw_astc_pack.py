#!/usr/bin/env python3
"""Selective, reversible Mario BC5_UNORM/BC7 -> ASTC4x4 overlay.

Existing ASTC, signed data textures, BC4 and HDR are deliberately preserved.
Only equal-block-size conversions are admitted: all BNTX/BFRES/SARC offsets,
uncompressed archive sizes, mip geometry and array strides remain unchanged.
Every converted mip/layer is decoded back and checked against its BC reference.
"""
from pathlib import Path
import argparse, ctypes as C, hashlib, json, os, struct, subprocess, tempfile
import numpy as np
from PIL import Image
import zstandard
from texture_survey import bntx_textures, sarc_members

class Desc(C.Structure):
    _fields_=[(x,C.c_int) for x in ['target','format','flags','samples','width','height','depth','levels','stride','pkg_block_h']]
class Layout(C.Structure):
    _fields_=[('size',C.c_uint64),('layer_size',C.c_uint64)]+[(x,C.c_uint32) for x in ['align','layers','bpb','tileH','tileD']]
FORMATS={0x1e01:0x4b,0x2001:0x4d,0x2006:0x4e}
class QualityGate(ValueError):pass

def sha(b):return hashlib.sha256(b).hexdigest()

class Converter:
    def __init__(self, root, cache, encoder, library):
        self.root=root;self.cache=cache;self.encoder=encoder;self.rows=[];self.rejected=[]
        self.encoder_hash=sha(encoder.read_bytes());cache.mkdir(parents=True,exist_ok=True)
        self.lib=C.CDLL(str(library.resolve()))
        self.lib.nvn_tex_layout.argtypes=[C.POINTER(Desc),C.POINTER(Layout)]
        self.lib.nvn_tex_level_offset.argtypes=[C.POINTER(Desc),C.c_uint];self.lib.nvn_tex_level_offset.restype=C.c_uint64
        self.lib.nvn_deswizzle.argtypes=[C.POINTER(Desc),C.c_uint,C.c_uint,C.c_void_p,C.c_void_p,C.c_size_t]
        self.lib.nvn_swizzle.argtypes=[C.POINTER(Desc),C.c_uint,C.c_uint,C.c_void_p,C.c_size_t,C.c_void_p]
        self.lib.nvn_bc_decode.argtypes=[C.c_uint,C.c_void_p,C.c_size_t,C.c_uint,C.c_uint,C.c_void_p,C.c_size_t]

    def texture(self, data, t, path):
        at=t['bntx_base']+t['data_offset'];original=bytes(data[at:at+t['image_bytes']])
        recipe={'source':sha(original),'format':t['format'],'width':t['width'],'height':t['height'],
                'layers':t['layers'],'mips':t['mips'],'block_height':t['block_height_log2'],
                'encoder':self.encoder_hash,'preset':'thorough','block':'4x4','minimum_psnr_db':40,'max_rmse':2.55}
        key=sha(json.dumps(recipe,sort_keys=True).encode());cached=self.cache/(key+'.bin');meta=self.cache/(key+'.json')
        if cached.exists() and meta.exists():
            report=json.loads(meta.read_text());payload=cached.read_bytes()
            if report['sha256']==sha(payload) and len(payload)==len(original):
                self.rows.append(dict(path=path,**t,quality=report));return payload
        desc=Desc(4 if t['layers']>1 else 1,FORMATS[t['format']],0,1,t['width'],t['height'],t['layers'],t['mips'],0,t['block_height_log2']+1)
        layout=Layout();self.lib.nvn_tex_layout(C.byref(desc),C.byref(layout))
        assert layout.size==len(original),(path,'storage size')
        assert [self.lib.nvn_tex_level_offset(C.byref(desc),i) for i in range(t['mips'])]==t['mip_offsets'],(path,'mip layout')
        storage=C.create_string_buffer(original);result=C.create_string_buffer(original);quality=[]
        with tempfile.TemporaryDirectory(dir=self.cache,suffix='.partial') as tmp:
            tmp=Path(tmp)
            for layer in range(t['layers']):
                for level in range(t['mips']):
                    w=max(1,t['width']>>level);h=max(1,t['height']>>level);pitch=((w+3)//4)*16
                    bc=C.create_string_buffer(pitch*((h+3)//4));channels=2 if t['format']==0x1e01 else 4
                    assert self.lib.nvn_deswizzle(C.byref(desc),level,layer,storage,bc,pitch)==0
                    pixels=C.create_string_buffer(w*h*channels)
                    assert self.lib.nvn_bc_decode(desc.format,bc,pitch,w,h,pixels,w*channels)==0
                    a=np.frombuffer(pixels.raw[:w*h*channels],dtype=np.uint8).reshape(h,w,channels)
                    rgba=np.zeros((h,w,4),dtype=np.uint8);rgba[:,:,:channels]=a
                    if channels==2:rgba[:,:,3]=255
                    src=tmp/'src.png';enc=tmp/'out.astc';dec=tmp/'out.png';Image.fromarray(rgba).save(src)
                    profile='s' if t['format']==0x2006 else 'l'
                    cmd=[str(self.encoder),'-c'+profile,str(src),str(enc),'4x4','-thorough','-j','2','-silent']
                    if channels==2:cmd+=['-cw','1','1','0','0']
                    subprocess.run(cmd,check=True,capture_output=True)
                    subprocess.run([str(self.encoder),'-d'+profile,str(enc),str(dec),'-silent'],check=True,capture_output=True)
                    decoded=np.array(Image.open(dec).convert('RGBA'))
                    delta=decoded[:,:,:channels].astype(np.float64)-a
                    rmse=float(np.sqrt(np.mean(delta*delta)));psnr=999.0 if rmse==0 else float(20*np.log10(255/rmse))
                    if psnr<40 or rmse>2.55:raise QualityGate(f'{path} layer={layer} mip={level} PSNR={psnr:.2f} RMSE={rmse:.3f}')
                    quality.append({'layer':layer,'mip':level,'psnr_db':psnr,'rmse_8bit':rmse,'maximum_error_8bit':int(np.max(np.abs(delta)))})
                    astc=enc.read_bytes();assert astc[:4]==b'\x13\xab\xa1\x5c' and astc[4:7]==b'\x04\x04\x01'
                    assert len(astc)==16+len(bc.raw)
                    blocks=C.create_string_buffer(astc[16:])
                    assert self.lib.nvn_swizzle(C.byref(desc),level,layer,blocks,pitch,result)==0
                    # Independent readback of the newly swizzled bytes, not just layout math.
                    check=C.create_string_buffer(len(astc)-16)
                    assert self.lib.nvn_deswizzle(C.byref(desc),level,layer,result,check,pitch)==0
                    assert check.raw==astc[16:]
        payload=result.raw[:len(original)];report={'recipe':recipe,'sha256':sha(payload),'subresources':quality,'psnr_min_db':min(x['psnr_db'] for x in quality)}
        cached.write_bytes(payload);meta.write_text(json.dumps(report,indent=2)+'\n')
        self.rows.append(dict(path=path,**t,quality=report));print('CONVERTED',len(self.rows),hex(t['format']),t['width'],t['height'],'layers',t['layers'],'minPSNR',round(report['psnr_min_db'],2),flush=True)
        return payload

    def blob(self, data, path):
        if data[:4]==b'\x28\xb5\x2f\xfd':
            raw=zstandard.ZstdDecompressor().decompress(data,max_output_size=512<<20);new=self.blob(raw,path)
            return data if new==raw else zstandard.ZstdCompressor(level=10).compress(new)
        if data[:4]==b'SARC':
            # Target BNTX members are uncompressed within these SARC files. A
            # compressed member changing size is rejected instead of relocating.
            endian='<' if data[6:8]==b'\xff\xfe' else '>'
            header=struct.unpack_from(endian+'H',data,4)[0];begin=struct.unpack_from(endian+'I',data,12)[0]
            fat=struct.unpack_from(endian+'H',data,header+4)[0];result=bytearray(data)
            for i,(name,raw) in enumerate(sarc_members(data)):
                new=self.blob(raw,path+'!'+name)
                if new!=raw:
                    if len(new)!=len(raw):raise ValueError('Nested compressed archive resize requires explicit repacking: '+path+'!'+name)
                    lo=struct.unpack_from(endian+'I',data,header+fat+i*16+8)[0];result[begin+lo:begin+lo+len(raw)]=new
            return bytes(result)
        result=bytearray(data)
        for t in bntx_textures(data):
            if t['format'] not in FORMATS:continue
            if t['depth']!=1 or t['tile_mode']!=0:raise ValueError('Unsupported target geometry: '+path)
            try:new=self.texture(data,t,path)
            except QualityGate as exc:
                self.rejected.append({'path':path,'format':t['format'],'sha256':t['sha256'],'reason':str(exc)})
                print('QUALITY_RETAIN_ORIGINAL',len(self.rejected),str(exc),flush=True);continue
            at=t['bntx_base']+t['data_offset'];result[at:at+len(new)]=new
            struct.pack_into('<I',result,t['bntx_base']+t['brti_offset']+0x1c,0x2d06 if t['format']==0x2006 else 0x2d01)
        return bytes(result)

def main():
    p=argparse.ArgumentParser();p.add_argument('romfs',type=Path);p.add_argument('inventory',type=Path);p.add_argument('output',type=Path);p.add_argument('--encoder',type=Path,required=True);p.add_argument('--library',type=Path,required=True);p.add_argument('--cache',type=Path,required=True);p.add_argument('--limit',type=int,default=0);a=p.parse_args()
    if a.output.exists():raise FileExistsError('Never overwrite a published pack: '+str(a.output))
    work=a.output.with_name(a.output.name+'.partial');work.mkdir(parents=True,exist_ok=True)
    c=Converter(a.romfs,a.cache,a.encoder,a.library);rows=json.loads(a.inventory.read_text())['rows'];paths=sorted({x['path'].split('!')[0] for x in rows if x['format'] in FORMATS})
    if a.limit:paths=paths[:a.limit]
    files=[]
    for path in paths:
        raw=(a.romfs/path).read_bytes();new=c.blob(raw,path)
        if new!=raw:
            dst=work/path;dst.parent.mkdir(parents=True,exist_ok=True);dst.write_bytes(new)
            files.append({'path':path,'source_bytes':len(raw),'source_sha256':sha(raw),'bytes':len(new),'sha256':sha(new)})
    manifest={'schema':1,'game':'010015100B514000','package':'v327680','policy':'Keep existing ASTC and SNORM/BC4/HDR; ASTC4x4 for BC5_UNORM and BC7 only, retaining any texture that fails the quality gate','files':files,'converted_texture_instances':len(c.rows),'quality_retained_original_instances':len(c.rejected),'all_subresources_psnr_at_least_db':40,'test_only_partial':bool(a.limit)}
    (work/'pack.json').write_text(json.dumps(manifest,indent=2)+'\n')
    (a.cache/'QUALITY.json').write_text(json.dumps(c.rows,indent=2)+'\n')
    (a.cache/'RETAINED_ORIGINAL.json').write_text(json.dumps(c.rejected,indent=2)+'\n')
    work.rename(a.output);print('PACK_COMPLETE',len(files),'files',len(c.rows),'texture instances',sum(x['bytes'] for x in files),'bytes',flush=True)

if __name__=='__main__':main()
