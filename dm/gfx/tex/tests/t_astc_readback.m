// Real Metal sampling of offline ASTC blocks; output floats for an independent
// astcenc decoder comparison. Not a game scene or an A16 device test.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
int main(int argc,char **argv) { @autoreleasepool {
    if (argc!=4) return 2;
    NSData *input=[NSData dataWithContentsOfFile:@(argv[1])];const unsigned char *b=input.bytes;
    if (input.length<16 || memcmp(b,"\x13\xab\xa1\x5c",4) || memcmp(b+4,"\x04\x04\x01",3)) return 3;
    unsigned w=b[7]|b[8]<<8|b[9]<<16,h=b[10]|b[11]<<8|b[12]<<16;
    id<MTLDevice> dev=MTLCreateSystemDefaultDevice();
    MTLTextureDescriptor *d=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:atoi(argv[3]) ? MTLPixelFormatASTC_4x4_sRGB : MTLPixelFormatASTC_4x4_LDR width:w height:h mipmapped:NO];
    d.storageMode=MTLStorageModeShared;d.usage=MTLTextureUsageShaderRead;
    id<MTLTexture> t=[dev newTextureWithDescriptor:d];if (!t) return 4;
    [t replaceRegion:MTLRegionMake2D(0,0,w,h) mipmapLevel:0 withBytes:b+16 bytesPerRow:((w+3)/4)*16];
    NSError *error=nil;
    id<MTLLibrary> lib=[dev newLibraryWithSource:@"#include <metal_stdlib>\nusing namespace metal;kernel void read_astc(texture2d<float> t [[texture(0)]],device float4 *o [[buffer(0)]],uint2 p [[thread_position_in_grid]]) { if (p.x>=t.get_width() || p.y>=t.get_height()) return; constexpr sampler s(coord::pixel,filter::nearest,address::clamp_to_edge);o[p.y*t.get_width()+p.x]=t.sample(s,float2(p)+0.5); }" options:nil error:&error];
    if (!lib) { fprintf(stderr,"%s\n",error.description.UTF8String);return 5; }
    id<MTLComputePipelineState> ps=[dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"read_astc"] error:&error];if (!ps) return 6;
    id<MTLBuffer> out=[dev newBufferWithLength:(NSUInteger)w*h*16 options:MTLResourceStorageModeShared];
    id<MTLCommandQueue> q=[dev newCommandQueue];id<MTLCommandBuffer> cb=[q commandBuffer];id<MTLComputeCommandEncoder> e=[cb computeCommandEncoder];
    [e setComputePipelineState:ps];[e setTexture:t atIndex:0];[e setBuffer:out offset:0 atIndex:0];
    [e dispatchThreads:MTLSizeMake(w,h,1) threadsPerThreadgroup:MTLSizeMake(8,8,1)];[e endEncoding];[cb commit];[cb waitUntilCompleted];
    if (cb.error) return 7;
    if (![[NSData dataWithBytes:out.contents length:out.length] writeToFile:@(argv[2]) atomically:YES]) return 8;
    fprintf(stderr,"GPU=%s ASTC4x4%s %ux%u\n",dev.name.UTF8String,atoi(argv[3]) ? "_sRGB" : "_linear",w,h);return 0;
} }
