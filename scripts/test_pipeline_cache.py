#!/usr/bin/env python3
"""Automated and repeatable test runner for Metal pipeline cache fixtures.

Executes all 9 isolated fixture test cases with strict process exit code checks,
concurrency conservation invariants, and portable paths for the public repository.
"""
import os, sys, subprocess, tempfile, shutil, json, time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
BIN_PATH = Path("/tmp/t_pipeline_cache_pub")

def compile_fixture_binary():
    cmd = [
        "clang", "-O2", "-fobjc-arc",
        "-framework", "Foundation", "-framework", "Metal",
        "-I" + str(ROOT / "dm/gfx/nvn"),
        "-I" + str(ROOT / "dm/games/010015100B514000"),
        "-I" + str(ROOT / "artifacts/ios17-feasibility/compile/profiles/010015100B514000" if (ROOT / "artifacts").exists() else str(ROOT / "dm/games/010015100B514000")),
        "-I" + str(ROOT / "dm/host"),
        str(ROOT / "dm/gfx/tests/t_pipeline_cache.m"),
        str(ROOT / "dm/gfx/nvn/nvn_pipeline_cache.m"),
        "-o", str(BIN_PATH)
    ]
    # If game_profile.h does not exist in include paths, generate it via game.py
    profile_h = ROOT / "dm/games/010015100B514000/game_profile.h"
    need_cleanup_profile_h = False
    if not profile_h.exists():
        subprocess.run(["python3", str(ROOT / "dm/games/game.py"), "header", "010015100B514000", str(profile_h)], check=True)
        need_cleanup_profile_h = True

    try:
        r = subprocess.run(cmd, capture_output=True, text=True)
        if r.returncode != 0:
            sys.stderr.write(f"Compilation failed: {r.stderr}\n")
            sys.exit(2)
    finally:
        if need_cleanup_profile_h and profile_h.exists():
            profile_h.unlink()

def run_case(name, cache_dir, shmap, args=None, env_extra=None):
    env = os.environ.copy()
    env["DM_PIPELINE_CACHE_DIR"] = str(cache_dir)
    env["DM_NVN_SHMAP"] = str(shmap)
    if env_extra:
        env.update(env_extra)
    cmd = [str(BIN_PATH)] + (args or [])
    t0 = time.time()
    r = subprocess.run(cmd, env=env, capture_output=True, text=True)
    elapsed = time.time() - t0

    if r.returncode != 0:
        raise AssertionError(f"Case {name} subprocess exited with non-zero code {r.returncode}: {r.stderr}")

    stats = None
    for line in r.stdout.splitlines():
        if line.startswith("{") and "loaded" in line:
            stats = json.loads(line)
            break

    if stats is None:
        raise AssertionError(f"Case {name} did not emit stats JSON. stdout: {r.stdout}, stderr: {r.stderr}")

    return stats, elapsed

