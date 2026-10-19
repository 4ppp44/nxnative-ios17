// nn::fs: on the real device it goes through the fsp-srv service; the host connects directly to the Mac file system. Mount name → host directory:
//   rom   → $DM_ROMFS (default $DM_ROOT/data/switch/3.3.94012/Update/RomFS, read-only; the game parses the storage blocks in it itself)
//   save  → $DM_SAVE (must be set, pointing to this run's copy of the standard save save_ref; if unset, report a failure and abort)
//   temp  → $DM_TEMP (default $DM_ROOT/run/platform/temp)
// Paths look like "rom:/data/x". FileHandle / DirectoryHandle are 8 bytes passed by value, here they store the host fd / DIR*.
// Struct layout follows the public Horizon ABI: DirectoryEntry = {char name[0x301], pad[3], s8 type, pad[3], s64 size} (0x310 bytes).
#include "hle.h"
#include "front.h"
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>
#include <stdio.h>
#include <stdatomic.h>
#include <sys/clonefile.h>
#include <sys/xattr.h>

// Every take-over in this file runs on the big host stack (hle_bigstack.c): path buffers are sized by PATH_MAX and one file open takes 6-7 KB of stack, while a game's save thread can have as little as 8 KB (Super Mario 3D World + Bowser's Fury)
#undef HLE_FORCE
#define HLE_FORCE HLE_FORCE_BIG

#define RES_PATH_NOT_FOUND 0x202u      // fs module 2, description 1
#define RES_PATH_EXISTS    0x402u      // fs module 2, description 2
enum { MODE_READ = 1, MODE_WRITE = 2, MODE_APPEND = 4 };
enum { ENT_DIR = 0, ENT_FILE = 1 };
enum { DIRMODE_DIR = 1, DIRMODE_FILE = 2 };

typedef struct { char name[0x301]; uint8_t pad0[3]; int8_t type; uint8_t pad1[3]; int64_t size; } DirectoryEntry;
_Static_assert(sizeof(DirectoryEntry) == 0x310, "DirectoryEntry 布局");

#define MAX_MOUNT 16
// Save transactions (HLE audit items 1–3): on the real device a save can be rolled back as a whole before commit, and after a crash / kill a remount sees only the version from the last Commit.
// Host: at mount, the committed directory commit (= $DM_SAVE) is clonefile'd as a whole tree into the working directory <commit>.work (APFS copy-on-write, nearly zero cost), and the mount points at the working directory,
// all game reads and writes happen in the working directory; Commit = clonefile(work → <commit>.new), then renamex_np(RENAME_SWAP) swaps it atomically with commit, then the swapped-out old version is deleted.
// Killed at any moment, commit is either the old version or the new version, never half-written / a mix of old and new; the next mount discards leftover .work / .new.
typedef struct { char name[32]; char dir[1024]; char overlay[4096]; char commit[1024]; int ro; } mount_t;
static mount_t g_mnt[MAX_MOUNT];   // commit non-empty = transactional save mount
static int g_nmnt;
static pthread_mutex_t g_lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_mutex_t g_path_lock = PTHREAD_MUTEX_INITIALIZER;
static void path_unlock(pthread_mutex_t **m) { pthread_mutex_unlock(*m); }
#define PATH_LOCK() pthread_mutex_t *path_guard __attribute__((cleanup(path_unlock))) = &g_path_lock; pthread_mutex_lock(path_guard)
static uint8_t g_fmode[65536];              // fd → open mode
static uint8_t g_fsave[65536];              // fd → whether it is on a transactional save mount (the save write injection point only counts these)
static _Atomic int g_save_writes;           // number of writes on the save mount (shared by the injection point and the commit log)
static _Atomic uint64_t g_txn_first_ns;     // time of this transaction's first save write (used by the commit log to report timing; cleared to 0 at commit)
// Write failures are refused per transaction: on the real device save space is reserved when the save is created, overwrites cannot fail, and the game does not check the return values of WriteFile / SetFileSize either, it Commits as usual after a failure
// (after injecting a failure on the 1st write, the committed joe.d2s is 0 bytes = character lost). When a host write fails (disk full etc., really possible on iOS):
// if any save write / set-size failed between the last Commit and this Commit, this Commit is refused -- the committed version is unchanged, the working directory is discarded and re-cloned from the committed version,
// and the front end is notified (front_save_failed); the next transaction (the game's next full save rewrite) is attempted as usual and committed if it succeeds. g_save_poison = errno of the first failure in this transaction (0 = none).
static _Atomic int g_save_poison;
static void save_poison(int e) { int z = 0; atomic_compare_exchange_strong(&g_save_poison, &z, e ? e : EIO); }
void dm_fs_save_poison(int e) { save_poison(e); }   // for the pre-commit hook: a side file (Chronicle / pouch) that failed to write also counts as a write failure of this transaction -- if the commit went ahead as usual, the items would no longer be in the character save and would not be in the side file either
// The default weak implementation only logs (Mac); the iOS front end provides a strong implementation of the same name that shows a native alert. Called on the game thread, the front end switches to the main thread itself
__attribute__((weak)) void front_save_failed(int err) { LOG("front_save_failed(errno=%d)：前端未接（缺省弱实现）", err); }
// DM_FSLOG=<file>: each ReadFile logs one TSV line "seconds since boot\tguest path\toffset\tlength\tguest buffer address" (which bytes boot read, for offline reverse lookup against the manifest)
static FILE *g_fslog; static char *g_fdpath[4096]; static pthread_mutex_t g_fslog_lock = PTHREAD_MUTEX_INITIALIZER;
static void fslog_init(void) { static int done; if (done) return; done = 1; const char *e = getenv("DM_FSLOG"); if (e && !(g_fslog = fopen(e, "w"))) die("DM_FSLOG 打不开 %s", e); }

static const char *envdir(const char *var, const char *rel, char *buf, size_t n) {
    const char *v = getenv(var);
    if (v) return v;
    snprintf(buf, n, "%s%s/%s", getenv("DM_ROOT") ?: getenv("HOME"), getenv("DM_ROOT") ? "" : "/dm-work", rel); return buf;
}

// Steps that end in a failed write (from d2r-mobile b94670c79): test injection DM_TEST_FS_FAILAT=<point>[:<count>][,...] -- in a save transaction, mountclone (clone the work directory at mount),
// reclone (reclone after a refused commit), guestname (write the guest name after a rename), renameback (rename rollback) fail with ENOSPC for the first <count> times (default 1),
// to check "no exit, committed version unchanged, next commit works" (tests/t_fs.c 6). Without the variable it costs one getenv
static int dm_fs_test_fail(const char *pt) {
    static char spec[256]; static int cnt[8]; const char *e = getenv("DM_TEST_FS_FAILAT"); if (!e || !e[0]) return 0;
    if (strcmp(spec, e)) { strlcpy(spec, e, sizeof spec); memset(cnt, 0, sizeof cnt); }   // a new set of injections starts counting from zero
    size_t L = strlen(pt); int k = 0;
    for (const char *q = spec; *q && k < 8; k++) { const char *end = strchr(q, ','); size_t n = end ? (size_t)(end - q) : strlen(q);
        if (n >= L && !strncmp(q, pt, L) && (n == L || q[L] == ':')) { int lim = n > L ? atoi(q + L + 1) : 1; if (cnt[k] < lim) { cnt[k]++; errno = ENOSPC; LOG("DM_TEST_FS_FAILAT：%s 第 %d 次按 ENOSPC 失败", pt, cnt[k]); return 1; } return 0; }
        q = end ? end + 1 : q + n; }
    return 0;
}
static int in_txn_dir(const char *hp) { for (int i = 0; i < g_nmnt; i++) { size_t n = strlen(g_mnt[i].dir); if (g_mnt[i].commit[0] && !strncmp(hp, g_mnt[i].dir, n) && (hp[n] == '/' || !hp[n])) return 1; } return 0; }
static int rm_tree(const char *p);
static Result mount_ex(const char *name, const char *dir, int ro, int txn) {
    PATH_LOCK(); pthread_mutex_lock(&g_lock);
    for (int i = 0; i < g_nmnt; i++)
        if (!strcmp(g_mnt[i].name, name)) { pthread_mutex_unlock(&g_lock); return RES_OK; }
    if (g_nmnt >= MAX_MOUNT) die("挂载表满");
    strlcpy(g_mnt[g_nmnt].name, name, sizeof g_mnt[0].name);
    g_mnt[g_nmnt].ro = ro; g_mnt[g_nmnt].overlay[0] = 0; g_mnt[g_nmnt].commit[0] = 0;
    if (getenv("DM_ROMFS_OVERLAY") && (!strcmp(name, "rom") ||
        (ro && !txn && getenv("DM_ROMFS") && !strcmp(dir,getenv("DM_ROMFS")))))
        strlcpy(g_mnt[g_nmnt].overlay, getenv("DM_ROMFS_OVERLAY"), sizeof g_mnt[0].overlay);
    // The transaction directory cannot be set up (leftovers cannot be cleared / clone failed, which really happens on a full disk): do not exit; mount the committed directory read-only -- saves still read, every write fails, commits are no-ops, the committed version is untouched, and the front end is told
    // (each of these three failures used to call die: with the phone's storage full the game exited as soon as it mounted its saves)
    int txn_err = 0;
    if (txn) {
        char work[1100], neu[1100]; snprintf(work, sizeof work, "%s.work", dir); snprintf(neu, sizeof neu, "%s.new", dir);
        mkdir(dir, 0755);
        const char *why = NULL;
        if (!access(work, F_OK) && rm_tree(work)) why = "清不掉上次残留的工作目录";
        else if (!access(neu, F_OK) && rm_tree(neu)) why = "清不掉上次残留的 .new";
        else if (dm_fs_test_fail("mountclone") || clonefile(dir, work, 0)) why = "克隆工作目录失败";
        if (why) { txn_err = errno ? errno : EIO; g_mnt[g_nmnt].ro = 1; strlcpy(g_mnt[g_nmnt].dir, dir, sizeof g_mnt[0].dir);
            LOG("【红】存档事务：%s（%s，errno=%d）——改为只读挂载已提交目录 %s：本局存档写不进去，已提交版本不变", why, work, txn_err, dir); }
        else {
            strlcpy(g_mnt[g_nmnt].commit, dir, sizeof g_mnt[0].commit);
            atomic_store(&g_save_poison, 0);                                // the working directory was just cloned from the committed version, intact
            strlcpy(g_mnt[g_nmnt].dir, work, sizeof g_mnt[0].dir); }
    } else strlcpy(g_mnt[g_nmnt].dir, dir, sizeof g_mnt[0].dir);
    g_nmnt++;
    pthread_mutex_unlock(&g_lock);
    if (txn_err) front_save_failed(txn_err);
    if (!ro && !txn) mkdir(dir, 0755);
    LOG("fs 挂载 %s: → %s%s%s", name, txn ? g_mnt[g_nmnt - 1].dir : dir, ro || txn_err ? "（只读）" : txn ? "（事务式存档：工作目录，Commit 原子换入）" : "", g_mnt[g_nmnt - 1].overlay[0] ? "（overlay 优先）" : "");
    return RES_OK;
}
static Result mount(const char *name, const char *dir, int ro) { return mount_ex(name, dir, ro, 0); }

