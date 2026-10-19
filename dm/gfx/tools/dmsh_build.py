#!/usr/bin/env python3
# B 路线离线出包：Switch 原版着色器 → SPIR-V（dmsh_xlate，Ryujinx 翻译器）→ spirv-cross MSL → metallib + 回放反射 JSON。
# 运行时不翻译（iOS 无 JIT）：产物进着色器缓存目录，文件名 = Switch 控制段键（dm_ctl_sha16，与 shader_map.tsv 第 4 列同）+「_b」。
# 查询作答来源：游戏档案里的作答表 dm/games/<名>/shader_facts.tsv（dmsh_facts.py）——贴图类型、顶点属性 / 片元输出分量类型、计算线程组大小与共享内存；出包不需要 PC 版文件。
# 用法：dmsh_build.py <Switch 包目录> <输出缓存目录> [键…]（不给键 = 全部）；产物实际写进 <输出缓存目录>/b-<链版本>/（IOSOUT 同），链版本见 dmsh_chain.py   环境：DM_GAME=游戏档案（缺省 smbw，dm/games/），XLATE=翻译工具路径（缺省仓内 dmsh_xlate_bin），DMSH_CAS=内容寻址缓存目录（缺省为输出缓存目录/cas），J=并发
# 程序本体内嵌的图形着色器（映射表 main.rodata@偏移 行）从 MAIN（Switch main NSO，缺省 3.3.94012 Update/ExeFS/main）解出；解 NSO 要 lz4，用 dm 的 venv python 跑
# 产物：<键>_b.metallib、<键>_b.json（回放反射，含驱动段 c0 / c2 的运行时读取偏移 drv_reads）、<键>_b.metal（MSL）
# 环境 IOSOUT=目录：同一份 MSL 经 dm/ios/tools/ios_metal.compile 同时出 iphoneos metallib + 反射（chain_metal 记 iOS 编译口径）
# 末尾汇总：成功 / 失败数与原因分布；驱动段读取的偏移分布（落在回放层能填的范围外的单列）
# Route B offline build: original Switch shaders → SPIR-V (dmsh_xlate, the Ryujinx translator) → spirv-cross MSL → metallib + replay reflection JSON.
# No translation at runtime (iOS has no JIT): build output goes into the shader cache directory, file name = Switch control segment key (dm_ctl_sha16, same as column 4 of shader_map.tsv) + "_b".
# Source of query answers: the answer table in the game profile, dm/games/<id>/shader_facts.tsv (dmsh_facts.py) - texture types, vertex attribute / fragment output component types, compute thread group size and shared memory; the build needs no PC version files.
# Usage: dmsh_build.py <Switch package dir> <output cache dir> [key...] (no keys = all); build output is actually written to <output cache dir>/b-<chain version>/ (same for IOSOUT), for the chain version see dmsh_chain.py   Environment: DM_GAME=game profile (default smbw, dm/games/), XLATE=path to the translation tool (default the in-repo dmsh_xlate_bin), DMSH_CAS=content-addressed cache dir (default <output cache dir>/cas), J=concurrency
# Graphics shaders embedded in the executable itself (mapping table rows main.rodata@offset) are extracted from MAIN (Switch main NSO, default 3.3.94012 Update/ExeFS/main); extracting the NSO needs lz4, run with dm's venv python
# Build output: <key>_b.metallib, <key>_b.json (replay reflection, including drv_reads, the runtime read offsets into driver segments c0 / c2), <key>_b.metal (MSL)
# Environment IOSOUT=dir: the same MSL also goes through dm/ios/tools/ios_metal.compile to produce an iphoneos metallib + reflection (chain_metal records the iOS compile convention)
# Final summary: success / failure counts and the distribution of reasons; distribution of driver segment read offsets (those outside the range the replay layer can fill are listed separately)
import ast, inspect, os, re, sys, json, struct, hashlib, shutil, subprocess, tempfile, collections, threading, concurrent.futures as cf
DM_ROOT = os.environ.get('DM_ROOT') or os.path.expanduser('~/dm-work')   # 工作区根目录（游戏文件、产物、运行现场都在它下面） | Workspace root (game files, build outputs and run artifacts are all under it)
HOME = os.path.expanduser('~')
dm_dir, out = sys.argv[1:3]; want = set(sys.argv[3:]); cache_root = out
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__))); import dmsh_chain, dmsh_fetch, dmsh_facts   # 翻译链版本：先核工具与锁文件，产物进 b-<V>/ | translation chain version: verify the tools against the lock file first; build output goes into b-<V>/
_bad = dmsh_chain.check_tools()
if _bad: sys.exit('\n'.join('【红】翻译链工具与锁文件不符：' + b for b in _bad) + '\n（换了工具就 dmsh_chain.py --update-lock 并入仓；只是没重编翻译器就重编）')
CHAIN = dmsh_chain.version(); out = os.path.join(out, 'b-' + CHAIN)
GAME = dmsh_chain.GAME   # 当前游戏档案（DM_GAME，缺省 smbw）：表与 NVN 常数都从这里取 | the current game profile (DM_GAME, default smbw): the tables and NVN constants come from here
if f'"{CHAIN}"' not in open(dmsh_chain.HEADER).read(): sys.exit(f'【红】{dmsh_chain.HEADER} 不是当前翻译链版本 {CHAIN}：先跑 dmsh_chain.py --header（否则宿主找不到这批库）')
XLATE = os.environ.get('XLATE', os.path.join(dmsh_chain.XLATE_DIR, 'dmsh_xlate'))
FACTS = dmsh_facts.load()
if not os.path.exists(dmsh_facts.TABLE): sys.exit(f'【红】没有作答表 {dmsh_facts.TABLE}（随游戏档案；空表 = 全部按缺省作答）')
IOSOUT = os.environ.get('IOSOUT')   # 设了就同时出 iOS 版（iphoneos metallib + 反射）到该目录 | if set, also build the iOS version (iphoneos metallib + reflection) into that directory
if IOSOUT:
    sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '../../ios/tools')); import ios_metal
    IOSOUT = os.path.join(IOSOUT, 'b-' + CHAIN); os.makedirs(IOSOUT, exist_ok=True)
