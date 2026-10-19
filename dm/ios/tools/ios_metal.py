# iOS 着色器出包链的唯一编译口径：任意来源的 MSL（PC 链 / 常数补丁 / 今后 Switch 原版经 Ryujinx 翻译）→ iphoneos metallib。
# 编译参数只在这里定义一次；反射 json 的 chain.metal 记录由同一份参数生成，记录 == 实际。
# The single compile standard for the iOS shader packaging chain: MSL from any source (PC chain / constant patches / in future, the Switch original translated via Ryujinx) → iphoneos metallib.
# Compile parameters are defined only once, here; the chain.metal record in the reflection json is generated from the same parameters, record == actual.
import subprocess
# -fmetal-math-mode=relaxed：保留快速数学的重排 / 合并，但不许假设没有 NaN / Inf。翻译出的着色器靠 isnan 选择复现 Maxwell 的 NaN 语义（8337 / 12809 个用到），
# 缺省 fast 让各 GPU 的后端编译器可以把它们当成恒假；A20 Pro 上开场关卡的奇数帧主画面 NaN 72 万像素（M4 Pro 同一份 AIR 只有几十个），黑带 / 黑边光晕即由此而来
# -fmetal-math-mode=relaxed: keep fast math's reassociation / contraction, but forbid assuming there are no NaN / Inf. The translated shaders reproduce Maxwell's NaN semantics with isnan selects (8337 / 12809 use them),
# and the default fast mode lets each GPU's backend compiler treat them as always false; on the A20 Pro the opening course's odd frames had 727k NaN pixels in the main image (a few dozen with the same AIR on the M4 Pro), which became the black band / black-edged glow
METAL = ['xcrun', '-sdk', 'iphoneos', 'metal', '-c', '-mios-version-min=17.0', '-fmetal-math-mode=relaxed', '-fpreserve-invariance']
METALLIB = ['xcrun', '-sdk', 'iphoneos', 'metallib']
RECORD = ' '.join(METAL) + '; ' + ' '.join(METALLIB)                                # 写进 json chain.metal | Written into json chain.metal

def compile(msl, air, lib):
    import sys
    from pathlib import Path
    sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'gfx/tools'))
    import metal_content_cache
    metal_content_cache.compile(msl, air, lib, METAL, METALLIB)