// APFS is case-insensitive by default, Horizon paths are case-sensitive: every component is looked up exactly by guest name.
// Ordinary host names are unchanged; only when a name collides on the host is a separate physical name chosen, with the guest name stored in an xattr.
// clonefile preserves xattr, so save Commit/remount needs no separate mapping table; enumeration must not leak physical aliases.
#define FS_GUEST_NAME "org.d2rmobile.guest-name"
static int guest_name(const char *parent, const char *physical, char *out, size_t n) {
    // Only the physical names chosen on a case collision (.dm-case-N) carry the xattr (set_guest_name writes it only when the physical name differs from the guest name); any other physical name is the guest name,
    // so no per-entry getxattr is needed -- that was one system call per entry when listing, seconds for the 216,000 entries Engage walks in RomFS at boot
    if (strncmp(physical, ".dm-case-", 9)) { strlcpy(out, physical, n); return 1; }
    char p[1280]; snprintf(p, sizeof p, "%s/%s", parent, physical);
    ssize_t k = getxattr(p, FS_GUEST_NAME, out, n - 1, 0, XATTR_NOFOLLOW);
    if (k >= 0) { out[k] = 0; return 1; }
    if (errno != ENOATTR) return 0;
    strlcpy(out, physical, n); return 1;
}
// Name index of the directories of read-only mounts (RomFS, a save that fell back to read-only): guest name → physical name, sorted by guest name. The mount table is resident and a read-only mount does not change for the whole process,
// so each directory's index is built once at its first lookup and stays valid. The entry-by-entry comparison below calls getxattr on every entry of the parent directory for each path component:
// Engage's voice bank directories have 38,000 entries, and walking the whole RomFS at boot (9,680 directories) took about 17 s of black screen on the Mac and longer on the phone;
// in play every audio file Wwise opened also took tens of milliseconds, all while holding the global path lock. Callers all hold PATH_LOCK (like host_path_ex), so the index takes no lock of its own.
typedef struct { const char *guest, *phys; } name_ent;
typedef struct dir_index { struct dir_index *next; uint64_t hash; char *path; size_t n; name_ent *e; char *pool; } dir_index;
#define DIR_INDEX_SLOTS 8192
static dir_index *g_dir_index[DIR_INDEX_SLOTS];
static uint64_t fnv1a(const char *s) { uint64_t h = 1469598103934665603ull; while (*s) { h ^= (uint8_t)*s++; h *= 1099511628211ull; } return h; }
static int name_ent_cmp(const void *a, const void *b) { return strcmp(((const name_ent *)a)->guest, ((const name_ent *)b)->guest); }
// Returns NULL when it cannot be built (the directory cannot be opened, reading an entry's xattr fails); the caller then takes the original path
static const dir_index *dir_index_get(const char *dir) {
    uint64_t h = fnv1a(dir); dir_index **slot = &g_dir_index[h % DIR_INDEX_SLOTS];
    for (dir_index *x = *slot; x; x = x->next) if (x->hash == h && !strcmp(x->path, dir)) return x;
    DIR *d = opendir(dir); if (!d) return NULL;
    // First gather the names into one pool (a physical name is stored separately only when it differs from the guest name), with offsets in off[]; they become pointers once the pool stops growing
    size_t n = 0, cap = 64, plen = 0, pcap = 4096; size_t (*off)[2] = malloc(cap * sizeof *off); char *pool = malloc(pcap);
    if (!off || !pool) die("目录索引分配失败");
    struct dirent *e; char guest[0x301]; int ok = 1;
    while ((e = readdir(d))) {
        if (!strcmp(e->d_name, ".") || !strcmp(e->d_name, "..")) continue;
        if (!guest_name(dir, e->d_name, guest, sizeof guest)) { ok = 0; break; }
        size_t gl = strlen(guest) + 1, same = !strcmp(guest, e->d_name), pl = same ? 0 : strlen(e->d_name) + 1;
        if (n == cap && !(off = realloc(off, (cap *= 2) * sizeof *off))) die("目录索引分配失败");
        while (plen + gl + pl > pcap) if (!(pool = realloc(pool, pcap *= 2))) die("目录索引分配失败");
        off[n][0] = plen; memcpy(pool + plen, guest, gl); plen += gl;
        off[n][1] = same ? off[n][0] : plen; if (!same) { memcpy(pool + plen, e->d_name, pl); plen += pl; }
        n++;
    }
    closedir(d);
    if (!ok) { free(off); free(pool); return NULL; }
    dir_index *x = calloc(1, sizeof *x); if (!x || !(x->path = strdup(dir)) || !(x->e = malloc((n ? n : 1) * sizeof *x->e))) die("目录索引分配失败");
    for (size_t i = 0; i < n; i++) { x->e[i].guest = pool + off[i][0]; x->e[i].phys = pool + off[i][1]; }
    free(off); qsort(x->e, n, sizeof *x->e, name_ent_cmp);
    x->hash = h; x->n = n; x->pool = pool; x->next = *slot; *slot = x;
    return x;
}
static int path_component(char *parent, size_t n, const char *name, int create, int ro) {
    if (ro && !create) {
        const dir_index *x = dir_index_get(parent);
        if (x) {
            name_ent key = {name, NULL}; const name_ent *hit = bsearch(&key, x->e, x->n, sizeof *x->e, name_ent_cmp);
            if (!hit) { errno = ENOENT; return 0; }
            size_t len = strlen(parent), k = strlen(hit->phys);
            if (len + k + 2 > n) { errno = ENAMETOOLONG; return 0; }
            parent[len] = '/'; memcpy(parent + len + 1, hit->phys, k + 1); return 1;
        }
    }
    DIR *d = opendir(parent); if (!d) return 0;
    struct dirent *e; char physical[0x301] = "", guest[0x301];
    while ((e = readdir(d))) {
        if (!strcmp(e->d_name, ".") || !strcmp(e->d_name, "..")) continue;
        if (!guest_name(parent, e->d_name, guest, sizeof guest)) { closedir(d); return 0; }
        if (!strcmp(guest, name)) { strlcpy(physical, e->d_name, sizeof physical); break; }
    }
    closedir(d);
    if (!physical[0]) {
        if (!create) { errno = ENOENT; return 0; }
        strlcpy(physical, name, sizeof physical);
        char p[1280]; struct stat st;
        snprintf(p, sizeof p, "%s/%s", parent, physical);
        if (!lstat(p, &st)) { // the exact guest name does not exist, but APFS matched the physical name to another entry
            unsigned i = 0;
            do { snprintf(physical, sizeof physical, ".dm-case-%u", ++i);
                 snprintf(p, sizeof p, "%s/%s", parent, physical); } while (!lstat(p, &st));
        }
        if (errno != ENOENT) return 0;
    }
    size_t len = strlen(parent), k = strlen(physical);
    if (len + k + 2 > n) { errno = ENAMETOOLONG; return 0; }
    parent[len] = '/'; memcpy(parent + len + 1, physical, k + 1); return 1;
}
static int root_path(const char *root, const char *rest, char *out, size_t n) {
    strlcpy(out, root, n);
    while (*rest) {
        while (*rest == '/') rest++;
        if (!*rest) break;
        const char *end = strchr(rest, '/'); if (!end) end = rest + strlen(rest);
        size_t k = end - rest; char part[0x301];
        if (k >= sizeof part) { errno = ENAMETOOLONG; return 0; }
        memcpy(part, rest, k); part[k] = 0;
        if (!strcmp(part, "..")) { errno = ENOENT; return 0; }
        if (strcmp(part, ".") && !path_component(out, n, part, 0, 1)) return 0;   // overlay roots are all RomFS, read-only
        rest = end;
    }
    return 1;
}
// Files in the overlay that the host itself reads (marker files, sidecar tables, data archives) are all looked up here. DM_ROMFS_OVERLAY may have
// several layers, colon-separated, earlier ones taking priority; old devices have two layers,
// "in-bundle romfs_overlay_astc:Legacy Device Pack directory"; treating the whole string as one directory when building file names finds nothing at all
// on old devices.
int dm_overlay_file(const char *rel, char *out, size_t n) {
    const char *ov = getenv("DM_ROMFS_OVERLAY");
    for (const char *p = ov ? ov : ""; *p;) {
        size_t l = strcspn(p, ":");
        if (l && snprintf(out, n, "%.*s/%s", (int)l, p, rel) < (int)n && !access(out, R_OK)) return 1;
        p += l; if (*p == ':') p++;
    }
    if (n) out[0] = 0;
    return 0;
}
static int rom_overlay_path(const mount_t *m, const char *rest, char *out, size_t n) {
    char *roots = strdup(m->overlay);
    if (!roots) die("rom overlay 路径分配失败");
    char *save = NULL;
    for (char *root = strtok_r(roots, ":", &save); root; root = strtok_r(NULL, ":", &save)) {
        char candidate[1024];
        if (root_path(root, rest, candidate, sizeof candidate) && !access(candidate, F_OK)) {
            strlcpy(out, candidate, n); free(roots); return 1;
        }
    }
    int found = root_path(m->dir, rest, out, n) && !access(out, F_OK);
    free(roots);
    if (found) return 1;
    errno = ENOENT; return 0;
}
// The path after the mount name is normalized lexically as Horizon's PathNormalizer does: "." is dropped, ".." goes up one level, and going above the root is an error (ResultDirectoryUnobtainable on hardware, reported here as not found).
// Metroid Dread's stream sound paths are "rom:/system/snd/../../sounds/streams/...": ".." used to be reported as not found, and Atk's stream load task got an unexpected error code and aborted (main+0x1225a8c)
static int norm_rest(const char *rest, char *out, size_t n) {
    size_t len = 0; out[0] = 0;
    while (*rest) {
        while (*rest == '/') rest++;
        if (!*rest) break;
        const char *end = strchr(rest, '/'); if (!end) end = rest + strlen(rest);
        size_t k = end - rest;
        if (k == 2 && rest[0] == '.' && rest[1] == '.') {
            if (!len) { errno = ENOENT; return 0; }
            while (len && out[len - 1] != '/') len--;
            if (len) len--;
            out[len] = 0;
        } else if (!(k == 1 && rest[0] == '.')) {
            if (len + 1 + k + 1 > n) { errno = ENAMETOOLONG; return 0; }
            out[len++] = '/'; memcpy(out + len, rest, k); len += k; out[len] = 0;
        }
        rest = end;
    }
    return 1;
}
// create only allows the last component to not exist yet; intermediate directories still need an exact match.
static int host_path_ex(const char *p, char *out, size_t n, int *ro, int create) {
    const char *c = strchr(p, ':');
    if (!c) { errno = ENOENT; return 0; }
    size_t ln = c - p;
    for (int i = 0; i < g_nmnt; i++) {
        if (strlen(g_mnt[i].name) != ln || strncmp(g_mnt[i].name, p, ln)) continue;
        if (ro) *ro = g_mnt[i].ro;
        char normed[1024]; const char *rest = c + 1;
        if (strstr(rest, "/.")) { if (!norm_rest(rest, normed, sizeof normed)) return 0; rest = normed; }   // only paths with "." components are normalized; the rest walk component by component as before
        if (g_mnt[i].overlay[0] && !create) return rom_overlay_path(&g_mnt[i], rest, out, n);
        strlcpy(out, g_mnt[i].dir, n);
        while (*rest) {
            while (*rest == '/') rest++;
            if (!*rest) break;
            const char *end = strchr(rest, '/'); if (!end) end = rest + strlen(rest);
            size_t k = end - rest; char part[0x301];
            if (k >= sizeof part) { errno = ENAMETOOLONG; return 0; }
            memcpy(part, rest, k); part[k] = 0;
            if (!strcmp(part, "..")) { errno = ENOENT; return 0; }
            const char *next = end; while (*next == '/') next++;
            if (strcmp(part, ".") && !path_component(out, n, part, create && !*next, g_mnt[i].ro)) return 0;
            rest = end;
        }
        return 1;
    }
    errno = ENOENT; return 0;
}
static int host_path(const char *p, char *out, size_t n, int *ro) { return host_path_ex(p, out, n, ro, 0); }
static int set_guest_name(const char *hp, const char *path) {
    const char *end = path + strlen(path); while (end > path && end[-1] == '/') end--;
    const char *start = end; while (start > path && start[-1] != '/' && start[-1] != ':') start--;
    char guest[0x301]; size_t k = end - start;
    if (k >= sizeof guest) { errno = ENAMETOOLONG; return -1; }
    memcpy(guest, start, k); guest[k] = 0;
    const char *physical = strrchr(hp, '/') + 1;
    if (strcmp(physical, guest)) return setxattr(hp, FS_GUEST_NAME, guest, strlen(guest), 0, XATTR_NOFOLLOW);
    if (!removexattr(hp, FS_GUEST_NAME, XATTR_NOFOLLOW) || errno == ENOATTR) return 0;
    return -1;
}
static Result err_res(const char *op, const char *path) {
    if (errno == ENOENT || errno == ENOTDIR) { if (g_flag.fs) LOG("fs %s 不存在：%s", op, path); return RES_PATH_NOT_FOUND; }   // Logged under DM_FS=1 (the game often probes with "not found", not logged by default)
    if (errno == EEXIST) return RES_PATH_EXISTS;
    LOG("fs %s %s 失败 errno=%d", op, path, errno); return RES_FAIL;
}
// Name resolution shares one lock with create/rename/enumerate, aliases and xattr are published to the guest together.
#define HP_EX(path, create) PATH_LOCK(); char hp[1024]; int ro = 0; if (!host_path_ex(path, hp, sizeof hp, &ro, create)) return err_res("path", path)
#define HP(path) HP_EX(path, 0)
#define RW() if (ro) { LOG("fs 写只读挂载：%s", hp); return RES_FAIL; }
// Create directory / create file: if the target exists, answer "already exists" as a writable mount would -- that is the only failure the game understands (the original save storage never fails to write); with a generic failure it carries on with a null handle
#define RW_CREATE() if (ro) { if (!access(hp, F_OK)) return RES_PATH_EXISTS; LOG("fs 写只读挂载：%s", hp); return RES_FAIL; }