MAIN = os.environ.get('MAIN', f'{DM_ROOT}/data/switch/3.3.94012/Update/ExeFS/main')
MAP = str(GAME.table('shader_map.tsv'))
BF_WANT_FILE = str(GAME.table('bf_want.tsv'))
BF_WANT = {line.strip() for line in open(BF_WANT_FILE) if line.strip() and not line.lstrip().startswith('#')} if os.path.exists(BF_WANT_FILE) else set()
XC = ['--msl', '--msl-version', '20300', '--msl-argument-buffers', '--msl-texture-buffer-native', '--msl-pad-fragment-output']
CAS = os.environ.get('DMSH_CAS', os.path.join(cache_root, 'cas'))
CAS_LOCKS, CAS_LOCKS_GUARD = {}, threading.Lock()
PRE_STATS = collections.Counter()
# Match position arithmetic across depth and colour passes (upstream f1cc6be850cf).
MAC_METAL = ['xcrun', '-sdk', 'macosx', 'metal', '-c', '-fpreserve-invariance']
MAC_RECORD = ' '.join(MAC_METAL) + '; xcrun -sdk macosx metallib'
# 贴图句柄表（贴图指令立即数句柄所在的驱动段）：马力欧（NVN 55）是 0x20 + 8 r、32 槽——全库 4888 个着色器的立即数句柄恰是 0x20..0xF0、步长 8（D2R 的旧驱动是 0x168）。
#   本作只用合并句柄（nvnCommandBufferBindTexture），没有分离采样器；图像句柄表仍在 0x120 + 8 r（8 槽，紧接贴图表之后；agl 的 10 个计算着色器实测 0x120 / 0x128 / 0x130，与 D2R 同址）。
# Texture handle table (the driver segment holding texture instructions' immediate handles): Mario (NVN 55) uses 0x20 + 8 r, 32 slots - the immediate handles of all 4888 shaders are exactly 0x20..0xF0 in steps of 8 (D2R's older driver used 0x168).
#   This game uses only combined handles (nvnCommandBufferBindTexture), with no separate samplers; the image handle table is still at 0x120 + 8 r (8 slots, right after the texture table; measured 0x120 / 0x128 / 0x130 on agl's 10 compute shaders, the same address as D2R).
TEX_BASE, TEX_SLOTS, SAMP_BASE, IMG_BASE, IMG_SLOTS = (GAME.int(k) for k in ('nvn_tex_base', 'nvn_tex_slots', 'nvn_samp_base', 'nvn_img_base', 'nvn_img_slots'))
SSBO = {k: int(v, 0) for k, v in GAME.pairs('nvn_ssbo_bases')}   # c0 存储缓冲表基址（按阶段） | c0 storage buffer table bases (per stage)
# 翻译器（dmsh_xlate/Program.cs）内置了贴图 / 采样器句柄表基址，只用来把句柄换成槽号、去作答表里查该槽的贴图 / 图像类型（TexSlot）；绑定的槽号由本脚本按档案解（decode_tex）。
#   所以只有作答表里有按槽的贴图 / 图像事实时，档案的基址才必须与翻译器内置值相同（否则查错槽）；Engage（0x168 / 0x568）作答表没有这类事实，翻译器不用改
# The translator (dmsh_xlate/Program.cs) has the texture / sampler handle table bases built in, used only to turn a handle into a slot and look up that slot's texture / image type in the answer table (TexSlot); the bindings' slots are decoded by this script from the profile (decode_tex).
#   So the profile's bases must equal the translator's only when the answer table has per-slot texture / image facts (otherwise the wrong slot is looked up); Engage (0x168 / 0x568) has no such facts, so the translator needs no change
_xb = re.search(r'const int TexBase = (0x[0-9a-fA-F]+), SampBase = (0x[0-9a-fA-F]+);', open(os.path.join(os.path.dirname(os.path.abspath(__file__)), 'dmsh_xlate/Program.cs')).read())
if (not _xb or (int(_xb.group(1), 16), int(_xb.group(2), 16)) != (TEX_BASE, SAMP_BASE)) and any(f.get('tex') or f.get('img') for f in FACTS.values()):
    sys.exit(f'【红】游戏档案 {GAME.id} 的 nvn_tex_base / nvn_samp_base（{TEX_BASE:#x} / {SAMP_BASE:#x}）与翻译器内置值不同（dmsh_xlate/Program.cs TexBase / SampBase），而作答表里有按槽的贴图 / 图像事实：先让翻译器按档案取值')

def records(d):
    r = [m.start() for m in re.finditer(b'BTCDBTCD', d)]
    return [d[x:(r[k + 1] if k + 1 < len(r) else len(d))] for k, x in enumerate(r)]

def clone(src, dst):
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    tmp = dst + '.tmp-' + str(os.getpid()) + '-' + str(threading.get_ident())
    r = subprocess.run(['cp', '-c', src, tmp], stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, timeout=60)
    if r.returncode:
        shutil.copyfile(src, tmp)
    os.replace(tmp, dst)

def atomic_json(path, value):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = path + '.tmp-' + str(os.getpid()) + '-' + str(threading.get_ident())
    with open(tmp, 'w') as f: json.dump(value, f, ensure_ascii=False, indent=1)
    os.replace(tmp, path)

def source_without_rule_bodies():
    source = open(__file__, 'r').read(); lines = source.splitlines(True); tree = ast.parse(source)
    names = {f.__name__ for f, _ in RULES}
    for node in ast.walk(tree):
        if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)) and node.name in names and node.body:
            first = node.body[0].lineno - 1
            last = max(getattr(x, 'end_lineno', x.lineno) for x in ast.walk(node) if getattr(x, 'lineno', 0) >= node.body[0].lineno)
            indent = re.match(r'\s*', lines[first]).group(0); lines[first:last] = [indent + 'pass\n']
    return ''.join(lines)

def shader_rule_source(name):
    return b''.join(inspect.getsource(f).encode() for f, applies in RULES if applies(name))

def tool_fingerprint():
    sc = subprocess.run(['spirv-cross', '--version'], capture_output=True, text=True, timeout=30)
    return ('lock\0' + open(dmsh_chain.LOCK).read() + '\0options\0' + dmsh_chain.options() +
            '\0xlate\0' + dmsh_chain.xlate_source_sha() + '\0spirv-cross\0' + sc.stdout + sc.stderr +
            '\0xc\0' + repr(XC) + '\0mac\0' + MAC_RECORD + '\0ios\0' + (ios_metal.RECORD if IOSOUT else ''))

def shader_key(key, name, rec):
    pc = dmsh_facts.row(key, FACTS[key]).encode() if key in FACTS else '缺'.encode()
    map_row = MAP_ROWS.get(key, '缺'.encode()) + MAP_CONFLICT_ROWS.get(key, b'')
    embedded = rec if name.startswith('main.rodata@') else b''
    payload = (b'record\0' + rec + b'\0map\0' + map_row + b'\0pc\0' + pc + b'\0embedded\0' + embedded +
               b'\0tools\0' + TOOL_FP + b'\0code\0' + CODE_FP.encode() +
               b'\0rule\0' + shader_rule_source(name))
    return hashlib.sha256(payload).hexdigest()

def cache_meta_path(key): return os.path.join(CAS, 'index', key + '.json')
def cache_path(digest): return os.path.join(CAS, 'shader', digest)

def cache_outputs(key, digest, cached=False):
    root = cache_path(digest); files = {}
    for label, directory, names in (
            ('mac', out, [key + '_b.metallib', key + '_b.metal', key + '_b.json']),
            ('ios', IOSOUT, [key + '_b.metallib', key + '_b.json'])):
        if not directory: continue
        base = os.path.join(root, label) if cached else directory
        found = [n for n in names if os.path.exists(os.path.join(base, n))]
        if key + '_b.metallib' not in found or key + '_b.json' not in found: return None
        files[label] = found
    return root, files

def restore_cache(key, digest):
    found = cache_outputs(key, digest, cached=True)
    if not found: return False
    root, files = found
    for label, names in files.items():
        directory = out if label == 'mac' else IOSOUT
        for name in names:
            src = os.path.join(root, label, name); dst = os.path.join(directory, name)
            if name.endswith('.json'):
                tmp = dst + '.tmp-' + str(os.getpid()) + '-' + str(threading.get_ident())
                with open(tmp, 'wb') as f: f.write(re.sub(rb'("chain"\s*:\s*")[^"]*"', rb'\g<1>' + CHAIN.encode() + b'"', open(src, 'rb').read(), count=1))
                os.replace(tmp, dst)
            else: clone(src, dst)
    return True

def cache_lookup(key, digest, rule_fp, code_fp):
    with CAS_LOCKS_GUARD: lock = CAS_LOCKS.setdefault(('shader', key), threading.Lock())
    with lock:
        if restore_cache(key, digest): PRE_STATS['hit'] += 1; return True, '命中'
        old = json.load(open(cache_meta_path(key))) if os.path.exists(cache_meta_path(key)) else None
        if old and old.get('code_fp') != code_fp: reason = '代码指纹变化：全部重出'
        elif old and old.get('rule_fp') != rule_fp: reason = '规则变'
        else: reason = '新键'
        PRE_STATS['miss'] += 1; PRE_STATS[reason] += 1; return False, reason

