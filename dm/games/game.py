#!/usr/bin/env python3
# Game profiles: dm/games/<base game title ID>/game.tsv (key <TAB> values..., lines starting with # are comments) + the shader tables and dmsh_chain.h in the same folder. The shader tools, the host build, iOS packaging and the NSP script take each game's constants from here.
# Usage: game.py list (list all profiles); game.py <id> <key> (print that key's value, for shell); game.py header <id> <out.h> (generate the host's game_profile.h)
#   From Python: import game; g = game.load() (takes DM_GAME; there is no default game: unset is an error that lists the profiles); game.by_title(title ID); g.get / g.words / g.int / g.builds() / g.table(file name)
import os, re, sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
STAGES = {'vs': 0, 'ps': 1, 'gs': 2, 'hs': 3, 'ds': 4, 'cs': 5}   # NVN shader stage numbers


class Game:
    def __init__(self, d):
        self.dir = Path(d).resolve(); self.id = self.dir.name; self.rows = []
        for line in (self.dir / 'game.tsv').read_text(encoding='utf-8').splitlines():
            if not line.strip() or line.lstrip().startswith('#'): continue
            c = line.split('\t'); self.rows.append((c[0].strip(), [v.strip() for v in c[1:]]))

    def values(self, key):   # every row of this key (keys such as build repeat)
        return [v for k, v in self.rows if k == key]

    def get(self, key, default=None):
        r = self.values(key)
        if r: return '\t'.join(r[0])
        if default is None: raise KeyError(f'{self.dir / "game.tsv"} 没有键 {key} | has no key {key}')
        return default

    def words(self, key, default=None): return self.get(key, default).split()
    def int(self, key): return int(self.get(key), 0)
    def table(self, name): return self.dir / name

    @property
    def title_id(self): return int(self.get('title_id'), 16)

    def builds(self):
        """{version: {'display': display version, module name: build ID, ...}}"""
        out = {}
        for ver, disp, *mods in self.values('build'):
            out[ver] = dict([('display', disp)] + [tuple(m.split('=', 1)) for m in mods])
        return out

    def pairs(self, key):   # "a=b c=d" → [(a, b), (c, d)]
        return [tuple(w.split('=', 1)) for w in self.words(key)]


def load(name=None):
    name = name or os.environ.get('DM_GAME')
    if not name:   # there is no default game
        have = ', '.join(f'{g.id} ({g.get("name", "")})' for g in all_games())
        raise SystemExit(f'【红】没设 DM_GAME：用基础版标题号选游戏档案：{have} | DM_GAME is not set: pick a game profile by base game title ID: {have}')
    d = Path(name) if os.sep in str(name) else HERE / name
    if not (d / 'game.tsv').exists():   # profile folders are named after the base game's title ID (the old names smbw / fe_engage are gone)
        have = ', '.join(f'{g.id} ({g.get("name", "")})' for g in all_games())
        raise SystemExit(f'【红】没有游戏档案 {d / "game.tsv"}（DM_GAME / GAME 用基础版标题号：{have}）| no game profile {d / "game.tsv"} (DM_GAME / GAME take the base game title ID: {have})')
    return Game(d)


def all_games():
    return [Game(d) for d in sorted(HERE.iterdir()) if (d / 'game.tsv').exists()]


def by_title(tid):
    return next((g for g in all_games() if g.title_id == tid), None)