// ---------- Mount ----------
HLE_FORCE("_ZN2nn2fs22QueryMountRomCacheSizeEPm", "fsp-srv；rom 直读宿主目录，缓存只给最小值", Result, h_fs_QueryRomCache, size_t *out) { *out = 0x1000; return RES_OK; }
HLE_FORCE("_ZN2nn2fs8MountRomEPKcPvm", "fsp-srv；rom → 宿主 RomFS 目录", Result, h_fs_MountRom, const char *name, void *cache, size_t sz) {
    (void)cache; (void)sz; char b[1024];
    Result r = mount(name, envdir("DM_ROMFS", "data/switch/3.3.94012/Update/RomFS", b, sizeof b), 1);
    if (r == RES_OK && getenv("DM_ROMFS_OVERLAY")) {
        PATH_LOCK();
        for (int i = 0; i < g_nmnt; i++) if (!strcmp(g_mnt[i].name, name)) {
            strlcpy(g_mnt[i].overlay, getenv("DM_ROMFS_OVERLAY"), sizeof g_mnt[i].overlay); break;
        }
    }
    return r;
}
// Add-on content (DLC) RomFS: DM_AOC_DIR/<index>/, extracted from the player's DLC NSPs by the packing script; mounted read-only, using the directory index like rom.
// The owned index list is reported by the aoc calls in hle_misc.c from the same directory; the game only mounts indices it was given, and a missing directory answers "target not found" (fs 2-1002, as on hardware without that DLC)
#define RES_TARGET_NOT_FOUND 0x7D402u   // fs module 2, description 1002
HLE_FORCE("_ZN2nn2fs31QueryMountAddOnContentCacheSizeEPmi", "fsp-srv；追加内容直读宿主目录，缓存只给最小值", Result, h_fs_QueryAocCache, size_t *out, int index) { (void)index; *out = 0x1000; return RES_OK; }
HLE_FORCE("_ZN2nn2fs17MountAddOnContentEPKciPvm", "fsp-srv；追加内容 → DM_AOC_DIR/<序号>（只读）", Result, h_fs_MountAoc, const char *name, int index, void *cache, size_t sz) {
    (void)cache; (void)sz; const char *base = getenv("DM_AOC_DIR"); char dir[1024]; struct stat st;
    if (!base || !*base || snprintf(dir, sizeof dir, "%s/%d", base, index) >= (int)sizeof dir || stat(dir, &st) || !S_ISDIR(st.st_mode)) {
        LOG("fs 挂载追加内容 %s: 序号 %d 不存在（DM_AOC_DIR=%s）", name, index, base ? base : "未设");
        return RES_TARGET_NOT_FOUND;
    }
    return mount(name, dir, 1);   // mount_ex logs it
}
// IsMounted: the original SDK checks its own mount table, which stays empty because the host takes over mounting. Engage (IL2CPP) uses it to check whether "rom:" is mounted before opening a file; a "no" fails with an invalid-parameter error (0x57) and global-metadata.dat cannot be opened
HLE_FORCE("_ZN2nn2fs9IsMountedEPKc", "fsp-srv；查宿主挂载表", int, h_fs_IsMounted, const char *name) {   // bool in w0: 1 / 0
    PATH_LOCK();
    for (int i = 0; name && i < g_nmnt; i++) if (!strcmp(g_mnt[i].name, name)) return 1;
    return 0;
}
HLE_FORCE("_ZN2nn2fs21MountTemporaryStorageEPKc", "fsp-srv；临时区 → 宿主目录", Result, h_fs_MountTemp, const char *name) {
    char b[1024]; return mount(name, envdir("DM_TEMP", "run/platform/temp", b, sizeof b), 0);
}
HLE_FORCE("_ZN2nn2fs14EnsureSaveDataERKNS_7account3UidE", "fsp-srv；存档目录在挂载时建", Result, h_fs_EnsureSave, const void *uid) { (void)uid; return RES_OK; }
// Settings defaults for the touch product (dropped item names shown permanently by default, can be turned off in settings): Settings/Settings.json in the save only records keys the player has changed, unrecorded ones use the game default.
// Before mounting the save, fill in the touch product defaults for the two keys "the player has not touched yet"; existing keys are never changed (if the player changed it in the options page, the player wins):
//   "Item Name Display": 1 -- options page 「显示物品」(Show Items) = toggle style (game default 0 = hold; touch has no key that can be held). Companion: the front end taps the 「显示物品」(Show Items) key once for the player the first time this process reaches the normal in-run state (front_ios.m),
//       in toggle style one tap keeps it shown, and it persists into the next run after exit and re-entry; a player who wants it off changes this item back to 「长按」(Hold).
//   "Item Tooltip Hotkey Appender": 0 -- item tooltips carry no controller key hints (game default 1).
//   Minimap (placed top right: mini, semi-transparent):
//   "AutoMapMode": 2 = mini map on the right (0 full screen / 1 left / 2 right, the game default is also 2, stated here explicitly); opacity (AutoMapFade) is not filled in, the game default 0 = no fade is used -- with 「全部」(All) (3) the minimap lines fade until almost only the text remains; the map is lines overlaid on the picture anyway, so it shows through without fading;
//   "AutoMap Open On Load": 1 = open automatically on entering a run (game default 0). Tapping the minimap = the map toggle key, see front_ios.m.
// Done by default in the iOS app; not done by default on the Mac host (gate checks compare images against Switch ground truth), DM_TOUCH_DEFAULTS=1 on / =0 off.
// Shared stash seed: when the save directory has no ModernSharedStashSoftCoreV2/ModernSharedStashSoftCoreV2.d2i, write the seed file (stash_seed.h); an existing one is not changed by a single byte.
// Done before mounting the save and cloning the working directory, so it is what the game reads the first time. On by default on iOS, DM_STASH_SEED=0 turns it off; off by default on the Mac host, DM_STASH_SEED=1 turns it on.
// Only covers the DLC type (standard + hardcore): SharedStash{Soft,Hard}CoreV2.d2i used by the Lord of Destruction type is not seeded -- the touch character creation page cannot create that kind of character
// The seed file stash_seed.h holds the bytes of a save the game itself generated, and the public repository does not ship it: without the header nothing is seeded (the game then creates an empty shared stash of its own the first time one is needed, as the original does)
#if __has_include("stash_seed.h")
#include "stash_seed.h"
static void stash_seed_one(const char *save_dir, const char *name) {
    char dir[1100], path[1200], tmp[1210]; snprintf(dir, sizeof dir, "%s/%s", save_dir, name); snprintf(path, sizeof path, "%s/%s.d2i", dir, name);
    struct stat st; if (!stat(path, &st)) return;
    if (mkdir(dir, 0755) && errno != EEXIST) { LOG("共享仓库预置：建目录 %s 失败（%s），不预置", dir, strerror(errno)); return; }
    snprintf(tmp, sizeof tmp, "%s.tmp", path); FILE *f = fopen(tmp, "wb"); if (!f) { LOG("共享仓库预置：写 %s 失败（%s），不预置", tmp, strerror(errno)); return; }
    int ok = fwrite(g_stash_seed, 1, sizeof g_stash_seed, f) == sizeof g_stash_seed; ok = fclose(f) == 0 && ok;
    if (ok && !rename(tmp, path)) LOG("共享仓库预置：%s 不存在，已写入预置文件（%zu 字节：250 万金币 + 2 枚赦免之证）", path, sizeof g_stash_seed); else { remove(tmp); LOG("共享仓库预置：写入失败，不预置"); }
}
// One copy each for standard and hardcore, each judged on its own (the game picks the file name by character type, main+0x2ce1e8: DLC type standard = ModernSharedStashSoftCoreV2, hardcore = ModernSharedStashHardCoreV2; same file format)
static void stash_seed(const char *save_dir) {
    const char *e = getenv("DM_STASH_SEED"); int on = e ? strcmp(e, "0") != 0 : TARGET_OS_IPHONE; if (!on) return;   // on by default on iOS; off by default on the Mac host (gate checks such as lockstep comparison / save transaction compare the save directory byte by byte, one extra file turns them red), set DM_STASH_SEED=1 to verify
    stash_seed_one(save_dir, "ModernSharedStashSoftCoreV2"); stash_seed_one(save_dir, "ModernSharedStashHardCoreV2");
}
#else
static void stash_seed(const char *save_dir) { (void)save_dir; }
#endif
// Fallback for 「大字体」(Large Font) (settings key "Low Vision Mode"): if it is 1 in the settings file, change it back to 0. It switches the UI to the original game's low-vision layout profile, which our touch UI was never built for; it hangs after being turned on in the settings page.
// This item in the settings page is separately hidden by the UI overlay; this here guarantees that devices where it was already turned on recover on restart. Same switch as settings_seed (on by default on iOS, on the Mac host only with DM_TOUCH_DEFAULTS=1)
static void low_vision_off(const char *save_dir) {
    const char *e = getenv("DM_TOUCH_DEFAULTS"); int on = e ? strcmp(e, "0") != 0 : TARGET_OS_IPHONE; if (!on) return;
    char path[1200]; snprintf(path, sizeof path, "%s/Settings/Settings.json", save_dir); static char buf[65536]; FILE *f = fopen(path, "rb"); if (!f) return;
    size_t n = fread(buf, 1, sizeof buf - 1, f); fclose(f); if (n == sizeof buf - 1) return; buf[n] = 0;
    char *k = strstr(buf, "\"Low Vision Mode\""); if (!k) return; char *v = strchr(k + 17, ':'); if (!v) return; v++; while (*v == ' ' || *v == '\t') v++;
    if (*v != '1' || (v[1] >= '0' && v[1] <= '9')) return; *v = '0';
    char tmp[1210]; snprintf(tmp, sizeof tmp, "%s.tmp", path); f = fopen(tmp, "wb"); if (!f) return; int ok = fwrite(buf, 1, n, f) == n; ok = fclose(f) == 0 && ok;
    if (ok && !rename(tmp, path)) LOG("设置兜底：「大字体」（Low Vision Mode）是开着的，已改回关"); else remove(tmp);
}
static void settings_seed(const char *save_dir) {
    const char *e = getenv("DM_TOUCH_DEFAULTS"); int on = e ? strcmp(e, "0") != 0 : TARGET_OS_IPHONE; if (!on) return;
    static const char *kv[][2] = {{"\"Item Name Display\"", "1"}, {"\"Item Tooltip Hotkey Appender\"", "0"},
                                  {"\"AutoMapMode\"", "2"}, {"\"AutoMap Open On Load\"", "1"}};
    char dir[1100], path[1200]; snprintf(dir, sizeof dir, "%s/Settings", save_dir); snprintf(path, sizeof path, "%s/Settings.json", dir);
    static char buf[65536], out[66000]; size_t n = 0; FILE *f = fopen(path, "rb");   // static: the game thread that mounts the save has a small stack (two 64 KB blocks on the stack overflow it outright, measured crash); mounting the save is done on one thread only
    int first = f == NULL;   // no settings file = first install
    if (f) { n = fread(buf, 1, sizeof buf - 1, f); fclose(f); if (n == sizeof buf - 1) { LOG("设置缺省：%s 超过 64 KB，不动", path); return; } }
    buf[n] = 0;
    char *brace = strchr(buf, '{'); int had = brace != NULL; size_t o = 0; int added = 0;
    o += (size_t)snprintf(out + o, sizeof out - o, "{");
    for (size_t i = 0; i < sizeof kv / sizeof kv[0]; i++) if (!strstr(buf, kv[i][0])) { o += (size_t)snprintf(out + o, sizeof out - o, "\n    %s: %s,", kv[i][0], kv[i][1]); added++; }
    // On first install the original game's text and voice languages are set from the system language (dm_sys_lang(), see dm_i18n.c; only when there is no settings file). An existing settings file does not get these two keys added (existing players stay as they are); afterwards they are changed by the language switch on the Custom page (settings_lang_apply)
    if (first) { int dm_sys_lang(void); o += (size_t)snprintf(out + o, sizeof out - o, "\n    \"Language\": %d,\n    \"VoiceLanguage\": %d,", dm_sys_lang(), dm_sys_lang()); added += 2; }
    if (!added) return;
    if (had) { const char *rest = brace + 1; const char *q = rest; while (*q == ' ' || *q == '\n' || *q == '\r' || *q == '\t') q++;
        if (*q == '}') { out[o - 1] = 0; o--; }   // the original file is an empty object: remove the last comma that was added
        o += (size_t)snprintf(out + o, sizeof out - o, "%s", rest); }
    else { out[o - 1] = 0; o--; o += (size_t)snprintf(out + o, sizeof out - o, "\n}\n"); }
    mkdir(dir, 0755); char tmp[1300]; snprintf(tmp, sizeof tmp, "%s.seed", path);
    f = fopen(tmp, "wb"); if (!f || fwrite(out, 1, o, f) != o) { if (f) fclose(f); LOG("【红】设置缺省：写 %s 失败", tmp); return; }
    fclose(f); if (rename(tmp, path)) { LOG("【红】设置缺省：改名到 %s 失败", path); return; }
    LOG("设置缺省：%s 补了 %d 个键（显示物品 = 开关式 / 说明条热键 = 关 / 小地图放右、进局自动开%s；已有的键不动）", path, added, first ? " / 首次安装按系统语言写 Language" : "");
}
// Language switch (the cell in the title row of the Custom page, lang_en in dm_custom.c): once the player has tapped 「应用」(Apply) the settings file holds an explicit value, and on every save mount (before the game reads its settings) the original game's settings file has its
// Language (text) and VoiceLanguage (voice; the voice switches along with it) changed to 0 English / 8 Simplified Chinese accordingly. It is changed only when it "does not match the switch": switch = English but text is not 0; switch = Chinese but text is 0.
// So with the switch off, if the player has chosen another language such as Traditional Chinese in the original game, it is not changed back to Simplified Chinese. Whichever of the two keys is missing is added. Apply never tapped (-1) = nothing is touched
static int json_int_set(char *buf, size_t cap, const char *key, int val) {   // Replace the N of "key": N with val (if the key is absent, insert it after the first {); returns 1 = changed
    char *k = strstr(buf, key); char num[16]; snprintf(num, sizeof num, "%d", val);
    if (!k) { char *b = strchr(buf, '{'); char ins[96]; int m = snprintf(ins, sizeof ins, "\n    %s: %s,", key, num); if (!b || strlen(buf) + (size_t)m + 1 >= cap) return 0;
        memmove(b + 1 + m, b + 1, strlen(b + 1) + 1); memcpy(b + 1, ins, (size_t)m); return 1; }
    char *v = strchr(k + strlen(key), ':'); if (!v) return 0; v++; while (*v == ' ' || *v == '\t') v++; char *e = v; if (*e == '-') e++; while (*e >= '0' && *e <= '9') e++;
    if (e == v || atoi(v) == val) return 0; size_t nl = strlen(num); if (strlen(buf) + nl + 1 >= cap) return 0;
    memmove(v + nl, e, strlen(e) + 1); memcpy(v, num, nl); return 1; }