def publish_cache(key, digest, rule_fp, code_fp):
    found = cache_outputs(key, digest)
    if not found: return
    root, files = found
    for label, names in files.items():
        d = os.path.join(root, label); os.makedirs(d, exist_ok=True)
        for name in names: clone(os.path.join(out if label == 'mac' else IOSOUT, name), os.path.join(d, name))
        for name in names:
            if name.endswith('.json'):
                src = os.path.join(out if label == 'mac' else IOSOUT, name)
                value = json.load(open(src)); value.pop('fetch', None)
                atomic_json(os.path.join(d, name), value)
    atomic_json(cache_meta_path(key), {'digest': digest, 'rule_fp': rule_fp, 'code_fp': code_fp})

BF_STATS = collections.Counter()

def bf_digest(msl, key):
    h = hashlib.sha256()
    h.update(msl.encode())
    h.update(b'\0mac\0' + MAC_RECORD.encode())
    h.update(b'\0ios\0' + (ios_metal.RECORD if IOSOUT else '').encode())
    h.update(b'\0bf-want\0' + (b'1' if key in BF_WANT else b'0'))
    return h.hexdigest()

def bf_cache_root(digest): return os.path.join(CAS, 'variant', digest)

def bf_cache_restore(key, digest, fmeta, fmsl):
    root = bf_cache_root(digest)
    names = ['metal', 'mac.metallib'] + (['ios.metallib'] if IOSOUT else [])
    if not all(os.path.exists(os.path.join(root, n)) for n in names): return False
    clone(os.path.join(root, 'metal'), fmsl)
    clone(os.path.join(root, 'mac.metallib'), os.path.join(out, key + '_bf.metallib'))
    if IOSOUT: clone(os.path.join(root, 'ios.metallib'), os.path.join(IOSOUT, key + '_bf.metallib'))
    BF_STATS['hit'] += 1
    return True

def bf_cache_publish(digest, fmsl, maclib, ioslib, fmeta):
    root = bf_cache_root(digest); os.makedirs(root, exist_ok=True)
    clone(fmsl, os.path.join(root, 'metal'))
    clone(maclib, os.path.join(root, 'mac.metallib'))
    if IOSOUT: clone(ioslib, os.path.join(root, 'ios.metallib'))
    atomic_json(os.path.join(root, 'fetch.json'), fmeta)

def write_refl(key, refl):
    for d, rec in ((out, MAC_RECORD),) + (((IOSOUT, ios_metal.RECORD),) if IOSOUT else ()):
        value = dict(refl, chain_metal=rec)
        atomic_json(os.path.join(d, key + '_b.json'), value)

def fetch_finish(key, src, refl):
    if refl['stage'] != 'ps': return refl
    # 有可改采样的照旧出变体；没有可改采样的只给名单（bf_want.tsv，宿主规划器产出）里的键出仅输出映射变体
    # Those with rewritable samples get variants as before; those without get an output-mapping-only variant, and only for keys in the list (bf_want.tsv, produced by the host planner)
    fv, fmeta = dmsh_fetch.variant(src, refl['bindings'], om_only_ok=key in BF_WANT)
    if not fv:
        for path in (os.path.join(out, key + '_bf.metallib'), os.path.join(out, key + '_bf.metal')) + ((os.path.join(IOSOUT, key + '_bf.metallib'),) if IOSOUT else ()):
            try: os.unlink(path)
            except FileNotFoundError: pass
        write_refl(key, refl)
        return refl
    BF_STATS['generated'] += 1
    fmsl = os.path.join(out, key + '_bf.metal')
    digest = bf_digest(fv, key)
    with CAS_LOCKS_GUARD: lock = CAS_LOCKS.setdefault(('variant', digest), threading.Lock())
    with lock:
        try:
            if not bf_cache_restore(key, digest, fmeta, fmsl):
                BF_STATS['miss'] += 1
                open(fmsl, 'w').write(fv)
                fair = fmsl[:-6] + '.air'; flib = os.path.join(out, key + '_bf.metallib')
                try:
                    subprocess.run([*MAC_METAL, fmsl, '-o', fair], check=True)
                    tmp_flib = flib + '.tmp-' + str(os.getpid())
                    subprocess.run(['xcrun', '-sdk', 'macosx', 'metallib', fair, '-o', tmp_flib], check=True)
                    os.replace(tmp_flib, flib)
                    ilib = None
                    if IOSOUT:
                        ilib = os.path.join(IOSOUT, key + '_bf.metallib')
                        ios_metal.compile(fmsl, fmsl[:-6] + '.ios.air', ilib + '.tmp')
                        os.replace(ilib + '.tmp', ilib)
                except subprocess.CalledProcessError:
                    return refl
                BF_STATS['compile'] += 1
                bf_cache_publish(digest, fmsl, flib, ilib, fmeta)
        finally:
            for path in (fmsl, fmsl[:-6] + '.air', fmsl[:-6] + '.ios.air'):
                try: os.unlink(path)
                except FileNotFoundError: pass
    refl['fetch'] = fmeta
    write_refl(key, refl)
    return refl

pc_of, loc, stage_of = {}, {}, {}
MAP_ROWS, MAP_CONFLICT_ROWS = {}, {}
for raw in open(MAP, 'rb'):
    c = raw.rstrip(b'\n').split(b'\t')
    if len(c) > 4: MAP_ROWS.setdefault(c[3].decode(), raw)
for raw in open(MAP + '.conflicts.tsv', 'rb'):
    c = raw.rstrip(b'\n').split(b'\t')
    if len(c) > 1 and not raw.startswith((b'#', b'dm_')): MAP_CONFLICT_ROWS.setdefault(c[0].decode(), raw)
for ln in open(MAP):
    c = ln.rstrip('\n').split('\t')
    if len(c) > 4 and c[0].endswith('.bin'): pc_of.setdefault(c[3], c[4]); loc.setdefault(c[3], (c[0], int(c[1])))
    if len(c) > 4 and c[0].startswith('main.rodata@'):   # 内嵌：位置 = main 映像偏移（控制段起点），阶段取映射表第 3 列 | embedded: location = main image offset (start of the control segment), stage taken from column 3 of the mapping table
        pc_of.setdefault(c[3], c[4]); loc.setdefault(c[3], (c[0], int(c[0].split('@')[1], 16))); stage_of[c[3]] = {'顶点': 'vs', '像素': 'ps'}[c[2]]
for ln in open(MAP + '.conflicts.tsv'):
    c = ln.rstrip('\n').split('\t')
    if len(c) > 1 and not ln.startswith('#') and not ln.startswith('dm_') and c[0] in pc_of: pc_of[c[0]] = c[1]

def main_rec(mi, o):
    """内嵌着色器 → 与包内记录同布局的字节：包内记录 +0x38 起是代码区（0x30 头 + SPH + 指令，标记 78563412），紧接控制段（34127698）；
    内嵌的代码区紧贴在控制段之前（核对 5 个：代码区长 0x100–0x300、c1 均为空，与同名包内记录布局一致）
    Embedded shader → bytes in the same layout as a package record: in a package record the code area starts at +0x38 (0x30 header + SPH + instructions, marker 78563412), immediately followed by the control segment (34127698);
        the embedded code area sits immediately before the control segment (checked 5: code area length 0x100–0x300, c1 empty in all, consistent with the layout of the same-named package records)"""
    g = mi.rfind(bytes.fromhex('78563412'), o - 0x1000, o)
    if g < 0 or mi[o:o + 4] != bytes.fromhex('34127698'): sys.exit(f'【红】main 映像 @{o:#x} 不是内嵌着色器控制段（MAIN={MAIN}）')
    return bytes(0x38) + mi[g:o + 0x880]