def header(g):
    """the host's game_profile.h: the profile constants the host uses, as macros"""
    q = lambda s: '"' + s.replace('\\', '\\\\').replace('"', '\\"') + '"'
    mods = g.words('modules')
    ssbo = dict(g.pairs('nvn_ssbo_bases'))
    sb = ' : '.join(f'(stage) == {STAGES[k]} ? {v}' for k, v in ssbo.items()) + ' : -1'
    vers = ', '.join('{' + q(b['main']) + ', ' + q(b['display']) + '}' for b in g.builds().values() if 'main' in b)
    pi = g.get('present_interval', 'game')   # present interval: game = as the game sets it (as on the Switch), display = one frame per display tick
    if pi not in ('game', 'display'): sys.exit(f'{g.id}: present_interval 只能是 game / display | present_interval must be game or display: {pi}')
    cp = g.get('core_preempt', 'off')   # same-core preemption approximation (hle_thread.c): on / off
    if cp not in ('on', 'off'): sys.exit(f'{g.id}: core_preempt 只能是 on / off | core_preempt must be on or off: {cp}')
    sf = g.get('shared_font', 'bfttf')   # what the shared-font address points at (hle_sdk16.c): bfttf = 8-byte header + TTF, ttf = the TTF alone
    if sf not in ('bfttf', 'ttf'): sys.exit(f'{g.id}: shared_font 只能是 bfttf / ttf | shared_font must be bfttf or ttf: {sf}')
    pl = g.get('pad_layout', 'simple')   # the virtual gamepad's first layout (DmGamepad.m; afterwards whatever the player switched to in game is kept): simple = 2D, full = 3D (D-pad, right stick, L3 / R3)
    if pl not in ('simple', 'full'): sys.exit(f'{g.id}: pad_layout 只能是 simple / full | pad_layout must be simple or full: {pl}')
    fbs = g.words('feedback_snap', '')   # fragment shader key prefixes whose same-pass feedback sampling gets a snapshot first (nvn_mtl.m fb_prepare); none by default
    if any(not re.fullmatch(r'[0-9a-f]{8,16}', k) for k in fbs): sys.exit(f'{g.id}: feedback_snap 要写片元着色器键（8–16 位小写十六进制）| feedback_snap takes fragment shader keys (8-16 lowercase hex digits): {fbs}')
    compat_fbs = g.words('compat_feedback_snap', '')
    if any(not re.fullmatch(r'[0-9a-f]{8,16}', k) for k in compat_fbs):
        sys.exit(f'{g.id}: invalid compat_feedback_snap shader prefix')
    afr = g.words('alpha_from_red', '')   # fragment shader key prefixes that read single-channel textures mapped (R, 0, 0, 1) with alpha = red (nvn_mtl.m tex_alpha_red); none by default
    if any(not re.fullmatch(r'[0-9a-f]{8,16}', k) for k in afr): sys.exit(f'{g.id}: alpha_from_red 要写片元着色器键（8–16 位小写十六进制）| alpha_from_red takes fragment shader keys (8-16 lowercase hex digits): {afr}')
    api = g.get('device_api', '55.15')   # the NVN API major.minor version nvnDeviceGetInteger reports (hle_nvn.c)
    if not re.fullmatch(r'\d+\.\d+', api): sys.exit(f'{g.id}: device_api 要写成 主.次 | device_api must be major.minor: {api}')
    L = [f'// Generated by dm/games/game.py from dm/games/{g.id}/game.tsv; do not edit',
         '#pragma once',
         f'#define DM_GAME_ID {q(g.id)}',
         f'#define DM_GAME_NAME {q(g.get("name"))}',
         f'#define DM_GAME_PROGRAM_ID 0x{int(g.get("program_id"), 16):016X}ull',
         f'#define DM_GAME_MODULES {{{", ".join(map(q, mods))}}}',
         f'#define DM_GAME_NMOD {len(mods)}',
         f'#define DM_GAME_ROMFS_MARKER {q(g.get("romfs_marker"))}',
         f'#define DM_GAME_MEM_RESERVE {g.int("mem_reserve"):#x}ull',
         f'#define DM_GAME_MEM_ALIAS {g.int("mem_alias"):#x}ull',
         f'#define DM_GAME_MEM_STACK {g.int("mem_stack"):#x}ull',
         f'#define DM_GAME_APP_POOL {g.int("app_pool"):#x}ull',
         f'#define DM_GAME_NVN_SSBO_BASE(stage) ({sb})',
         f'#define DM_GAME_NVN_TEX_BASE {g.int("nvn_tex_base"):#x}',
         f'#define DM_GAME_NVN_TEX_SLOTS {g.int("nvn_tex_slots")}',
         f'#define DM_GAME_NVN_SAMP_BASE {g.int("nvn_samp_base"):#x}',
         f'#define DM_GAME_NVN_IMG_BASE {g.int("nvn_img_base"):#x}',
         f'#define DM_GAME_NVN_IMG_SLOTS {g.int("nvn_img_slots")}',
         f'#define DM_GAME_DISPLAY_VERSIONS {vers}',
         f'#define DM_GAME_PRESENT_DISPLAY {int(pi == "display")}',
         f'#define DM_GAME_CORE_PREEMPT {int(cp == "on")}',
         f'#define DM_GAME_SHARED_FONT_TTF {int(sf == "ttf")}',
         f'#define DM_GAME_PAD_FULL {int(pl == "full")}',
         f'#define DM_GAME_FEEDBACK_SNAP {q(" ".join(fbs))}',
        f'#define DM_GAME_COMPAT_FEEDBACK_SNAP {q(" ".join(compat_fbs))}',
         f'#define DM_GAME_ALPHA_FROM_RED {q(" ".join(afr))}',
         f'#define DM_GAME_NVN_API_MAJOR {api.split(".")[0]}',
         f'#define DM_GAME_NVN_API_MINOR {api.split(".")[1]}',
         '']
    return '\n'.join(L)


if __name__ == '__main__':
    a = sys.argv[1:]
    if a == ['list']:
        for g in all_games(): print(f'{g.id}\t{g.title_id:016X}\t{g.get("name", "")}')
    elif len(a) == 3 and a[0] == 'header':
        out = Path(a[2]); out.parent.mkdir(parents=True, exist_ok=True)
        tmp = out.with_name(out.name + '.tmp'); tmp.write_text(header(load(a[1]))); tmp.replace(out)
    elif len(a) == 2:
        print(load(a[0]).get(a[1]))
    else:
        sys.exit(__doc__ or '用法 | usage: game.py list | game.py <id> <key> | game.py header <id> <out.h>')