static void settings_lang_apply(const char *save_dir) {
    int dm_custom_lang_explicit(void); int en = dm_custom_lang_explicit(); if (en < 0) return;
    char path[1200]; snprintf(path, sizeof path, "%s/Settings/Settings.json", save_dir); static char buf[66000]; FILE *f = fopen(path, "rb"); if (!f) return;
    size_t n = fread(buf, 1, 65535, f); fclose(f); if (n == 65535) return; buf[n] = 0;
    const char *k = strstr(buf, "\"Language\""), *c = k ? strchr(k + 10, ':') : NULL; int cur = c ? atoi(c + 1) : 0;   // Not written = game default (the host reports en-US)
    if ((en && cur == 0) || (!en && cur != 0)) { const char *vk = strstr(buf, "\"VoiceLanguage\""), *vc = vk ? strchr(vk + 15, ':') : NULL; int vcur = vc ? atoi(vc + 1) : cur;
        if ((en && vcur == 0) || (!en && vcur != 0)) return; }   // Text and voice already match the switch
    int want = en ? 0 : 8, ch = json_int_set(buf, sizeof buf, "\"Language\"", want) | json_int_set(buf, sizeof buf, "\"VoiceLanguage\"", want); if (!ch) return;
    char tmp[1300]; snprintf(tmp, sizeof tmp, "%s.lang", path); f = fopen(tmp, "wb"); size_t m = strlen(buf);
    if (!f || fwrite(buf, 1, m, f) != m) { if (f) fclose(f); LOG("【红】语言开关：写 %s 失败", tmp); return; }
    fclose(f); if (rename(tmp, path)) { LOG("【红】语言开关：改名到 %s 失败", path); return; }
    LOG("语言开关：设置文件的 Language / VoiceLanguage 改成 %d（%s；原文字语言 %d）", want, en ? "英文" : "简中", cur);
}
// The current working directory of the transactional save (the copy the game reads and writes; the host's own side files must be written here to enter the committed version with Commit). Returns NULL when no save is mounted
const char *dm_save_workdir(void) { for (int i = 0; i < g_nmnt; i++) if (g_mnt[i].commit[0]) return g_mnt[i].dir; return NULL; }
// The committed directory of the transactional save (the copy on disk, the version from the last Commit). Returns NULL when no save is mounted
const char *dm_save_commitdir(void) { for (int i = 0; i < g_nmnt; i++) if (g_mnt[i].commit[0]) return g_mnt[i].commit; return NULL; }
void (*g_dm_mount_seed_hook)(const char *save_dir);   // called before mounting the save (save dir): adds the files the host needs to the save
HLE_FORCE("_ZN2nn2fs13MountSaveDataEPKcRKNS_7account3UidE", "fsp-srv；存档 → 宿主目录（单用户）", Result, h_fs_MountSave, const char *name, const void *uid) {
    (void)uid;
    // No default directory: silently landing on a directory with no characters distorts the "character select" measurement (this once caused a misjudgment). Runs always use a fresh copy of save_ref
    const char *d = getenv("DM_SAVE");
    if (!d) die("未设 DM_SAVE：请指向一份存档目录的可写副本");
    char dd[1024]; strlcpy(dd, d, sizeof dd); size_t L = strlen(dd); while (L > 1 && dd[L - 1] == '/') dd[--L] = 0;   // strip trailing slashes (.work / .new are appended at the same level)
    // The items below all edit D2R's save (Settings/Settings.json, shared stash): only on the D2R build, other games' files of the same name are left alone
    int d2r = !strcmp(dm_main_build(), DM_D2R_BUILD);
    if (d2r) { stash_seed(dd); low_vision_off(dd); settings_seed(dd); settings_lang_apply(dd); }
    // Rule files for the loot filter (the game loads them at startup; dm_lootfilter.c registers this hook from a constructor; it is null in unit tests that link only hle_fs.c). Same switch as settings_seed:
    // written by default on iOS; not written under the Mac host's parity gate (saves must match the device ground truth file by file)
    { const char *e = getenv("DM_TOUCH_DEFAULTS"); if (d2r && g_dm_mount_seed_hook && (e ? strcmp(e, "0") != 0 : TARGET_OS_IPHONE)) g_dm_mount_seed_hook(dd); }
    return mount_ex(name, dd, 0, 1);
}
void (*g_dm_pre_commit_hook[4])(const char *workdir);   // called before commit (working directory): host side files are checked against the save contents in the working directory before being written ([0] personal stash pages dm_pages.c, [2] pouch dm_pouch.c, [1] chronicle vault dm_vault.c, [3] rift progress dm_rift.c)
void (*g_dm_save_commit_hook)(const char *commit_dir);   // called after a save commit succeeds (committed directory); the iOS iCloud sync sets it, NULL on the host
static _Atomic uint64_t g_save_commits;   // number of successful commits (used by the front end when going to background to wait for "the game's current save has been committed")
uint64_t dm_fs_commit_count(void) { return atomic_load(&g_save_commits); }
HLE_FORCE("_ZN2nn2fs6CommitEPKc", "fsp-srv；事务式存档：工作目录整树 clone 后与已提交目录原子互换（renamex_np RENAME_SWAP）", Result, h_fs_Commit, const char *name) {
    PATH_LOCK(); pthread_mutex_lock(&g_lock);
    int i = 0; while (i < g_nmnt && strcmp(g_mnt[i].name, name)) i++;
    if (i == g_nmnt || !g_mnt[i].commit[0]) { pthread_mutex_unlock(&g_lock); return RES_OK; }   // non-transactional mount: nothing to commit
    uint64_t tc0 = clock_gettime_nsec_np(CLOCK_MONOTONIC), tw0 = atomic_exchange(&g_txn_first_ns, 0);
    for (int k = 0; k < 4; k++) if (g_dm_pre_commit_hook[k]) g_dm_pre_commit_hook[k](g_mnt[i].dir);
    uint64_t tc1 = clock_gettime_nsec_np(CLOCK_MONOTONIC);   // side files written into the working directory are swapped in atomically together with this commit
    int perr = atomic_exchange(&g_save_poison, 0);
    if (perr) {                                                         // a write failed in this transaction: refuse the commit, discard the working directory
        char torn[512] = ""; size_t tl = 0; DIR *d0 = opendir(g_mnt[i].dir); struct dirent *e0;   // record files truncated to 0 bytes (the damage that would enter the save if committed as usual)
        while (d0 && (e0 = readdir(d0))) {
            if (e0->d_name[0] == '.') continue;
            char sub[1300]; snprintf(sub, sizeof sub, "%s/%s", g_mnt[i].dir, e0->d_name); DIR *d1 = opendir(sub); struct dirent *e1;
            while (d1 && (e1 = readdir(d1))) { char f[1600]; struct stat st; snprintf(f, sizeof f, "%s/%s", sub, e1->d_name);
                if (e1->d_name[0] != '.' && !stat(f, &st) && S_ISREG(st.st_mode) && !st.st_size && tl + strlen(e0->d_name) + strlen(e1->d_name) + 3 < sizeof torn)
                    tl += snprintf(torn + tl, sizeof torn - tl, " %s/%s", e0->d_name, e1->d_name); }
            if (d1) closedir(d1);
        }
        if (d0) closedir(d0);
        int nopen = 0; for (int k = 0; k < 65536; k++) nopen += g_fsave[k];   // save files still open: after re-cloning, these handles point into the deleted old working directory
        // First clone the committed version into a sibling temporary directory; once that succeeds, atomically swap it with the tainted work directory and delete the swapped-out one. If any step fails, do not exit: the work directory stays and the "tainted" mark is put back
        // (the next commit is refused again and recloning is retried); the committed version is unchanged (before, the work directory was deleted first and then recloned, and a failed clone called die, so with a full disk the process exited and the work directory was gone)
        char re[1100]; snprintf(re, sizeof re, "%s.re", g_mnt[i].dir); int rerr = 0;
        if (!access(re, F_OK) && rm_tree(re)) rerr = errno ? errno : EIO;
        else if (dm_fs_test_fail("reclone") || clonefile(g_mnt[i].commit, re, 0)) { rerr = errno ? errno : EIO; rm_tree(re); }
        else if (renamex_np(re, g_mnt[i].dir, RENAME_SWAP)) { rerr = errno ? errno : EIO; rm_tree(re); }
        else rm_tree(re);                                               // the swapped-out tainted work directory
        if (rerr) { save_poison(perr); LOG("【红】存档事务：重新克隆工作目录失败 errno=%d——工作目录不动、保持已污染（下次提交照样拒绝并重试），已提交版本不变", rerr); }
        pthread_mutex_unlock(&g_lock);
        LOG("【红】存档提交拒绝：本事务有存档写失败 errno=%d（工作目录里 0 字节文件：%s）；已提交版本不变，工作目录%s%s", perr, tl ? torn + 1 : "无", rerr ? "没能重新克隆（见上一行）" : "已从已提交版重新克隆", nopen ? "；【红】仍有存档文件开着" : "");
        front_save_failed(perr);
        return RES_FAIL;
    }
    char neu[1100]; snprintf(neu, sizeof neu, "%s.new", g_mnt[i].commit);
    Result r = RES_OK;
    if (!access(neu, F_OK)) rm_tree(neu);
    if (clonefile(g_mnt[i].dir, neu, 0)) { LOG("【红】存档提交：clonefile %s 失败 errno=%d（已提交版本不变）", neu, errno); r = RES_FAIL; }
    else if (renamex_np(neu, g_mnt[i].commit, RENAME_SWAP)) { LOG("【红】存档提交：原子互换失败 errno=%d（已提交版本不变）", errno); rm_tree(neu); r = RES_FAIL; }
    else rm_tree(neu);                                                  // the old version that was swapped out
    // Timing readouts (integer microseconds, no floating point): how long the pre-commit hook and the clone + atomic swap each took; how long in total from this transaction's first save write to the end of the commit (the game writing files + the commit; 0 = no save write in this transaction)
    static int n; if (r == RES_OK) { uint64_t tc2 = clock_gettime_nsec_np(CLOCK_MONOTONIC);
        LOG("存档提交 #%d：%s 原子换入 %s（此前存档写 %d 次）（钩子 %llu 微秒、克隆换入 %llu 微秒、自本事务首次写起 %llu 微秒）", ++n, g_mnt[i].dir, g_mnt[i].commit, atomic_load(&g_save_writes),
            (unsigned long long)((tc1 - tc0) / 1000), (unsigned long long)((tc2 - tc1) / 1000), (unsigned long long)(tw0 ? (tc2 - tw0) / 1000 : 0)); atomic_fetch_add(&g_save_commits, 1);
        if (g_dm_save_commit_hook) g_dm_save_commit_hook(g_mnt[i].commit); }   // iCloud sync (cloud_ios.m): called with the lock held, that side only takes a clonefile snapshot
    pthread_mutex_unlock(&g_lock);
    return r;
}
// SDK 11's old name: CommitSaveData(mount name) is the later Commit (Metroid Dread)
HLE_FORCE("_ZN2nn2fs14CommitSaveDataEPKc", "fsp-srv；同 Commit（SDK 11 旧名）", Result, h_fs_CommitSaveData, const char *name) { return h_fs_Commit(name); }
HLE_FORCE("_ZN2nn2fs7UnmountEPKc", "fsp-srv；挂载表常驻，卸载为空操作", void, h_fs_Unmount, const char *name) { (void)name; }