def job_for(key, name, rec, w):
    ci = rec.find(bytes.fromhex('34127698')); code = rec[0x38:ci]; stage = stage_of.get(key, name[:2])
    c1o, c1t = struct.unpack_from('<2I', rec, ci + 0x700)   # 控制段 +0x700：c1 相对指令区起点、+0x704：指令区总长（c1 = 两者之间；全库长度 0 / 256 / 512 / 768） | control segment +0x700: c1 relative to the start of the instruction area, +0x704: total length of the instruction area (c1 = what lies between the two; lengths across the whole library are 0 / 256 / 512 / 768)
    c1 = rec[0x38 + c1o:0x38 + c1t]
    if stage != 'cs': code = code[0x30:]   # 去 0x30 头（其后 0x50 SPH 由翻译器自己读） | strip the 0x30 header (the 0x50 SPH after it is read by the translator itself)
    elif code[:4] == bytes.fromhex('79563412'):
        # 计算阶段本作有头（魔数 0x12345679，D2R 的包记录没有）：头 0x30 + 零填充，指令从代码区 +0x100 起（全库 71 个实测；BRA 自跳与控制字都按这个起点 32 字节对齐）。
        # 只去 0x30 时翻译器从 +0x30 起解码：每 32 字节的控制字位置错开 0x10，间接跳转 BRX 的跳转表（相对程序起点）全部错位 → 粒子 / 后处理计算着色器死循环、GPU 卡死。
        # Compute in this game has a header (magic 0x12345679; D2R's package records have none): 0x30 header + zero padding, instructions start at code area +0x100 (measured on all 71; the BRA-to-self and the control words are 32-byte aligned to this start).
        # Stripping only 0x30 made the translator decode from +0x30: the control word every 32 bytes is off by 0x10 and the jump tables of indirect BRX (relative to the program start) are all misplaced → particle / post-effect compute shaders loop forever and hang the GPU.
        if any(code[0x30:0x100]): sys.exit(f'【红】{key}：计算代码区 +0x30..+0x100 不全为零，指令起点不是 +0x100')
        code = code[0x100:]
    cp = os.path.join(w, key + '.bin'); open(cp, 'wb').write(code)
    j = {'key': key, 'stage': stage, 'code': cp, 'tex': {}, 'img': {}, 'attr': {}, 'fout': {}, 'c1': c1.hex(),
         'debug': os.environ.get('XLATE_DEBUG', '1') != '0', 'reduced': os.environ.get('XLATE_REDUCED', '1') == '1'}   # 翻译选项（见 dmsh_xlate/Program.cs）；放宽精度缺省开（GPU 浮点末位误差不进游戏状态，mini 整帧 −26%）   # c1：翻译器读间接跳转表用 | translation options (see dmsh_xlate/Program.cs); relaxed precision is on by default (GPU float last-bit error does not enter game state, whole frame −26% on the second Mac)   # c1: used by the translator to read indirect jump tables
    if key not in FACTS: j['pc_missing'] = True; return j, c1   # 作答表里没有：查询按缺省（汇总里单列） | not in the answer table: queries use defaults (listed separately in the summary)
    j.update(FACTS[key])
    return j, c1

def raster_facts(stage, src):
    """读入可省（全覆盖首绘）的运行时证明所需的静态事实（nvn_mtl.m first_draw_covers）：
    顶点：位置 x / y / z 是否原样取自同一个顶点属性的 .x / .y / .z（w 为常数 1 或同属性 .w），主函数无分支、无裁剪距离——是则 pos_attr = 属性槽；
    片元：是否可能丢弃（discard_fragment）、是否写 sample_mask、写出的颜色号。认不出一律按「不可证」（pos_attr = -1 / discard = 1）
    Static facts needed for the runtime proof that the load can be skipped (full-coverage first draw) (nvn_mtl.m first_draw_covers):
        Vertex: whether position x / y / z are taken unchanged from the .x / .y / .z of one and the same vertex attribute (w is the constant 1 or the same attribute's .w), with no branches and no clip distances in the main function - if so, pos_attr = attribute slot;
        Fragment: whether it may discard (discard_fragment), whether it writes sample_mask, and which color indices it writes. Anything unrecognized is treated as "unprovable" (pos_attr = -1 / discard = 1)"""
    if stage == 'ps':
        out = re.search(r'struct main0_out\s*\{(.*?)\};', src, re.S)
        return {'discard': int('discard_fragment' in src), 'sample_mask': int('sample_mask' in (out.group(1) if out else '')),
                'colors': sorted({int(x) for x in re.findall(r'\[\[color\((\d+)\)\]\]', out.group(1) if out else '')})}
    if stage != 'vs': return {}
    body = re.search(r'\bvertex\s+\w+\s+\w+\s*\(.*?\)\s*\{(.*)\}\s*$', src, re.S)   # 主函数是文件里最后一个函数 | the main function is the last function in the file
    if not body or re.search(r'\b(if|for|while|switch|do)\b|clip_distance|ClipDistance', body.group(1)): return {'pos_attr': -1}
    b = body.group(1)
    attr = {m.group(2): int(m.group(3)) for m in re.finditer(r'(\w+)\s+(\w+)\s*\[\[attribute\((\d+)\)\]\]', src)}
    var = {m.group(1): (m.group(2), m.group(3)) for m in re.finditer(r'float\s+(_\w+)\s*=\s*in\.(\w+)\.([xyzw]);', b)}
    last = {}
    for m in re.finditer(r'out\.gl_Position\.([xyzw])\s*=\s*([^;]+);', b): last[m.group(1)] = m.group(2).strip()
    src_of = {c: var.get(v) for c, v in last.items()}
    m0 = src_of.get('x')
    if not m0 or m0[0] not in attr or any(src_of.get(c) != (m0[0], c) for c in 'xyz'): return {'pos_attr': -1}
    if last.get('w') == '1.0': w = 'one'
    elif src_of.get('w') == (m0[0], 'w'): w = 'attr'
    else: return {'pos_attr': -1}
    # uv 直传（合并 B 第 2 步「本像素寻址」证明用）：插值输出 locn K 的 .x / .y 原样取自顶点属性 A 的 .x / .y → uv_from_attr[K] = A
    # uv pass-through (used for the "this-pixel addressing" proof in merge B step 2): the .x / .y of interpolated output locn K are taken unchanged from the .x / .y of vertex attribute A → uv_from_attr[K] = A
    ost = re.search(r'struct main0_out\s*\{(.*?)\};', src, re.S)
    locn = {m.group(1): int(m.group(2)) for m in re.finditer(r'(m_\d+) \[\[user\(locn(\d+)\)\]\]', ost.group(1) if ost else '')}
    olast = {}
    for m in re.finditer(r'out\.(m_\d+)\.([xyzw])\s*=\s*([^;]+);', b): olast[(m.group(1), m.group(2))] = m.group(3).strip()
    uv, aff = {}, {}
    for mem, k in locn.items():
        sx, sy = var.get(olast.get((mem, 'x'), '')), var.get(olast.get((mem, 'y'), ''))
        if sx and sy and sx[0] == sy[0] and sx[0] in attr and sx[1] == 'x' and sy[1] == 'y': uv[str(k)] = attr[sx[0]]; continue
        # 仿射：分量 = fma(属性分量, uniform[槽].向量[i].分量, uniform[槽].向量[j].分量)（vp_cN 即 uniform 槽 N − 3）
        # Affine: component = fma(attribute component, uniform[slot].vector[i].component, uniform[slot].vector[j].component) (vp_cN is uniform slot N − 3)
        def fm(v_):
            m = re.search(r'float %s = fma\((_\w+), \(\*spvDescriptorSet0\.vp_c(\d+)\)\._m0\[(\d+)\]\.([xyzw]), \(\*spvDescriptorSet0\.vp_c(\d+)\)\._m0\[(\d+)\]\.([xyzw])\);' % re.escape(v_), b)
            if not m or m.group(1) not in var: return None
            return var[m.group(1)], [int(m.group(2)) - 3, int(m.group(3)), 'xyzw'.index(m.group(4))], [int(m.group(5)) - 3, int(m.group(6)), 'xyzw'.index(m.group(7))]
        fx, fy = fm(olast.get((mem, 'x'), '')), fm(olast.get((mem, 'y'), ''))
        if fx and fy and fx[0][0] == fy[0][0] and fx[0][0] in attr and fx[0][1] == 'x' and fy[0][1] == 'y' and min(fx[1][0], fx[2][0], fy[1][0], fy[2][0]) >= 0:
            aff[str(k)] = {'attr': attr[fx[0][0]], 'sx': fx[1], 'ox': fx[2], 'sy': fy[1], 'oy': fy[2]}
    return {'pos_attr': attr[m0[0]], 'pos_w': w, 'uv_from_attr': uv, 'uv_affine': aff}

