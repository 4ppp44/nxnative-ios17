// Real Metal regression for feedback snapshot selection and indirect declarations.
// Synthetic resources; this is not a reproduction of the user's A16 scene.
#include "../nvn/nvn_mtl.m"
int prog_key(const prog_t *p, unsigned s, uint8_t key[8]) { memset(key, 0, 8); return 0; }
void *front_metal_layer(void) { return NULL; }
module_t *module_of(const void *p) { return NULL; }
module_t g_mod[MAX_MOD]; int g_nmod;
void svc_thread_dump(void) {}
uint64_t now_ns(void) { return bp_now(); }
static int checks, failures;
#define CHECK(v) do { checks++; if (!(v)) { failures++; fprintf(stderr,"FAIL %d: %s\n",__LINE__,#v); } } while (0)
static void clear_texture(id<MTLTexture> t, double r, double g, double b) {
    if (g_blit) { enc_b_end(g_blit); g_blit = nil; }
    MTLRenderPassDescriptor *d = [MTLRenderPassDescriptor new];
    d.colorAttachments[0].texture = t; d.colorAttachments[0].loadAction = MTLLoadActionClear;
    d.colorAttachments[0].storeAction = MTLStoreActionStore;
    d.colorAttachments[0].clearColor = MTLClearColorMake(r,g,b,1);
    enc_r_end(enc_r_begin(d));
}
int main(void) { @autoreleasepool {
    setenv("DM_NVN_FB_SNAP","a7e5c6fd501cf21f",1);
    mtl_init(); NSError *error = nil;
    NSString *source = @"#include <metal_stdlib>\nusing namespace metal; struct A { texture2d<float> t [[id(0)]]; }; vertex float4 v(uint i[[vertex_id]]) { float2 p[3]={float2(-1,-1),float2(3,-1),float2(-1,3)}; return float4(p[i],0,1); } fragment float4 f(constant A& a[[buffer(0)]]) { return a.t.read(uint2(0)); }";
    id<MTLLibrary> lib = [g_dev newLibraryWithSource:source options:nil error:&error]; CHECK(lib != nil);
    NvShader *fs = [NvShader new]; strcpy(fs->key,"a7e5c6fd501cf21f_b"); fs->stage = 1;
    fs->fn = [lib newFunctionWithName:@"f"]; fs->ae = [fs->fn newArgumentEncoderWithBufferIndex:0];
    fs->rf.nb = 1; fs->rf.b[0] = (nvn_rbind){.kind=NVN_RB_TEX,.reg=0,.aid=0,.dtt=MTLTextureType2D};
    NvProg *pr = [NvProg new]; pr->sh[1] = fs;
    MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new]; pd.vertexFunction=[lib newFunctionWithName:@"v"];pd.fragmentFunction=fs->fn;
    pd.colorAttachments[0].pixelFormat=MTLPixelFormatRGBA8Unorm;
    id<MTLRenderPipelineState> pipeline=[g_dev newRenderPipelineStateWithDescriptor:pd error:&error];CHECK(pipeline != nil);
    void *handles = NULL; CHECK(!posix_memalign(&handles,getpagesize(),getpagesize())); memset(handles,0,getpagesize());
    ((uint32_t *)handles)[0] = 17; mtl_pool_add(handles,getpagesize());
    for (int bindless=0;bindless<2;bindless++) for (int float_target=0;float_target<2;float_target++) {
        tex_t t={.magic=MAGIC('T','E','X',0),.serial=(uint64_t)(81000+2*bindless+float_target)};
        t.d.target=NVN_TEXTURE_TARGET_2D;t.d.width=t.d.height=8;t.d.depth=t.d.levels=t.d.samples=1;
        t.d.format=float_target ? NVN_FORMAT_R11G11B10F : NVN_FORMAT_RGBA8;
        MTLTextureDescriptor *td=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:float_target ? MTLPixelFormatRG11B10Float : MTLPixelFormatRGBA8Unorm width:8 height:8 mipmapped:NO];
        td.usage=MTLTextureUsageShaderRead|MTLTextureUsageRenderTarget;td.storageMode=MTLStorageModePrivate;
        id<MTLTexture> base=[g_dev newTextureWithDescriptor:td];CHECK(base != nil);res_add(base);serial_put(t.serial,base);mtl_reg_tex(17,&t,NULL);
        td.pixelFormat=MTLPixelFormatRGBA8Unorm;id<MTLTexture> output=[g_dev newTextureWithDescriptor:td];res_add(output);
        fs->rf.b[0].kind=bindless ? NVN_RB_TEXU : NVN_RB_TEX;fs->rf.b[0].reg=bindless ? 1 : 0;
        ((uint32_t *)handles)[0]=17;
        fprintf(stderr,"CASE bindless=%d float=%d\n",bindless,float_target);
        S.tex[1][0]=17;S.ubo[1][1]=(p_bind_buf){.addr=(uint64_t)handles,.size=4};
        memset(&R.rt,0,sizeof R.rt);R.rt.n=1;R.rt.color[0]=&t;
        mtl_sub_begin();clear_texture(base,1,0,0);fb_prepare(pr);CHECK(g_fb_n==1);
        clear_texture(base,0,0,1); // The sample must still read the earlier red snapshot.
        if(g_blit){enc_b_end(g_blit);g_blit=nil;}
        MTLRenderPassDescriptor *rp=[MTLRenderPassDescriptor new];rp.colorAttachments[0].texture=output;rp.colorAttachments[0].loadAction=MTLLoadActionClear;rp.colorAttachments[0].storeAction=MTLStoreActionStore;
        id<MTLRenderCommandEncoder> e=enc_r_begin(rp);enc_r_pso(e,pipeline);g_pass.serial++;
        args_dirty_all();CHECK(encode_args(e,fs,1,0));
        uint64_t calls=g_legacy_use_calls, skipped=g_legacy_use_skipped;
        for(int i=0;i<100;i++) legacy_use_resource(e,g_fb_use[0],MTLResourceUsageRead,0);
        BOOL dedup = !getenv("DM_NVN_USE_DEDUP") || strcmp(getenv("DM_NVN_USE_DEDUP"),"0");
        CHECK(g_legacy_use_calls==calls+(dedup ? 0 : 100));CHECK(g_legacy_use_skipped==skipped+(dedup ? 100 : 0));
        enc_r_draw(e,MTLPrimitiveTypeTriangle,0,3);enc_r_end(e);
        id<MTLBuffer> rb=[g_dev newBufferWithLength:256 options:MTLResourceStorageModeShared];res_add(rb);
        enc_b_copy_texture_buffer(blit(),output,0,0,MTLOriginMake(0,0,0),MTLSizeMake(8,8,1),rb,0,32,256);
        CHECK(mtl_wait(mtl_sub_commit(),5000000000ull));CHECK(!mtl_last_commit_error());
        for(int i=0;i<64;i++) CHECK(((uint32_t *)rb.contents)[i]==0xff0000ff);
        // A new encoder must declare the same resource again.
        mtl_sub_begin();id<MTLRenderCommandEncoder> e2=enc_r_begin(rp);calls=g_legacy_use_calls;
        legacy_use_resource(e2,g_fb_use[0],MTLResourceUsageRead,0);CHECK(g_legacy_use_calls==calls+1);
        legacy_use_resource(e2,g_fb_use[0],MTLResourceUsageRead|MTLResourceUsageWrite,0);CHECK(g_legacy_use_calls==calls+2);
        enc_r_end(e2);CHECK(mtl_wait(mtl_sub_commit(),5000000000ull));
        // An unbound feedback slot must produce no snapshot.
        S.tex[1][0]=0;((uint32_t *)handles)[0]=0;fb_prepare(pr);CHECK(g_fb_n==0);
    }
    mtl_pool_del(handles);free(handles);
    printf("IOS17_FEEDBACK_REAL_METAL checks=%d failures=%d use_calls=%llu use_skipped=%llu\n",checks,failures,g_legacy_use_calls,g_legacy_use_skipped);
    return failures != 0;
} }
