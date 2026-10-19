// Exercises the production legacy backend on real Metal with synthetic inputs.
#include "../nvn/nvn_mtl.m"
int prog_key(const prog_t *p, unsigned s, uint8_t key[8]) { memset(key, 0, 8); return 0; }
void *front_metal_layer(void) { return NULL; }
module_t *module_of(const void *p) { return NULL; }
module_t g_mod[MAX_MOD]; int g_nmod;
void svc_thread_dump(void) {}
uint64_t now_ns(void) { return bp_now(); }
static int checks, failures;
#define CHECK(v) do { checks++; if (!(v)) { failures++; fprintf(stderr,"FAIL line %d: %s\n",__LINE__,#v); } } while (0)
int main(void) { @autoreleasepool {
    mtl_init();
    CHECK(g_q && g_present_uv[0] && g_bloomq_const[2]);
    NSMutableArray *buffers = [NSMutableArray array];
    for (int i = 0; i < 700; i++) {
        id<MTLBuffer> b = [g_dev newBufferWithLength:256 options:MTLResourceStorageModeShared];
        CHECK(b != nil); res_add(b); res_add(b); [buffers addObject:b];
        NSUInteger off; CHECK(legacy_buffer_at(b.gpuAddress + 127, &off) == b && off == 127);
    }
    CHECK(g_legacy_count == 706); // six permanent present/bloom buffers
    for (id<MTLBuffer> b in buffers) res_remove(b);
    CHECK(g_legacy_count == 6);
    NSUInteger off; CHECK(legacy_buffer_at(0, &off) == nil && off == 0);
    NSError *error = nil;
    NSString *msl = @"#include <metal_stdlib>\nusing namespace metal;\nkernel void add(device const uint* a[[buffer(0)]], device uint* b[[buffer(1)]], uint i[[thread_position_in_grid]]) { b[i] = a[i] + 3; }\nvertex float4 v(uint i[[vertex_id]]) { float2 p[3]={float2(-1,-1),float2(3,-1),float2(-1,3)}; return float4(p[i],0,1); }\nfragment float4 f() { return float4(1,0,0,1); }\n";
    id<MTLLibrary> lib = [g_dev newLibraryWithSource:msl options:nil error:&error]; CHECK(lib != nil);
    id<MTLComputePipelineState> cp = [g_dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"add"] error:&error]; CHECK(cp != nil);
    id<MTLBuffer> seed = [g_dev newBufferWithLength:256 options:MTLResourceStorageModeShared];
    id<MTLBuffer> a = [g_dev newBufferWithLength:256 options:MTLResourceStorageModeShared];
    id<MTLBuffer> b = [g_dev newBufferWithLength:256 options:MTLResourceStorageModeShared];
    res_add(seed); res_add(a); res_add(b);
    for (unsigned i=0;i<64;i++) ((uint32_t*)seed.contents)[i]=i;
    MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new]; pd.vertexFunction=[lib newFunctionWithName:@"v"];pd.fragmentFunction=[lib newFunctionWithName:@"f"];pd.colorAttachments[0].pixelFormat=MTLPixelFormatRGBA8Unorm;
    id<MTLRenderPipelineState> rpso=[g_dev newRenderPipelineStateWithDescriptor:pd error:&error];CHECK(rpso != nil);
    MTLTextureDescriptor *td=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:8 height:8 mipmapped:NO];td.storageMode=MTLStorageModeShared;td.usage=MTLTextureUsageRenderTarget|MTLTextureUsageShaderRead;
    id<MTLTexture> tex=[g_dev newTextureWithDescriptor:td];res_add(tex);
    for (unsigned n=0;n<8;n++) {
        mtl_sub_begin();
        enc_b_copy_buffer(blit(),seed,0,a,0,256);enc_b_end(g_blit);g_blit=nil;
        id<MTLComputeCommandEncoder> ce=enc_c_begin(NULL);enc_c_pso(ce,cp);
        enc_c_args(ce,a.gpuAddress,0);enc_c_args(ce,b.gpuAddress,1);
        enc_c_dispatch(ce,MTLSizeMake(2,1,1),MTLSizeMake(32,1,1));enc_c_end(ce);
        MTLRenderPassDescriptor *rp=[MTLRenderPassDescriptor new];rp.colorAttachments[0].texture=tex;rp.colorAttachments[0].loadAction=MTLLoadActionClear;rp.colorAttachments[0].storeAction=MTLStoreActionStore;
        id<MTLRenderCommandEncoder> re=enc_r_begin(rp);enc_r_pso(re,rpso);enc_r_draw(re,MTLPrimitiveTypeTriangle,0,3);enc_r_end(re);
        // Force one segmented submission, keeping the final fence on the tail.
        sub_cut();g_stat_draw+=64;sub_cut();
        enc_b_copy_texture_buffer(blit(),tex,0,0,MTLOriginMake(0,0,0),MTLSizeMake(8,8,1),a,0,32,256);
        CHECK(mtl_wait(mtl_sub_commit(),5000000000ull));CHECK(!mtl_last_commit_error());
        for(unsigned i=0;i<64;i++) { CHECK(((uint32_t*)b.contents)[i]==i+3); CHECK(((uint32_t*)a.contents)[i]==0xff0000ff); }
    }
    CHECK(g_cuts>=8);
    id<MTLLibrary> ilib=[g_dev newLibraryWithSource:@"#include <metal_stdlib>\nusing namespace metal; struct A { device const uint* a [[id(0)]]; device uint* b [[id(1)]]; }; kernel void indirect(constant A& x [[buffer(0)]], uint i [[thread_position_in_grid]]) { x.b[i]=x.a[i]*7; }" options:nil error:&error];
    CHECK(ilib != nil);
    NvShader *sh=[NvShader new];sh->fn=[ilib newFunctionWithName:@"indirect"];sh->ae=[sh->fn newArgumentEncoderWithBufferIndex:0];sh->stage=5;
    sh->rf.nb=2;sh->rf.b[0]=(nvn_rbind){.kind=NVN_RB_UBOP,.reg=0,.aid=0};sh->rf.b[1]=(nvn_rbind){.kind=NVN_RB_SBUFP,.reg=1,.aid=1,.rw=1};
    id<MTLComputePipelineState> ips=[g_dev newComputePipelineStateWithFunction:sh->fn error:&error];CHECK(ips != nil);
    uint32_t *in=NULL,*out=NULL;CHECK(!posix_memalign((void**)&in,getpagesize(),getpagesize()));CHECK(!posix_memalign((void**)&out,getpagesize(),getpagesize()));
    for(int i=0;i<64;i++){in[i]=i+9;out[i]=0;}
    mtl_pool_add(in,getpagesize());mtl_pool_add(out,getpagesize());
    S.ubo[5][0]=(p_bind_buf){.addr=(uint64_t)in,.size=256};S.ssbo[5][1]=(p_bind_buf){.addr=(uint64_t)out,.size=256};
    mtl_sub_begin();id<MTLComputeCommandEncoder> ie=enc_c_begin(NULL);enc_c_pso(ie,ips);
    CHECK(encode_args(ie,sh,5,0));enc_c_dispatch(ie,MTLSizeMake(2,1,1),MTLSizeMake(32,1,1));enc_c_end(ie);
    CHECK(mtl_wait(mtl_sub_commit(),5000000000ull));CHECK(!mtl_last_commit_error());
    for(int i=0;i<64;i++)CHECK(out[i]==(i+9)*7);
    mtl_pool_del(in);mtl_pool_del(out);free(in);free(out);

    printf("IOS17_BACKEND_REAL_METAL checks=%d failures=%d\n",checks,failures);
    return failures!=0;
} }