def decode_tex(name):
    """fp_t_cb{slots}_{handle} / fp_t_tcb_{handle}：贴图槽、采样器槽（Ryujinx TextureHandle 编码；c[2] 句柄表） | fp_t_cb{slots}_{handle} / fp_t_tcb_{handle}: texture slot, sampler slot (Ryujinx TextureHandle encoding; c[2] handle table)"""
    m = re.match(r'[a-z]+_[ti]\w*?_(?:cb(\d+)|tcb)_([0-9A-F]+)', name)
    if not m: return None
    slots = int(m.group(1)) if m.group(1) else -1; h = int(m.group(2), 16)
    tb = (slots & 0xffff) if slots >= 0 else 2; sb = ((slots >> 16) - 1) if slots >= 0 and (slots >> 16) else tb
    o0, o1, ty = h & 0x3fff, (h >> 14) & 0x3fff, h >> 28
    def slot(word, base, cb): return (word * 4 - base) // 8 if cb == 2 and word * 4 >= base and (word * 4 - base) % 8 == 0 else None
    words = [o0] + ([o1] if ty else [])
    if re.match(r'[a-z]+_i', name):   # 图像 | image
        return next((slot(x, IMG_BASE, tb) for x in words if IMG_BASE <= x * 4 < IMG_BASE + 8 * IMG_SLOTS and slot(x, IMG_BASE, tb) is not None), None), None, ty
    t = next((slot(x, TEX_BASE, tb) for x in words if slot(x, TEX_BASE, tb) is not None and x * 4 < TEX_BASE + 8 * TEX_SLOTS), None)
    s = next((slot(x, SAMP_BASE, sb) for x in words if x * 4 >= SAMP_BASE and slot(x, SAMP_BASE, sb) is not None), None)
    return t, s, ty

def decode_ubo_tex(name):
    """无绑定贴图：句柄由游戏写在自己的 uniform 缓冲里（fp_t_cb7_2A = c[7] 第 0x2A 字）。返回 (贴图: (uniform 槽, 字节偏移), 采样器: (槽, 偏移))；
    句柄类型 0 = 合并句柄（同一个 32 位字：低 20 位贴图号、高 12 位采样器号），1 = 采样器句柄在另一个字（槽取 slots 高 16 位 − 1）。本作全库只有类型 0（1850 个着色器）
    Bindless texture: the handle is written by the game into its own uniform buffer (fp_t_cb7_2A = c[7] word 0x2A). Returns (texture: (uniform slot, byte offset), sampler: (slot, offset));
    handle type 0 = combined handle (one 32-bit word: low 20 bits texture ID, high 12 bits sampler ID), 1 = the sampler handle is in another word (its slot is the high 16 bits of slots − 1). This game's whole library uses only type 0 (1850 shaders)"""
    m = re.match(r'[a-z]+_t\w*?_cb(\d+)_([0-9A-F]+)', name)
    if not m: return None
    slots, h = int(m.group(1)), int(m.group(2), 16)
    tb = slots & 0xffff; sb = (slots >> 16) - 1 if slots >> 16 else tb
    o0, o1, ty = h & 0x3fff, (h >> 14) & 0x3fff, h >> 28
    if not 3 <= tb <= 16 or ty not in (0, 1) or (ty and not 3 <= sb <= 16): return None
    return (tb - 3, o0 * 4), ((sb - 3, o1 * 4) if ty else (tb - 3, o0 * 4))