// ---------- Files ----------
// Zero-stripped archives: large zero-filled ranges in the resource pack (cutscene videos, old-version music) are not distributed with the package -- these zero-filled ranges are stripped from the archive file, and an extent table is placed beside it,
// "<archive name>.holes" (text: first line `size <original byte count>`, then one line `<zero-filled range start> <zero-filled range length>` each, ascending by start, non-overlapping).
// When reading such archives the host translates offsets through the table: bytes falling in a zero-filled range return 0 and the file size is reported as the original value; the game and the startup prefetch still see the original layout, and not a single word of the index needs changing.
// There are only two read entry points: ReadFile in this file and the startup prefetch in hle_tact.c, both going through dm_data_pread. Files without .holes take the original path with zero extra overhead.
typedef struct { int64_t size; int n; int64_t *log, *len, *phys; char name[40]; } holemap;   // Kept segment: original start / length / start in the zero-stripped file
static _Atomic uint64_t g_hole_reads;   // Number of reads that hit a zero-filled range: should normally be 0 (zero-filled ranges are stripped cutscene videos / old-version music the game should not come to read); non-zero = stripped wrongly
static holemap *g_hm[4096];
static holemap *hm_load(const char *hostpath) {
    char hp2[1100]; if (snprintf(hp2, sizeof hp2, "%s.holes", hostpath) >= (int)sizeof hp2) return NULL;
    FILE *f = fopen(hp2, "r"); if (!f) return NULL;
    long long size = -1, o, l; if (fscanf(f, "size %lld", &size) != 1 || size < 0) die("区段表格式不对：%s", hp2);
    holemap *m = calloc(1, sizeof *m); int cap = 64; m->size = size; m->log = malloc(cap * sizeof *m->log); m->len = malloc(cap * sizeof *m->len); m->phys = malloc(cap * sizeof *m->phys);
    int64_t pos = 0, phys = 0;
    while (fscanf(f, "%lld %lld", &o, &l) == 2) {
        if (o < pos || l <= 0 || o + l > size) die("区段表零段越界或乱序：%s（%lld %lld）", hp2, o, l);
        if (o > pos) { if (m->n == cap) { cap *= 2; m->log = realloc(m->log, cap * sizeof *m->log); m->len = realloc(m->len, cap * sizeof *m->len); m->phys = realloc(m->phys, cap * sizeof *m->phys); }
            m->log[m->n] = pos; m->len[m->n] = o - pos; m->phys[m->n++] = phys; phys += o - pos; }
        pos = o + l;
    }
    fclose(f);
    if (pos < size) { if (m->n == cap) { cap++; m->log = realloc(m->log, cap * sizeof *m->log); m->len = realloc(m->len, cap * sizeof *m->len); m->phys = realloc(m->phys, cap * sizeof *m->phys); }
        m->log[m->n] = pos; m->len[m->n] = size - pos; m->phys[m->n++] = phys; phys += size - pos; }
    struct stat st; if (stat(hostpath, &st) || st.st_size != phys) die("剔零档案长度与区段表不符：%s 实际 %lld，按表应为 %lld", hostpath, (long long)st.st_size, (long long)phys);
    const char *bn = strrchr(hostpath, '/'); strlcpy(m->name, bn ? bn + 1 : hostpath, sizeof m->name);
    { static _Atomic int said[64]; unsigned h = 0; for (const char *c = m->name; *c; c++) h = h * 31 + (unsigned char)*c;   // Print a line for each archive only on first registration
      if (!atomic_exchange(&said[h % 64], 1)) LOG("剔零档案 %s：原始 %lld 字节，实存 %lld 字节，保留段 %d 个", m->name, (long long)size, (long long)phys, m->n); }
    return m;
}
void dm_data_note_fd(int fd, const char *hostpath) {   // Called after opening a resource archive: register it if there is an extent table
    if (fd < 0 || fd >= 4096) return;
    g_hm[fd] = hm_load(hostpath);
}
// Same as dm_data_logical_size, but opened relative to the directory fd: listing does not resolve the long path from the root again for every entry
static int64_t data_logical_size_at(int dfd, const char *name, int64_t phys_size) {
    char hn[0x320]; if (snprintf(hn, sizeof hn, "%s.holes", name) >= (int)sizeof hn) return phys_size;
    int fd = openat(dfd, hn, O_RDONLY); if (fd < 0) return phys_size;
    FILE *f = fdopen(fd, "r"); if (!f) { close(fd); return phys_size; }
    long long size = -1; int ok = fscanf(f, "size %lld", &size) == 1; fclose(f); return ok && size >= 0 ? size : phys_size;
}
int64_t dm_data_logical_size(const char *hostpath, int64_t phys_size) {   // For directory listing / size queries: report the original size when there is an extent table
    char hp2[1100]; if (snprintf(hp2, sizeof hp2, "%s.holes", hostpath) >= (int)sizeof hp2) return phys_size;
    FILE *f = fopen(hp2, "r"); if (!f) return phys_size; long long size = -1; int ok = fscanf(f, "size %lld", &size) == 1; fclose(f); return ok && size >= 0 ? size : phys_size;
}
ssize_t dm_data_pread(int fd, void *buf, size_t n, off_t off) {   // Same semantics as pread (may short-read); zero-stripped archives are translated through the extent table
    holemap *m = fd >= 0 && fd < 4096 ? g_hm[fd] : NULL;
    if (!m) return pread(fd, buf, n, off);
    if (off >= m->size) return 0;
    if ((int64_t)n > m->size - off) n = (size_t)(m->size - off);
    int lo = 0, hi = m->n;   // The first kept segment whose end point > off
    while (lo < hi) { int mid = (lo + hi) / 2; if (m->log[mid] + m->len[mid] <= off) lo = mid + 1; else hi = mid; }
    size_t done = 0;
    while (done < n) {
        int64_t cur = off + (int64_t)done;
        if (lo < m->n && cur >= m->log[lo]) {   // In a kept segment: read directly into the destination buffer
            int64_t in = cur - m->log[lo]; size_t want = n - done; if ((int64_t)want > m->len[lo] - in) want = (size_t)(m->len[lo] - in);
            size_t got = 0; while (got < want) { ssize_t r = pread(fd, (uint8_t *)buf + done + got, want - got, m->phys[lo] + in + (int64_t)got); if (r < 0) { if (errno == EINTR) continue; return -1; } if (r == 0) return (ssize_t)(done + got); got += (size_t)r; }
            done += want; if (in + (int64_t)want == m->len[lo]) lo++;
        } else {                               // In a zero-filled range: fill 0 up to the start of the next kept segment
            int64_t end = lo < m->n ? m->log[lo] : m->size; size_t z = n - done; if ((int64_t)z > end - cur) z = (size_t)(end - cur);
            memset((uint8_t *)buf + done, 0, z); done += z;
            // The game reads whole blocks aligned to 256 KB: when what it wants is a kept file next to a zero-filled range, the whole block incidentally overlaps the edge of the zero-filled range (harmless, the kept file's bytes are returned as usual).
            // Only a read that lies entirely inside a zero-filled range is really reading stripped content → report a failure (the first 20 one by one, then one line per 1000); boundary-crossing reads are only noted the first 3 times
            if (z == n) { uint64_t hr = atomic_fetch_add(&g_hole_reads, 1);
                if (hr < 20 || hr % 1000 == 0) LOG("【红】读到剔零区段 %s 偏移 %lld 长 %zu（第 %llu 次；整块都在被砍掉的过场视频 / 旧版音乐里，说明砍错了或有新的读者）", m->name, (long long)off, n, (unsigned long long)hr + 1);
            } else { static _Atomic uint64_t edge; if (atomic_fetch_add(&edge, 1) < 3) LOG("整块读压到剔零区段边缘（无害）：%s 读 %lld 长 %zu，其中 %zu 字节在零段", m->name, (long long)off, n, z); }
        }
    }
    return (ssize_t)done;
}
HLE_FORCE("_ZN2nn2fs8OpenFileEPNS0_10FileHandleEPKci", "fsp-srv → open(2)", Result, h_fs_OpenFile, uint64_t *out, const char *path, int mode) {
    HP(path);
    if (mode & (MODE_WRITE | MODE_APPEND)) RW();
    int fd = open(hp, (mode & (MODE_WRITE | MODE_APPEND)) ? ((mode & MODE_READ) ? O_RDWR : O_WRONLY) : O_RDONLY);
    if (fd < 0) return err_res("open", hp);
    struct stat st; fstat(fd, &st);
    if (S_ISDIR(st.st_mode)) { close(fd); return RES_PATH_NOT_FOUND; }
    if (fd >= (int)sizeof g_fmode) die("fd 超出表");
    g_fmode[fd] = (uint8_t)mode; *out = (uint64_t)fd;
    g_hm[fd] = NULL; if (!(mode & (MODE_WRITE | MODE_APPEND))) dm_data_note_fd(fd, hp);
    { const char *c = strchr(path, ':'); size_t ln = c ? (size_t)(c - path) : 0; g_fsave[fd] = 0;
      for (int i = 0; c && i < g_nmnt; i++) if (strlen(g_mnt[i].name) == ln && !strncmp(g_mnt[i].name, path, ln)) g_fsave[fd] = g_mnt[i].commit[0] != 0; }
    fslog_init();
    if (g_fslog && fd < 4096) { pthread_mutex_lock(&g_fslog_lock); free(g_fdpath[fd]); g_fdpath[fd] = strdup(path); pthread_mutex_unlock(&g_fslog_lock); }
    if (g_flag.fs) LOG("fs open [%.2fs] %s mode=%d → fd %d", (now_ns() - g_t0_ns) / 1e9, path, mode, fd);
    return RES_OK;
}
HLE_FORCE("_ZN2nn2fs8ReadFileEPmNS0_10FileHandleElPvm", "fsp-srv → pread(2)", Result, h_fs_ReadFile, size_t *out, uint64_t h, int64_t off, void *buf, size_t sz) {
    if (!h) { *out = 0; return RES_FAIL; }   // a file handle is an fd; 0 is stdin and never a file the game opened: the null handle the game keeps using after a failed open
    size_t got = 0; uint64_t t0 = g_flag.bootprof ? now_ns() : 0;
    dm_guest_write_prepare(buf, sz);   // The destination may be a texture pool page write-protected by the graphics layer: a kernel write to a read-only page returns EFAULT instead of page-faulting, so unprotect and mark dirty first
    while (got < sz) {
        ssize_t r = dm_data_pread((int)h, (uint8_t *)buf + got, sz - got, off + got);
        if (r < 0) { if (errno == EINTR) continue; return err_res("pread", "fd"); }
        if (r == 0) break;
        got += r;
    }
    *out = got;
    if (g_flag.bootprof) dm_prof_add(PROF_FS_READ, now_ns() - t0, got);
    if (g_fslog) { pthread_mutex_lock(&g_fslog_lock);
        static int hash_on = -1; if (hash_on < 0) hash_on = getenv("DM_FSLOG_HASH") != NULL;   // DM_FSLOG_HASH=1: append a column with the FNV-1a 64 of the content read (to compare whether the bytes read from two resource packs match)
        uint64_t fh = 0xcbf29ce484222325ull; if (hash_on) for (size_t i = 0; i < got; i++) fh = (fh ^ ((uint8_t *)buf)[i]) * 0x100000001b3ull;
        if (hash_on) fprintf(g_fslog, "%.4f\t%s\t%lld\t%zu\t%p\t%016llx\n", (now_ns() - g_t0_ns) / 1e9, (int)h < 4096 && g_fdpath[(int)h] ? g_fdpath[(int)h] : "?", (long long)off, got, buf, (unsigned long long)fh);
        else fprintf(g_fslog, "%.4f\t%s\t%lld\t%zu\t%p\n", (now_ns() - g_t0_ns) / 1e9, (int)h < 4096 && g_fdpath[(int)h] ? g_fdpath[(int)h] : "?", (long long)off, got, buf);
        pthread_mutex_unlock(&g_fslog_lock); }
    if (g_flag.fs) {   // Read metering: print a line every 64 MiB accumulated or every 1000 reads
        static uint64_t n, bytes, next_b = 64 << 20; static pthread_mutex_t m = PTHREAD_MUTEX_INITIALIZER;
        pthread_mutex_lock(&m); n++; bytes += got;
        if (bytes >= next_b || n % 1000 == 0) { LOG("fs 读 累计 %llu 次 %.1f MiB（本次 fd %d 偏移 %#llx 长 %#zx）", n, bytes / 1048576.0, (int)h, off, got); if (bytes >= next_b) next_b += 64 << 20; }
        pthread_mutex_unlock(&m);
    }
    return RES_OK;
}
HLE_FORCE("_ZN2nn2fs9WriteFileENS0_10FileHandleElPKvmRKNS0_11WriteOptionE", "fsp-srv → pwrite(2)", Result, h_fs_WriteFile, uint64_t h, int64_t off, const void *buf, size_t sz, const void *opt) {
    if (!h) return RES_FAIL;
    (void)opt; size_t put = 0;
    if (g_fsave[(int)h & 0xffff]) {                                     // Save write injection point (for deterministic regression; only writes on the save mount are counted)
        static int cfg = -1, kill_n, fail_n, fail_e;
        if (cfg < 0) { const char *k = getenv("DM_TEST_KILL_AT"), *f = getenv("DM_TEST_FS_FAIL");
            kill_n = k && !strncmp(k, "write:", 6) ? atoi(k + 6) : 0;
            if (f && !strncmp(f, "write:", 6)) { fail_n = atoi(f + 6); const char *c = strchr(f + 6, ':'); fail_e = c ? atoi(c + 1) : ENOSPC; }
            cfg = 1; }
        int n = atomic_fetch_add(&g_save_writes, 1) + 1;
        { uint64_t z = 0; atomic_compare_exchange_strong(&g_txn_first_ns, &z, clock_gettime_nsec_np(CLOCK_MONOTONIC)); }
        if (kill_n && n == kill_n) { LOG("DM_TEST_KILL_AT：存档第 %d 次写，直接 _exit（模拟写到一半被杀）", n); _exit(9); }
        if (fail_n && n == fail_n) { LOG("DM_TEST_FS_FAIL：存档第 %d 次写返回失败 errno=%d", n, fail_e); errno = fail_e; save_poison(fail_e); return err_res("pwrite（注入）", "fd"); }
    }
    while (put < sz) {
        ssize_t r = pwrite((int)h, (const uint8_t *)buf + put, sz - put, off + put);
        if (r < 0) { if (errno == EINTR) continue; if (g_fsave[(int)h & 0xffff]) save_poison(errno); return err_res("pwrite", "fd"); }
        if (r == 0) { errno = ENOSPC; if (g_fsave[(int)h & 0xffff]) save_poison(ENOSPC); return err_res("pwrite（写入 0 字节）", "fd"); }   // This used to loop forever here
        put += r;
    }
    return RES_OK;
}
HLE_FORCE("_ZN2nn2fs11GetFileSizeEPlNS0_10FileHandleE", "fsp-srv → fstat(2)", Result, h_fs_GetFileSize, int64_t *out, uint64_t h) {
    if (!h) return RES_FAIL;
    struct stat st; if (fstat((int)h, &st)) return err_res("fstat", "fd");
    *out = (int)h < 4096 && g_hm[(int)h] ? g_hm[(int)h]->size : st.st_size; return RES_OK;
}
HLE_FORCE("_ZN2nn2fs11SetFileSizeENS0_10FileHandleEl", "fsp-srv → ftruncate(2)", Result, h_fs_SetFileSize, uint64_t h, int64_t sz) {
    if (!h) return RES_FAIL;
    if (!ftruncate((int)h, sz)) return RES_OK;
    if (g_fsave[(int)h & 0xffff]) save_poison(errno);
    return err_res("ftruncate", "fd");
}
HLE_FORCE("_ZN2nn2fs9FlushFileENS0_10FileHandleE", "fsp-srv；宿主 write 已进页缓存，刷新为空操作", Result, h_fs_FlushFile, uint64_t h) { (void)h; return RES_OK; }
HLE_FORCE("_ZN2nn2fs9CloseFileENS0_10FileHandleE", "fsp-srv → close(2)", void, h_fs_CloseFile, uint64_t h) {
    if (!h) return;   // the null handle after a failed open (see ReadFile): do not touch fd 0
    g_fmode[(int)h & 0xffff] = 0; g_fsave[(int)h & 0xffff] = 0;
    if ((int)h >= 0 && (int)h < 4096 && g_hm[(int)h]) { holemap *m = g_hm[(int)h]; g_hm[(int)h] = NULL; free(m->log); free(m->len); free(m->phys); free(m); }
    close((int)h); }
