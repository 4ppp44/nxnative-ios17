// Isolated host pipeline creation/archive I/O. No game data, draw or dispatch.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include "../nvn/nvn_pipeline_cache.h"
#include <assert.h>
#include <sys/stat.h>
int main(int argc, const char **argv) { @autoreleasepool {
    id<MTLDevice> device = MTLCreateSystemDefaultDevice(); assert(device);
    NSError *error = nil;
    NSString *source = @"#include <metal_stdlib>\nusing namespace metal;\n"
        "vertex float4 v(uint i [[vertex_id]]) { return float4(float(i),0,0,1); }\n"
        "fragment float4 f() { return float4(1,0,0,1); }\n"
        "kernel void c(device uint *p [[buffer(0)]], uint i [[thread_position_in_grid]]) { p[i]=i; }\n"
        "kernel void c2(device uint *p [[buffer(0)]], uint i [[thread_position_in_grid]]) { p[i]=i+1; }\n";
    id<MTLLibrary> library = [device newLibraryWithSource:source options:nil error:&error]; assert(library);
    MTLRenderPipelineDescriptor *d = [MTLRenderPipelineDescriptor new];
    d.vertexFunction = [library newFunctionWithName:@"v"]; d.fragmentFunction = [library newFunctionWithName:@"f"];
    d.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
    assert(nvn_cached_render(device, d, &error)); assert(d.binaryArchives == nil);
    assert(nvn_cached_compute(device, [library newFunctionWithName:@"c"], &error));
    nvn_cache_flush();
    if (argc > 1 && !strcmp(argv[1], "write-failure")) {
        NSString *root = @(getenv("DM_PIPELINE_CACHE_DIR"));
        NSDirectoryEnumerator *paths = [NSFileManager.defaultManager enumeratorAtPath:root]; NSString *name;
        NSMutableArray *blocked = [NSMutableArray array];
        while ((name = paths.nextObject)) if ([name hasSuffix:@"pipelines.metalarc"]) {
            NSString *dir = [root stringByAppendingPathComponent:name].stringByDeletingLastPathComponent;
            assert(!chmod(dir.fileSystemRepresentation, 0500)); [blocked addObject:dir];
        }
        assert(nvn_cached_compute(device, [library newFunctionWithName:@"c2"], &error));
        nvn_cache_flush();
        for (NSString *dir in blocked) assert(!chmod(dir.fileSystemRepresentation, 0700));
    }
    if (argc > 1 && !strcmp(argv[1], "parallel")) {
        dispatch_apply(16, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0), ^(size_t i) {
            (void)i; NSError *e = nil; assert(nvn_cached_compute(device, [library newFunctionWithName:@"c2"], &e));
        });
        nvn_cache_flush();
    }
    nvn_cache_status s; nvn_cache_snapshot(&s);
    printf("{\"loaded\":%d,\"hits\":%llu,\"misses\":%llu,\"added\":%llu,\"saved\":%llu,\"bypassed\":%llu,\"write_failed\":%d,\"disabled\":%d}\n",
        s.loaded, s.hits, s.misses, s.added, s.saved, s.bypassed, s.write_failed, s.disabled);
    return 0;
} }