def reflect(key, stage, msl, res):
    """MSL 参数缓冲结构体成员 → 回放反射：kind（同 nvn_refl.h）+ NVN 槽号 + 参数缓冲成员号 | MSL argument buffer struct member → replay reflection: kind (same as nvn_refl.h) + NVN slot number + argument buffer member index"""
    body = re.search(r'struct spvDescriptorSetBuffer0\s*\{(.*?)\};', msl, re.S)
    sb_cb = {b['binding']: b for b in res['sbufs']}
    binds = []
    for m in re.finditer(r'^\s*(.+?)\s+(\w+)\s*\[\[id\((\d+)\)\]\];', body.group(1) if body else '', re.M):
        ty, nm, aid = m.group(1).strip(), m.group(2), int(m.group(3))
        e = {'msl_name': nm, 'msl_type': ty, 'arg_id': aid}
        if nm == 'support_buffer': e.update(kind='support')
        elif re.fullmatch(r'[a-z]+_c(\d+)', nm):
            n = int(re.fullmatch(r'[a-z]+_c(\d+)', nm).group(1))
            e.update(kind='cbuf', reg=n - 3) if 3 <= n <= 16 else e.update(kind='c1' if n == 1 else 'drvcb', bank=n)
        elif re.fullmatch(r'[a-z]+_s(\d+)', nm):
            e.update(kind='sbuf', index=int(re.fullmatch(r'[a-z]+_s(\d+)', nm).group(1)))
        elif decode_ubo_tex(nm[:-5] if nm.endswith('Smplr') else nm):   # 无绑定：句柄在 uniform 缓冲里（reg = uniform 槽，off = 字节偏移） | bindless: the handle is in a uniform buffer (reg = uniform slot, off = byte offset)
            ut, us = decode_ubo_tex(nm[:-5] if nm.endswith('Smplr') else nm)
            if nm.endswith('Smplr'): e.update(kind='samp_ubo', reg=us[0], off=us[1])
            elif 'texture_buffer' in ty: e.update(kind='?')   # 无绑定类型化缓冲：回放层未实现 | bindless typed buffer: not implemented in the replay layer
            else: e.update(kind='tex_ubo', reg=ut[0], off=ut[1])
        elif nm.endswith('Smplr'):   # 句柄类型 0 = 贴图与采样器合在同一句柄：采样器号取该贴图槽句柄的高位 | handle type 0 = texture and sampler combined in one handle: the sampler index is taken from the high bits of that texture slot's handle
            t, s, ty = decode_tex(nm[:-5]); e.update(kind='samp', reg=s) if ty else e.update(kind='samp_tex', reg=t)
        else:
            d = decode_tex(nm)
            if not d: e.update(kind='?')
            else: e.update(kind='img' if re.match(r'[a-z]+_i', nm) else ('tbuf' if 'texture_buffer' in ty else 'tex'), reg=d[0])
        binds.append(e)
    # 存储缓冲：SPIR-V 绑定号 → c0 偏移 → NVN 存储缓冲槽（c0 基址：顶点 0x110、计算 0x310、像素 0x510，每槽 0x10）
    # Storage buffers: SPIR-V binding number → c0 offset → NVN storage buffer slot (c0 base: vertex 0x110, compute 0x310, pixel 0x510, 0x10 per slot)
    base = SSBO.get(stage)   # 外壳 / 域阶段的存储缓冲基址未实测：遇到存储缓冲按「无槽」报 | storage buffer base for the hull / domain stages has not been measured: a storage buffer there is reported as 「无槽」(no slot)
    sb_sorted = sorted(res['sbufs'], key=lambda b: b['binding'])
    for e in binds:
        if e['kind'] == 'sbuf':
            b = sb_sorted[e['index']] if e['index'] < len(sb_sorted) else None
            off = b['cb_offset'] * 4 if b and b['cb_slot'] == 0 else None
            if stage == 'cs' and off is not None and 0x210 <= off < 0x310 and (off - 0x210) % 16 == 0:
                e.update(kind='ubo_ptr', reg=(off - 0x210) // 16)   # 计算阶段 uniform 槽 r：地址在 c0[0x210 + 0x10 r]，经全局内存读（cs_lut_combine_c 读 cb10[66] 核对） | compute-stage uniform slot r: address at c0[0x210 + 0x10 r], read through global memory (checked against cs_lut_combine_c reading cb10[66])
            else: e['reg'] = (off - base) // 16 if off is not None and base is not None and 0 <= off - base < 0x100 and (off - base) % 16 == 0 else None
            e['rw'] = bool(b and b['flags'] & 2)
    return binds

DRV_FILL = {0: [(b, b + 0x100) for b in sorted(SSBO.values())],   # c0：存储缓冲地址表（顶点 / 计算 / 像素，各 16 槽 × 0x10） | c0: storage buffer address tables (vertex / compute / pixel, 16 slots × 0x10 each)
            2: [(TEX_BASE, TEX_BASE + 8 * TEX_SLOTS), (IMG_BASE, IMG_BASE + 8 * IMG_SLOTS), (SAMP_BASE, SAMP_BASE + 8 * 128)]}
# c2：贴图句柄表（马力欧 0x20 + 8 r、32 槽；Engage 0x168 + 8 r、128 槽）、图像句柄表（0x120 + 8 r，8 槽）、分离采样器句柄表（0x568 + 8 r，128 槽；回放层都现填）
# c2: texture handle table (Mario 0x20 + 8 r, 32 slots; Engage 0x168 + 8 r, 128 slots), image handle table (0x120 + 8 r, 8 slots), separate sampler handle table (0x568 + 8 r, 128 slots; the replay layer fills them all)

def drv_reads(src):
    """MSL 里对驱动段 c0 / c2 的读取：常量下标 → 字节区间；非常量下标记为动态 | Reads of driver segments c0 / c2 in the MSL: constant index → byte range; non-constant indices are recorded as dynamic"""
    out = {}
    for bank in (0, 2):
        offs, dyn = set(), False
        for m in re.finditer(r'fp_c%d\)\._m0\[([^\]]+)\]' % bank, src):
            idx = m.group(1).rstrip('u')
            if idx.isdigit(): offs.add(int(idx) * 16)
            else: dyn = True
        if offs or dyn: out[str(bank)] = {'vec4_offsets': sorted(offs), 'dynamic': dyn}
    return out

def unfillable(dr):
    bad = []
    for bank, d in dr.items():
        if d['dynamic']: bad.append(f'c{bank} 动态下标')
        for o in d['vec4_offsets']:
            # 读的是 16 字节一行：与任一张表相交即可（Engage 读 c2+0x160 那一行，是为了其中 0x168 的贴图槽 0）
            # a read is a 16-byte row: overlapping any table is enough (Engage reads the c2+0x160 row for texture slot 0 at 0x168 in it)
            if not any(o < b and a < o + 16 for a, b in DRV_FILL[int(bank)]): bad.append(f'c{bank}+{o:#x}')
    return bad

RULES = []   # 按着色器名挂的 MSL 改写规则（函数, 适用判定）；原有的暗部重映射 toe 已删（回到 Switch 原版亮度） | MSL rewrite rules attached by shader name (function, applicability test); the former dark-range remap toe has been removed (back to the original Switch brightness)
# 第一段代码指纹不包含 dmsh_fetch.py；可读 tile 变体单独按生成 MSL 做第二段缓存。
# The first-stage code fingerprint does not include dmsh_fetch.py; readable-tile variants get a separate second-stage cache keyed on the generated MSL.
CODE_FP = hashlib.sha256(source_without_rule_bodies().encode() + b''.join(b'\0' + open(m.__file__, 'rb').read() for m in (dmsh_chain,) + ((ios_metal,) if IOSOUT else ()))).hexdigest()
TOOL_FP = tool_fingerprint().encode()

_CAST = ('as_type<int>(', 'as_type<uint>(')
def int_inputs(src):
    """顶点着色器里只按整数用的输入（float 声明下每次使用都是 as_type<int/uint> 位转换，或原样拷走）→ {位置: 'uint'}。
    Maxwell 读顶点属性寄存器不做类型转换：整数格式（骨骼索引 R8UI / RG8UI / RGBA8UI 等）的位模式原样进寄存器，着色器再按整数用。
    本作没有 PC 版反射可配对，翻译器的属性类型查询缺省全答 float：Metal 把整数格式转成浮点值送进来，位转换后成了乱值——骨骼索引全错，蒙皮模型（角色）的顶点被拉成长条或飞出画面。
    Inputs that a vertex shader only uses as integers (under a float declaration every use is an as_type<int/uint> bit cast, or a plain copy) → {location: 'uint'}.
    Maxwell does no type conversion when reading vertex attribute registers: the bit pattern of integer formats (bone indices R8UI / RG8UI / RGBA8UI etc.) goes into the register as is and the shader uses it as an integer.
    This game has no PC version to pair reflection with, so the translator's attribute type queries all defaulted to float: Metal converts the integer format to a float value, and after the bit cast it is garbage - every bone index is wrong and skinned models (the characters) are stretched into streaks or thrown off screen."""
    ins = {m.group(2): int(m.group(3)) for m in re.finditer(r'(\w+)\s+(\w+)\s*\[\[attribute\((\d+)\)\]\]', src)}
    i = src.find('vertex main0_out main0(')
    if i < 0: return {}
    body = src[i:]; out = {}
    for name, loc_ in ins.items():
        uses = list(re.finditer(r'in\.%s\b' % re.escape(name), body))
        nint = 0; bad = False
        for u in uses:
            ls = body.rfind('\n', 0, u.start()) + 1; le = body.find('\n', u.end())
            m = re.match(r'\s*float\s+(_\w+)\s*=\s*in\.%s\.[xyzw];$' % re.escape(name), body[ls:le])
            if not m:
                if body[:u.start()].endswith(_CAST): nint += 1; continue
                bad = True; break
            v = m.group(1)
            for o in list(re.finditer(r'\b%s\b' % re.escape(v), body))[1:]:
                if body[:o.start()].endswith(_CAST): nint += 1; continue
                l2s = body.rfind('\n', 0, o.start()) + 1; l2e = body.find('\n', o.end())
                if re.match(r'\s*[\w.\[\]]+\s*=\s*%s;$' % re.escape(v), body[l2s:l2e]): continue   # 原样拷走：两种声明下位模式都不变 | plain copy: the bit pattern is the same under either declaration
                bad = True; break
            if bad: break
        if not bad and nint: out[str(loc_)] = 'uint'
    return out

# 顶点 / 像素配对（shader_split.py 从 BNSH 变体取出）：顶点键 → 配对的像素键 | vertex / pixel pairs (taken from BNSH variations by shader_split.py): vertex key → paired pixel keys
PAIRS = collections.defaultdict(set)
for _ln in open(GAME.table('shader_pairs.tsv')):
    if _ln.strip() and not _ln.startswith('#'): _v, _p = _ln.split(); PAIRS[_v].add(_p)

def vs_pad(key, src):
    """顶点着色器补上配对像素着色器读、它却没写的输出，值 (0,0,0,1)。
    Maxwell 的属性是无类型的 32 位槽，像素着色器读到顶点没写的位置只得到缺省值；Ryujinx 连接阶段时也是补成 (0,0,0,1)。这里逐个着色器离线翻译，不知道下一阶段读什么，
    Metal 又要求像素着色器的每个输入顶点都有输出：9043 对里有 331 对链接失败、这次绘制不画（iPhone 开场关之后一局 1 万多次「Fragment input(s) user(locnN) ... not written by vertex shader」）。
    返回 (新源码, 补上的位置)；读不到像素着色器的 MSL 的配对略过。
    Give a vertex shader the outputs its paired pixel shaders read but it does not write, with the value (0,0,0,1).
    Maxwell attributes are untyped 32-bit slots, and a pixel shader reading a location the vertex shader did not write only gets a default; Ryujinx also fills them with (0,0,0,1) when it links stages. Here every shader is translated
    offline on its own without knowing what the next stage reads, and Metal requires every pixel shader input to be a vertex output: 331 of 9043 pairs failed to link and their draws were skipped
    (over 10,000 "Fragment input(s) user(locnN) ... not written by vertex shader" in one iPhone session after the opening course). Returns (new source, padded locations); pairs whose pixel MSL cannot be read are skipped."""
    want = set()
    for ps in PAIRS.get(key, ()):
        fn = os.path.join(out, ps + '_b.metal')
        if os.path.exists(fn): want |= {int(x) for x in re.findall(r'\[\[user\(locn(\d+)\)', open(fn).read())}
    miss = sorted(want - {int(x) for x in re.findall(r'\[\[user\(locn(\d+)\)', src)})
    i = src.find('struct main0_out\n{\n'); j = src.find('\n};', i); k = src.find('main0_out out = {};')
    if not miss or i < 0 or j < 0 or k < 0: return src, []
    src = src[:j] + ''.join(f'\n    float4 dm_pad{l} [[user(locn{l})]];' for l in miss) + src[j:]
    k = src.find('main0_out out = {};') + len('main0_out out = {};')
    return src[:k] + ''.join(f'\n    out.dm_pad{l} = float4(0.0, 0.0, 0.0, 1.0);' for l in miss) + src[k:], miss

def vs_init(src):
    """顶点着色器的每个输出先置 (0,0,0,1)，再跑翻译出的主体：硬件上没写的分量就是这个缺省值。翻译器出的源码以 out = {} 开头，全是 0；
    Ryujinx 连接阶段时把下一阶段读的分量这样初始化，这里逐个着色器离线翻译，不知道下一阶段读什么，就全初始化（写了的分量照样被主体覆盖）。
    只写 xyz 的输出（世界坐标）在像素着色器里按 w 除：w 为 0 时整张阴影图的比较值成了无穷大，梦见岛户外全在阴影里（暗、篱笆不投影）。
    Every vertex shader output starts as (0,0,0,1) before the translated body runs: on the hardware that is what an unwritten component reads. The translator's source starts with out = {}, all zeros;
    Ryujinx initializes the components the next stage reads this way when it links stages, and since every shader is translated offline on its own without knowing what the next stage reads, all are
    initialized (components the body writes are overwritten as before). An output written only in xyz (a world position) is divided by its w in the pixel shader: with w = 0 every shadow-map
    compare value became infinite and Link's Awakening was in shadow everywhere outdoors (dim, no shadows from the fences)."""
    i = src.find('struct main0_out\n{\n'); j = src.find('\n};', i); k = src.find('main0_out out = {};')
    if i < 0 or j < 0 or k < 0: return src
    outs = re.findall(r'\n    float4 (\w+) \[\[user\(locn\d+\)\]\];', src[i:j])
    k += len('main0_out out = {};')
    return src[:k] + ''.join(f'\n    out.{n} = float4(0.0, 0.0, 0.0, 1.0);' for n in outs) + src[k:]

def finish(key, w, j, c1):
    name, k = loc[key]
    msl = os.path.join(w, key + '.metal'); air = msl[:-6] + '.air'; lib = os.path.join(out, key + '_b.metallib')
    r = subprocess.run(['spirv-cross', *XC, os.path.join(w, key + '.spv'), '--output', msl], capture_output=True, text=True)
    if r.returncode: return 'MSL 失败', r.stderr.strip()[:160], None
    src = open(msl).read()
    if j['stage'] == 'vs':   # 第二遍：只按整数用的输入改报 uint 重新翻译（见 int_inputs） | second pass: re-translate with inputs that are only used as integers reported as uint (see int_inputs)
        extra = {l: t for l, t in int_inputs(src).items() if l not in j['attr']}
        if extra:
            j['attr'].update(extra); jp = os.path.join(w, f'job1_{key}.json'); json.dump([j], open(jp, 'w'))
            rx = subprocess.run([XLATE, jp, w], capture_output=True, text=True)
            if rx.returncode or not os.path.exists(os.path.join(w, key + '.spv')): return '翻译失败', ('整数输入重翻：' + rx.stderr.strip())[:160], None
            r = subprocess.run(['spirv-cross', *XC, os.path.join(w, key + '.spv'), '--output', msl], capture_output=True, text=True)
            if r.returncode: return 'MSL 失败', r.stderr.strip()[:160], None
            src = open(msl).read()
    if j['stage'] == 'vs':
        src = vs_init(src); open(msl, 'w').write(src)
    pad = []
    if j['stage'] == 'vs' and PAIRS.get(key):   # 像素着色器读而顶点没写的输出补成 (0,0,0,1)（见 vs_pad） | outputs the pixel shader reads but the vertex shader does not write get (0,0,0,1) (see vs_pad)
        src, pad = vs_pad(key, src)
        if pad: open(msl, 'w').write(src)
    res = json.load(open(os.path.join(w, key + '.res.json')))
    try:
        import metal_content_cache
        metal_content_cache.compile(msl, air, lib, MAC_METAL, ['xcrun', '-sdk', 'macosx', 'metallib'])
    except subprocess.CalledProcessError as e:
        return 'metal 失败', str(e)[:160], None
    clone(msl, os.path.join(out, key + '_b.metal'))
    if IOSOUT:   # iOS：同一份 MSL 走 iOS 的唯一编译口径（dm/ios/tools/ios_metal.py）出 iphoneos metallib | iOS: the same MSL goes through iOS's single compile convention (dm/ios/tools/ios_metal.py) to produce an iphoneos metallib
        ilib = os.path.join(IOSOUT, key + '_b.metallib')
        try:
            ios_metal.compile(msl, msl[:-6] + '.ios.air', ilib + '.tmp')
            os.replace(ilib + '.tmp', ilib)
        except subprocess.CalledProcessError as e: return 'iOS metal 失败', str(e)[:160], None
    entry = re.search(r'(vertex|fragment|kernel)\s+\S+\s+(\w+)\s*\(', src)
    dr = drv_reads(src)
    refl = {'key': key + '_b', 'route': 'B', 'chain': CHAIN, 'dm_ctl': key, 'source': f'{name}#{k}', 'pc_paired': pc_of[key], 'stage': j['stage'],
            'entry': entry.group(2) if entry else 'main0', 'msl_entry_kind': entry.group(1) if entry else None,
            'threadgroup_size': j.get('local'), 'c1': c1.hex(), 'notes': res['notes'] + (['无配对 PC 反射，查询按缺省'] if j.get('pc_missing') else []), 'drv_reads': dr, 'drv_unfillable': unfillable(dr),
            'bindings': reflect(key, j['stage'], src, res),
            'vertex_inputs': [{'location': int(m.group(2)), 'msl_type': m.group(1)} for m in re.finditer(r'(\w+)\s+\w+\s*\[\[attribute\((\d+)\)\]\]', src)],
            'raster': raster_facts(j['stage'], src), 'vs_pad': pad}
    write_refl(key, refl)
    fetch_finish(key, src, refl)
    return 'ok', '', refl

keys = sorted(want) if want else sorted(loc)
NJ = int(os.environ.get('J', '8'))
os.makedirs(out, exist_ok=True)
w = tempfile.mkdtemp(prefix='dmsh_', dir=os.environ.get('WORK'))
packs, jobs, c1s = {}, {}, {}
digests, rule_fps, cache_reasons, cache_hits = {}, {}, {}, set()
for key in keys:
    name, k = loc[key]
    if name.startswith('main.rodata@'):
        if 'main' not in packs:
            sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '../../verify'))
            try: import nsoimg
            except ImportError as e: sys.exit(f'【红】解 main NSO 要 lz4（{e}）：用 $DM_ROOT/build/cache/dm/venv/bin/python 跑')
            packs['main'] = nsoimg.load(MAIN)
        rec = main_rec(packs['main'], k)
        if hashlib.sha256(rec[rec.find(bytes.fromhex('34127698')):][:0x880]).hexdigest()[:16] != key: sys.exit(f'【红】{name} 控制段哈希与映射表键 {key} 不符（MAIN={MAIN}）')
    else:
        if name not in packs: packs[name] = records(open(os.path.join(dm_dir, name), 'rb').read())
        rec = packs[name][k]
    digests[key] = shader_key(key, name, rec)
    rule_fps[key] = hashlib.sha256(shader_rule_source(name) + ','.join(sorted(PAIRS.get(key, ()))).encode()).hexdigest()   # 配对变了顶点着色器要重出（vs_pad） | the vertex shader must be rebuilt when its pairs change (vs_pad)
    hit, cache_reasons[key] = cache_lookup(key, digests[key], rule_fps[key], CODE_FP)
    if hit: cache_hits.add(key)
    else: jobs[key], c1s[key] = job_for(key, name, rec, w)