HLE_FORCE("_ZN2nn2fs15GetFileOpenModeENS0_10FileHandleE", "fsp-srv；打开方式由宿主记录", int, h_fs_GetFileOpenMode, uint64_t h) { return g_fmode[(int)h & 0xffff]; }

// ---------- Path operations ----------
HLE_FORCE("_ZN2nn2fs10CreateFileEPKcl", "fsp-srv → open(O_CREAT|O_EXCL)+ftruncate", Result, h_fs_CreateFile, const char *path, int64_t sz) {
    HP_EX(path, 1); RW_CREATE();
    int fd = open(hp, O_WRONLY | O_CREAT | O_EXCL, 0644);
    if (fd < 0) return err_res("create", hp);
    int rc = ftruncate(fd, sz); int e = errno; close(fd);
    if (!rc && set_guest_name(hp, path)) { rc = -1; e = errno; }
    if (rc) unlink(hp);
    errno = e; return rc ? err_res("create", hp) : RES_OK;
}
HLE_FORCE("_ZN2nn2fs10DeleteFileEPKc", "fsp-srv → unlink(2)", Result, h_fs_DeleteFile, const char *path) { HP(path); RW(); return unlink(hp) ? err_res("unlink", hp) : RES_OK; }
HLE_FORCE("_ZN2nn2fs15CreateDirectoryEPKc", "fsp-srv → mkdir(2)", Result, h_fs_CreateDirectory, const char *path) { HP_EX(path, 1); RW_CREATE();
    if (mkdir(hp, 0755)) return err_res("mkdir", hp);
    if (set_guest_name(hp, path)) { int e = errno; rmdir(hp); errno = e; return err_res("mkdir name", hp); }
    return RES_OK; }
