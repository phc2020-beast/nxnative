// Memory pools the GPU stops addressing leave the residency set (nvn_mtl.m pool_age): a pool a copy used goes after POOL_AGE_IDLE submissions with no lookup, comes back
// at its next use with the copy's literal bytes, and a pinned pool (a texture made on its buffer) stays. Runs with Metal validation, which reports a non-resident buffer the GPU reads
#define nvn_game_fps nvn_game_fps_mtl_default
#include "../nvn/nvn_mtl.m"
#undef nvn_game_fps
#define g_ft g_ft_hle
#include "../nvn/hle_nvn.c"
#undef g_ft
uint64_t g_t0_ns;
void *front_metal_layer(void) { return NULL; }
module_t *module_of(const void *p) { (void)p; return NULL; }
module_t *g_mod; int g_nmod;
void svc_thread_dump(void) {}
uint64_t now_ns(void) { return bp_now(); }
static int cases, failed;
#define EXPECT(n,w,v) do { int a=(w), b=(v); cases++; printf("%s expected %d -> got %d %s\n",n,a,b,a==b?"PASS":"FAIL"); failed+=a!=b; } while (0)

static int resident(const void *mem) { pthread_mutex_lock(&g_mu); int i = pool_find((uint64_t)(uintptr_t)mem, 1), r = i >= 0 && g_pools[i].res; pthread_mutex_unlock(&g_mu); return r; }
static void *pool_mem(size_t n) { void *m = NULL; if (posix_memalign(&m, getpagesize(), n)) abort(); memset(m, 0, n); return m; }
// One submission: copy 16 bytes from src to dst, with the command memory in cmd_mem
static void copy_sub(void *cmd_mem, const uint8_t *src, uint8_t *dst) {
    pool_t pool = {.mem=cmd_mem, .size=65536};
    NVNcommandBuffer cmd; h_nvnCommandBufferInitialize(&cmd, NULL);
    h_nvnCommandBufferAddCommandMemory(&cmd, (const NVNmemoryPool *)&pool, 0, 65536);
    h_nvnCommandBufferBeginRecording(&cmd);
    h_nvnCommandBufferCopyBufferToBuffer(&cmd, (NVNbufferAddress)src, (NVNbufferAddress)dst, 16, 0);
    NVNsync sync; h_nvnSyncInitialize(&sync, NULL);
    h_nvnCommandBufferFenceSync(&cmd, &sync, NVN_SYNC_CONDITION_ALL_GPU_COMMANDS_COMPLETE, 0);
    NVNcommandHandle h = h_nvnCommandBufferEndRecording(&cmd);
    state_reset(); memset(&R, 0, sizeof R); mtl_sub_begin(); mtl_exec((const uint8_t *)h); mtl_sub_commit();
    h_nvnSyncWait(&sync, 5000000000ull);
}
static void empty_subs(int n) { for (int i = 0; i < n; i++) { mtl_sub_begin(); mtl_sub_commit(); mtl_wait_at(atomic_load(&g_fence), UINT64_MAX, WS_SYNC); } }

int main(void) { @autoreleasepool {
    setenv("DM_NVN_POOL_UNWIRE", "1", 1);
    mtl_init();
    uint8_t *ps = pool_mem(65536), *pd = pool_mem(65536), *pp = pool_mem(65536), *cmd = pool_mem(65536);
    mtl_pool_add(ps, 65536); mtl_pool_add(pd, 65536); mtl_pool_add(pp, 65536); mtl_pool_add(cmd, 65536);
    for (int i = 0; i < 16; i++) ps[i] = (uint8_t)(i * 7 + 1);
    copy_sub(cmd, ps, pd);
    EXPECT("first copy: literal bytes", 0, memcmp(ps, pd, 16));
    void *mb; uint64_t mo; mtl_addr((uint64_t)(uintptr_t)pp, 16, &mb, &mo); pool_pin_at(pp);   // as a linear or buffer texture on its buffer does
    EXPECT("source pool resident after the copy", 1, resident(ps));
    EXPECT("destination pool resident after the copy", 1, resident(pd));
    EXPECT("pinned pool resident", 1, resident(pp));
    empty_subs(POOL_AGE_EVERY + POOL_AGE_IDLE + 8);
    EXPECT("source pool out of the residency set when no submission addressed it", 0, resident(ps));
    EXPECT("destination pool out of the residency set when no submission addressed it", 0, resident(pd));
    EXPECT("pinned pool stays", 1, resident(pp));
    EXPECT("pools counted as taken out", 1, g_pool_aged_n >= 2);
    for (int i = 0; i < 16; i++) ps[i] = (uint8_t)(200 - i * 3);
    copy_sub(cmd, ps, pd);
    EXPECT("copy after they left: literal bytes", 0, memcmp(ps, pd, 16));
    EXPECT("source pool back in the residency set", 1, resident(ps));
    EXPECT("destination pool back in the residency set", 1, resident(pd));
    EXPECT("pools counted as addressed again", 1, g_pool_rewired_n >= 2);
    EXPECT("GPU success", 0, mtl_last_commit_error());
    printf("POOL AGE cases=%d failed=%d\n", cases, failed); return failed != 0;
} }