misses = [key for key in keys if key not in cache_hits]
chunks = [misses[i::NJ] for i in range(NJ)]
def xl(ch):
    jp = os.path.join(w, f'job_{abs(hash(ch[0]))}.json'); json.dump([jobs[k] for k in ch], open(jp, 'w'))
    return subprocess.run([XLATE, jp, w], capture_output=True, text=True)
with cf.ThreadPoolExecutor(NJ) as ex: xr = list(ex.map(xl, [c for c in chunks if c]))
xerr = {}
for r in xr:
    for ln in r.stderr.splitlines():
        m = re.match(r'【红】(\w+)：(.*)', ln)
        if m: xerr[m.group(1)] = m.group(2)[:160]
def fin(key):
    if key in cache_hits:
        refl = json.load(open(os.path.join(out, key + '_b.json')))
        src = open(os.path.join(out, key + '_b.metal')).read() if refl['stage'] == 'ps' else ''
        return key, 'ok', '', fetch_finish(key, src, refl)
    if key in xerr or not os.path.exists(os.path.join(w, key + '.spv')): return key, '翻译失败', xerr.get(key, '无 spv'), None
    result = (key,) + finish(key, w, jobs[key], c1s[key])
    if result[1] == 'ok': publish_cache(key, digests[key], rule_fps[key], CODE_FP)
    return result