static int rm_tree(const char *p) {
    DIR *d = opendir(p); if (!d) return -1;
    struct dirent *e; char c[1024]; int rc = 0;
    while ((e = readdir(d))) {
        if (!strcmp(e->d_name, ".") || !strcmp(e->d_name, "..")) continue;
        snprintf(c, sizeof c, "%s/%s", p, e->d_name);
        rc |= e->d_type == DT_DIR ? rm_tree(c) : unlink(c);
    }
    closedir(d);
    return rc | rmdir(p);
}
HLE_FORCE("_ZN2nn2fs26DeleteDirectoryRecursivelyEPKc", "fsp-srv → 递归删除（只在可写挂载内）", Result, h_fs_DeleteDirRec, const char *path) {
    HP(path); RW(); return rm_tree(hp) ? err_res("rmtree", hp) : RES_OK;
}
// empty a directory and keep the directory itself (13 Sentinels)
HLE_FORCE("_ZN2nn2fs25CleanDirectoryRecursivelyEPKc", "fsp-srv → 递归删除目录内容、保留目录（只在可写挂载内）", Result, h_fs_CleanDirRec, const char *path) {
    HP(path); RW();
    DIR *d = opendir(hp); if (!d) return err_res("cleandir", hp);
    struct dirent *e; char c[1024]; int rc = 0;
    while ((e = readdir(d))) {
        if (!strcmp(e->d_name, ".") || !strcmp(e->d_name, "..")) continue;
        snprintf(c, sizeof c, "%s/%s", hp, e->d_name);
        rc |= e->d_type == DT_DIR ? rm_tree(c) : unlink(c);
    }
    closedir(d);
    return rc ? err_res("cleandir", hp) : RES_OK;
}
// file data cache (a global read cache in the fs process): the host reads through the page cache and leaves the buffer unused
HLE_FORCE("_ZN2nn2fs25EnableGlobalFileDataCacheEPvm", "fsp-srv 全局读缓存；宿主不用", void, h_fs_EnableGlobalCache, void *buf, size_t sz) { (void)buf; (void)sz; }
// SDK 11 (Metroid Dread): delete an empty directory
HLE_FORCE("_ZN2nn2fs15DeleteDirectoryEPKc", "fsp-srv → rmdir(2)（目录须空）", Result, h_fs_DeleteDir, const char *path) {
    HP(path); RW(); return rmdir(hp) ? err_res("rmdir", hp) : RES_OK;
}
HLE_FORCE("_ZN2nn2fs10RenameFileEPKcS2_", "fsp-srv → rename(2)", Result, h_fs_RenameFile, const char *from, const char *to) {
    HP(from); RW(); char hp2[1024];
    if (!host_path_ex(to, hp2, sizeof hp2, NULL, 1)) return err_res("rename path", to);
    if (!access(hp2, F_OK)) return RES_PATH_EXISTS;
    if (rename(hp, hp2)) return err_res("rename", hp);
    if (dm_fs_test_fail("guestname") || set_guest_name(hp2, to)) { int e = errno ? errno : EIO;
        if (dm_fs_test_fail("renameback") || rename(hp2, hp)) {   // the rollback fails too: the file stays at the new path with wrong guest-name metadata; do not exit -- inside a transactional save, this transaction's commit is refused (committed version unchanged; recloning restores it)
            LOG("【红】fs 改名元数据失败且回退失败 errno=%d：%s 留在新路径%s", errno, hp2, in_txn_dir(hp2) ? "，本事务存档提交将被拒" : ""); if (in_txn_dir(hp2)) save_poison(e); }
        errno = e; return err_res("rename name", hp2); }
    return RES_OK;
}
HLE_FORCE("_ZN2nn2fs12GetEntryTypeEPNS0_18DirectoryEntryTypeEPKc", "fsp-srv → stat(2)", Result, h_fs_GetEntryType, int32_t *out, const char *path) {
    HP(path); struct stat st;
    if (stat(hp, &st)) return err_res("stat", hp);
    *out = S_ISDIR(st.st_mode) ? ENT_DIR : ENT_FILE; return RES_OK;
}