def main():
    compile_fixture_binary()
    tmpdir = Path(tempfile.mkdtemp(prefix="nvn_pub_cache_test_"))
    results = []
    all_ok = True

    try:
        dm_dir = tmpdir / "dm"
        dm_dir.mkdir()
        (dm_dir / "main.fixups.tsv").write_text("fixup_main_v1")
        shmap = dm_dir / "shader_map.tsv"
        shmap.write_text("shader_map_v1")
        cache_dir = tmpdir / "cache"

        # Case 1: cold
        s1, t1 = run_case("cold", cache_dir, shmap)
        if not (s1["loaded"] == 0 and s1["hits"] == 0 and s1["misses"] == 2 and
                s1["added"] == 2 and s1["saved"] == 2 and s1["bypassed"] == 0 and
                s1["write_failed"] == 0 and s1["disabled"] == 0):
            raise AssertionError(f"Case cold assertion failed: {s1}")
        results.append({"case": "cold", "pass": True, "elapsed_s": round(t1, 4), "stats": s1})

        # Case 2: reload
        s2, t2 = run_case("reload", cache_dir, shmap)
        if not (s2["loaded"] == 1 and s2["hits"] == 2 and s2["misses"] == 0 and
                s2["added"] == 0 and s2["saved"] == 0 and s2["bypassed"] == 0 and
                s2["write_failed"] == 0 and s2["disabled"] == 0):
            raise AssertionError(f"Case reload assertion failed: {s2}")
        results.append({"case": "reload", "pass": True, "elapsed_s": round(t2, 4), "stats": s2})

        # Case 3: save_failure
        s3, t3 = run_case("save_failure", cache_dir, shmap, args=["write-failure"])
        if not (s3["loaded"] == 1 and s3["hits"] == 2 and s3["misses"] == 1 and
                s3["added"] == 1 and s3["saved"] == 0 and s3["bypassed"] == 0 and
                s3["write_failed"] == 1 and s3["disabled"] == 0):
            raise AssertionError(f"Case save_failure assertion failed: {s3}")
        results.append({"case": "save_failure", "pass": True, "elapsed_s": round(t3, 4), "stats": s3})

        # Case 4: reload_after_failure
        s4, t4 = run_case("reload_after_failure", cache_dir, shmap)
        if not (s4["loaded"] == 1 and s4["hits"] == 2 and s4["misses"] == 0 and
                s4["added"] == 0 and s4["saved"] == 0 and s4["bypassed"] == 0 and
                s4["write_failed"] == 0 and s4["disabled"] == 0):
            raise AssertionError(f"Case reload_after_failure assertion failed: {s4}")
        results.append({"case": "reload_after_failure", "pass": True, "elapsed_s": round(t4, 4), "stats": s4})

        # Case 5: corrupt_recovery
        for p in cache_dir.rglob("*.metalarc"):
            p.write_bytes(b"corrupted_binary_archive_data")
        s5, t5 = run_case("corrupt_recovery", cache_dir, shmap)
        if not (s5["loaded"] == 0 and s5["hits"] == 0 and s5["misses"] == 2 and
                s5["added"] == 2 and s5["saved"] == 2 and s5["bypassed"] == 0 and
                s5["write_failed"] == 0 and s5["disabled"] == 0):
            raise AssertionError(f"Case corrupt_recovery assertion failed: {s5}")
        results.append({"case": "corrupt_recovery", "pass": True, "elapsed_s": round(t5, 4), "stats": s5})

        # Case 6: parallel (Concurrency Conservation Laws)
        s6, t6 = run_case("parallel", cache_dir, shmap, args=["parallel"])
        concurrency_ok = (
            s6["loaded"] == 1 and
            s6["hits"] + s6["misses"] == 18 and
            s6["hits"] >= 2 and
            s6["misses"] >= 1 and
            s6["added"] == s6["misses"] and
            s6["saved"] == s6["added"] and
            s6["bypassed"] == 0 and
            s6["write_failed"] == 0 and
            s6["disabled"] == 0
        )
        if not concurrency_ok:
            raise AssertionError(f"Case parallel concurrency conservation failed: {s6}")
        results.append({"case": "parallel", "pass": True, "elapsed_s": round(t6, 4), "stats": s6,
                        "conservation": "hits + misses == 18, added == misses, saved == added"})

        # Case 7: identity_change
        shmap.write_text("shader_map_v2_updated")
        s7, t7 = run_case("identity_change", cache_dir, shmap)
        if not (s7["loaded"] == 0 and s7["hits"] == 0 and s7["misses"] == 2 and
                s7["added"] == 2 and s7["saved"] == 2 and s7["bypassed"] == 0 and
                s7["write_failed"] == 0 and s7["disabled"] == 0):
            raise AssertionError(f"Case identity_change assertion failed: {s7}")
        results.append({"case": "identity_change", "pass": True, "elapsed_s": round(t7, 4), "stats": s7})

        # Case 8: disabled
        s8, t8 = run_case("disabled", cache_dir, shmap, env_extra={"DM_PIPELINE_CACHE": "off"})
        if not (s8["loaded"] == 0 and s8["hits"] == 0 and s8["misses"] == 0 and
                s8["added"] == 0 and s8["saved"] == 0 and s8["bypassed"] == 2 and
                s8["write_failed"] == 0 and s8["disabled"] == 1):
            raise AssertionError(f"Case disabled assertion failed: {s8}")
        results.append({"case": "disabled", "pass": True, "elapsed_s": round(t8, 4), "stats": s8})

        # Case 9: directory_failure
        blocked = tmpdir / "regular_file_blocking_dir"
        blocked.write_text("blocking file")
        s9, t9 = run_case("directory_failure", blocked / "sub", shmap)
        if not (s9["loaded"] == 0 and s9["hits"] == 0 and s9["misses"] == 0 and
                s9["added"] == 0 and s9["saved"] == 0 and s9["bypassed"] == 2 and
                s9["write_failed"] == 1 and s9["disabled"] == 1):
            raise AssertionError(f"Case directory_failure assertion failed: {s9}")
        results.append({"case": "directory_failure", "pass": True, "elapsed_s": round(t9, 4), "stats": s9})

    except Exception as e:
        sys.stderr.write(f"TEST RUNNER ERROR: {e}\n")
        all_ok = False
        sys.exit(1)
    finally:
        shutil.rmtree(tmpdir, ignore_errors=True)
        if BIN_PATH.exists():
            BIN_PATH.unlink()

    print(f"ALL {len(results)} PIPELINE CACHE FIXTURE CASES PASSED STRICT ASSERTIONS!")

if __name__ == "__main__":
    main()