with cf.ThreadPoolExecutor(NJ) as ex:   # 两段：配对的顶点着色器要读配对像素着色器的 MSL（vs_pad），排在最后 | two phases: paired vertex shaders read their pixel shaders' MSL (vs_pad), so they go last
    res = list(ex.map(fin, [k for k in keys if k not in PAIRS])) + list(ex.map(fin, [k for k in keys if k in PAIRS]))
shutil.rmtree(w, ignore_errors=True)
st = collections.Counter(r[1] for r in res)
print(f'着色器 {len(res)}：成功 {st["ok"]}，' + '，'.join(f'{k} {v}' for k, v in st.items() if k != 'ok'))
print(f'前置缓存：命中 {PRE_STATS["hit"]}，重出 {PRE_STATS["miss"]}')
for reason in ('新键', '规则变', '代码指纹变化：全部重出'):
    if PRE_STATS[reason]: print(f'  {reason} {PRE_STATS[reason]}')
print(f'变体缓存：生成 {BF_STATS["generated"]}，命中 {BF_STATS["hit"]}，重出 {BF_STATS["miss"]}，编译 {BF_STATS["compile"]}')
for lvl in [k for k in st if k != 'ok']:
    for e, n in collections.Counter(r[2] for r in res if r[1] == lvl).most_common(10): print(f'  [{lvl}] {n:5d}  {e}')
ok = [r[3] for r in res if r[1] == 'ok']
rd = [x for x in ok if x['drv_reads']]
print(f'运行时读驱动段的着色器 {len(rd)}（c0 {sum("0" in x["drv_reads"] for x in rd)}，c2 {sum("2" in x["drv_reads"] for x in rd)}）；读到回放层填不了的 {sum(bool(x["drv_unfillable"]) for x in ok)}')
for e, n in collections.Counter(u for x in ok for u in x['drv_unfillable']).most_common(15): print(f'  填不了 {n:5d}  {e}')
SLOTK = {'cbuf', 'samp', 'samp_tex', 'tex', 'img', 'tbuf', 'sbuf', 'ubo_ptr', 'tex_ubo', 'samp_ubo'}
noreg = [x for x in ok if any(b['kind'] in SLOTK and b.get('reg') is None for b in x['bindings'])]
unk = [x for x in ok if any(b['kind'] == '?' for b in x['bindings'])]
print(f'绑定没解出槽号的着色器 {len(noreg)}，种类认不出的 {len(unk)}（运行时加载会报红）')
for e, n in collections.Counter(f"{b['kind']} {b['msl_name'][:28]}" for x in noreg + unk for b in x['bindings'] if b['kind'] == '?' or (b['kind'] in SLOTK and b.get('reg') is None)).most_common(8): print(f'  {n:5d}  {e}')
nt = collections.Counter(nn.split('（')[0] for x in ok for nn in x['notes'])
for e, n in nt.most_common(8): print(f'  查询无 PC 作答 {n:5d}  {e}')
json.dump([{'key': r[0], 'st': r[1], 'err': r[2]} for r in res], open(os.path.join(out, '_b_build.json'), 'w'), ensure_ascii=False)

print("Metal content cache:", __import__("metal_content_cache").stats)