// ---------- Directories ----------
typedef struct { DIR *d; char path[1024]; DIR *od; char opath[1024]; DirectoryEntry *snap; int64_t nsnap, psnap; int mode; } dirh_t;
static void dir_snapshot(dirh_t *h, const mount_t *m, const char *rest) {
    char *roots = strdup(m->overlay);
    char (*names)[0x301] = calloc(2048, sizeof *names);
    const char **all = calloc(65, sizeof *all);
    char *parent = malloc(1024), *guest = malloc(0x301), *rel = malloc(2048), *resolved = malloc(1024);
    if (!roots || !names || !all || !parent || !guest || !rel || !resolved) die("rom overlay 目录快照分配失败");
    int nn = 0, nr = 0;
    all[nr++] = m->dir;
    char *save = NULL;
    for (char *root = strtok_r(roots, ":", &save); root && nr < 65; root = strtok_r(NULL, ":", &save)) all[nr++] = root;
    for (int ri = nr - 1; ri >= 0; ri--) {
        if (!root_path(all[ri], rest, parent, 1024)) continue;
        DIR *x = opendir(parent); if (!x) continue;
        struct dirent *e;
        while ((e = readdir(x))) {
            if (!strcmp(e->d_name, ".") || !strcmp(e->d_name, "..")) continue;
            { size_t dl = strlen(e->d_name); if (dl > 6 && !strcmp(e->d_name + dl - 6, ".holes")) continue; }   // The extent table is not shown to the game
            if (!guest_name(parent, e->d_name, guest, 0x301)) continue;
            int dup = 0; for (int j = 0; j < nn; j++) if (!strcmp(names[j], guest)) { dup = 1; break; }
            if (!dup && nn < 2048) strlcpy(names[nn++], guest, sizeof names[0]);
        }
        closedir(x);
    }
    h->snap = calloc(nn, sizeof *h->snap); h->nsnap = nn;
    if (nn && !h->snap) die("rom overlay 目录快照分配失败");
    for (int j = 0; j < nn; j++) {
        strlcpy(h->snap[j].name, names[j], sizeof h->snap[j].name);
        snprintf(rel, 2048, "%s/%s", rest, names[j]);
        if (!rom_overlay_path(m, rel, resolved, 1024)) continue;
        struct stat st;
        if (!stat(resolved, &st)) { h->snap[j].type = S_ISDIR(st.st_mode) ? ENT_DIR : ENT_FILE; h->snap[j].size = S_ISDIR(st.st_mode) ? 0 : dm_data_logical_size(resolved, st.st_size); }
    }
    free(resolved); free(rel); free(guest); free(parent); free(all); free(names); free(roots);
}
HLE_FORCE("_ZN2nn2fs13OpenDirectoryEPNS0_15DirectoryHandleEPKci", "fsp-srv → opendir(3)", Result, h_fs_OpenDirectory, uint64_t *out, const char *path, int mode) {
    HP(path); DIR *d = opendir(hp);
    if (!d) return err_res("opendir", hp);
    dirh_t *h = calloc(1, sizeof *h); h->d = d; strlcpy(h->path, hp, sizeof h->path); h->mode = mode;
    const char *c = strchr(path, ':');
    if (c) for (int i = 0; i < g_nmnt; i++) if (g_mnt[i].overlay[0] && strlen(g_mnt[i].name) == (size_t)(c - path) && !strncmp(g_mnt[i].name, path, (size_t)(c - path))) {
        dir_snapshot(h, &g_mnt[i], c + 1); break;
    }
    *out = (uint64_t)h; return RES_OK;
}
HLE_FORCE("_ZN2nn2fs13ReadDirectoryEPlPNS0_14DirectoryEntryENS0_15DirectoryHandleEl", "fsp-srv → readdir(3)", Result, h_fs_ReadDirectory, int64_t *count, DirectoryEntry *ents, uint64_t hh, int64_t max) {
    if (!hh) { *count = 0; return RES_FAIL; }
    PATH_LOCK(); dirh_t *h = (dirh_t *)hh; int64_t n = 0; struct dirent *e;
    if (h->snap) { while (n < max && h->psnap < h->nsnap) { DirectoryEntry *src = &h->snap[h->psnap++]; if (!(h->mode & (src->type == ENT_DIR ? DIRMODE_DIR : DIRMODE_FILE))) continue; ents[n++] = *src; } *count = n; return RES_OK; }
    int dfd = dirfd(h->d);
    while (n < max && (e = readdir(h->d))) {
        if (!strcmp(e->d_name, ".") || !strcmp(e->d_name, "..")) continue;
        { size_t dl = strlen(e->d_name); if (dl > 6 && !strcmp(e->d_name + dl - 6, ".holes")) continue; }   // The extent table is not shown to the game
        // a directory's type comes from d_type without stat; files need a size, taken with fstatat relative to the directory fd (following links, like the old stat)
        struct stat st; int isdir;
        if (e->d_type == DT_DIR) isdir = 1;
        else { if (fstatat(dfd, e->d_name, &st, 0)) continue; isdir = S_ISDIR(st.st_mode); }
        if (!(h->mode & (isdir ? DIRMODE_DIR : DIRMODE_FILE))) continue;
        DirectoryEntry *o = &ents[n++]; memset(o, 0, sizeof *o);
        if (!guest_name(h->path, e->d_name, o->name, sizeof o->name)) { char c[1280]; snprintf(c, sizeof c, "%s/%s", h->path, e->d_name); *count = n - 1; return err_res("directory name", c); }
        o->type = isdir ? ENT_DIR : ENT_FILE; o->size = isdir ? 0 : data_logical_size_at(dfd, e->d_name, st.st_size);
    }
    *count = n; return RES_OK;
}
HLE_FORCE("_ZN2nn2fs14CloseDirectoryENS0_15DirectoryHandleE", "fsp-srv → closedir(3)", void, h_fs_CloseDirectory, uint64_t hh) {
    if (!hh) return;   // the game also closes after a failed open (handle 0): nothing to do in the original either
    dirh_t *h = (dirh_t *)hh; closedir(h->d); if (h->od) closedir(h->od); free(h->snap); free(h);
}

// ---------- Overloads from newer SDKs (SDK 16: MountRom without a cache, ReadFile without the bytes-read output / with read options, directory entry count) ----------
HLE_FORCE("_ZN2nn2fs8MountRomEPKc", "fsp-srv；rom → 宿主 RomFS 目录（无缓存参数的重载）", Result, h_fs_MountRom1, const char *name) { return h_fs_MountRom(name, NULL, 0); }
// ReadFile without the bytes-read output: the read must be complete; a short read (past the end of file) is returned as a failure
HLE_FORCE("_ZN2nn2fs8ReadFileENS0_10FileHandleElPvm", "fsp-srv → pread(2)，须读满", Result, h_fs_ReadFileExact, uint64_t h, int64_t off, void *buf, size_t sz) {
    size_t got = 0; Result r = h_fs_ReadFile(&got, h, off, buf, sz);
    if (r != RES_OK) return r;
    if (got != sz) { LOG("fs ReadFile 读不满：fd %d 偏移 %lld 要 %zu 得 %zu", (int)h, (long long)off, sz, got); return RES_FAIL; }
    return RES_OK;
}
HLE_FORCE("_ZN2nn2fs8ReadFileEPmNS0_10FileHandleElPvmRKNS0_10ReadOptionE", "fsp-srv → pread(2)（带读选项的重载，选项宿主不用）", Result, h_fs_ReadFileOpt,
          size_t *out, uint64_t h, int64_t off, void *buf, size_t sz, const void *opt) { (void)opt; return h_fs_ReadFile(out, h, off, buf, sz); }
HLE_FORCE("_ZN2nn2fs22GetDirectoryEntryCountEPlNS0_15DirectoryHandleE", "fsp-srv；目录项计数（按打开时的模式过滤，不动读位置）", Result, h_fs_DirCount, int64_t *out, uint64_t hh) {
    PATH_LOCK(); dirh_t *h = (dirh_t *)hh; int64_t n = 0;
    if (h->snap) { for (int64_t i = 0; i < h->nsnap; i++) if (h->mode & (h->snap[i].type == ENT_DIR ? DIRMODE_DIR : DIRMODE_FILE)) n++; *out = n; return RES_OK; }
    DIR *d = opendir(h->path); if (!d) return err_res("opendir", h->path);
    struct dirent *e;
    while ((e = readdir(d))) {
        if (!strcmp(e->d_name, ".") || !strcmp(e->d_name, "..")) continue;
        { size_t dl = strlen(e->d_name); if (dl > 6 && !strcmp(e->d_name + dl - 6, ".holes")) continue; }
        char c[1280]; snprintf(c, sizeof c, "%s/%s", h->path, e->d_name);
        struct stat st; if (stat(c, &st)) continue;
        if (h->mode & (S_ISDIR(st.st_mode) ? DIRMODE_DIR : DIRMODE_FILE)) n++;
    }
    closedir(d); *out = n; return RES_OK;
}
// Whether save data exists: the host's save directory is created at mount time, so from the game's point of view it always exists (EnsureSaveData always succeeds too)
HLE_FORCE("_ZN2nn2fs18IsSaveDataExistingERKNS_7account3UidE", "fsp-srv；存档恒已建（返回 bool）", unsigned, h_fs_SaveExists, const void *uid) { (void)uid; return 1; }
// File system access log and thread priority: on the real device both ask fsp-srv (the access log switch lives in the service); the host has no access log and priority does not affect pread
HLE_FORCE("_ZN2nn2fs26SetPriorityOnCurrentThreadENS0_8PriorityE", "fsp-srv；文件读优先级，宿主忽略", void, h_fs_SetPrio, int prio) { (void)prio; }
HLE_FORCE("_ZN2nn2fs6detail18IsEnabledAccessLogEj", "fsp-srv；访问日志恒关（返回 bool）", unsigned, h_fs_AccessLogMask, unsigned mask) { (void)mask; return 0; }
HLE_FORCE("_ZN2nn2fs6detail18IsEnabledAccessLogEv", "fsp-srv；访问日志恒关（返回 bool）", unsigned, h_fs_AccessLog, void) { return 0; }
