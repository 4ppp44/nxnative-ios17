// Validate a separately delivered, build-matched overlay before exposing it to
// the guest filesystem. A missing/corrupt pack falls back to original resources.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <CommonCrypto/CommonDigest.h>
#include <stdio.h>
#include <stdlib.h>

static NSString *g_validated_pack;
BOOL dm_a16_pack_available(void) { return g_validated_pack != nil; }
void dm_a16_pack_set_enabled(BOOL enabled);
static NSString *g_pack_message = @"原版贴图 / Original textures";
NSString *dm_a16_pack_message(void) { return g_pack_message; }
static NSString *hex_digest(const unsigned char digest[CC_SHA256_DIGEST_LENGTH]) {
    char s[CC_SHA256_DIGEST_LENGTH*2+1];
    for (unsigned i=0;i<CC_SHA256_DIGEST_LENGTH;i++) snprintf(s+i*2,3,"%02x",digest[i]);
    return @(s);
}
static NSString *data_digest(NSData *data) {
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];CC_SHA256(data.bytes,(CC_LONG)data.length,digest);return hex_digest(digest);
}
static BOOL check_file(NSString *path, NSNumber *size, NSString *hash) {
    NSDictionary *a=[NSFileManager.defaultManager attributesOfItemAtPath:path error:nil];
    if (![a[NSFileType] isEqualToString:NSFileTypeRegular] || [a[NSFileSize] unsignedLongLongValue]!=size.unsignedLongLongValue) return NO;
    FILE *f=fopen(path.fileSystemRepresentation,"rb");if (!f) return NO;
    CC_SHA256_CTX ctx;CC_SHA256_Init(&ctx);unsigned char b[65536],digest[CC_SHA256_DIGEST_LENGTH];size_t n;
    while ((n=fread(b,1,sizeof b,f))) CC_SHA256_Update(&ctx,b,(CC_LONG)n);
    BOOL ok=!ferror(f);fclose(f);CC_SHA256_Final(digest,&ctx);
    return ok && [hex_digest(digest) isEqualToString:hash];
}
static BOOL safe_relative(NSString *p) {
    return [p isKindOfClass:NSString.class] && p.length && !p.isAbsolutePath &&
        ![p.pathComponents containsObject:@".."] && ![p.pathComponents containsObject:@"."];
}
void dm_a16_pack_prepare(NSString *doc, NSString *res, NSString *romfs) {
    if ([MTLCreateSystemDefaultDevice() supportsBCTextureCompression]) return;
    const char *disable=getenv("DM_A16_OVERLAY");
    if (disable && !strcmp(disable,"0")) { g_pack_message=@"原版贴图（手动选择） / Original textures";return; }
    NSString *descriptor=[res stringByAppendingPathComponent:@"dm/a16_texture_pack.json"];
    NSData *trustedData=[NSData dataWithContentsOfFile:descriptor];
    if (!trustedData) { g_pack_message=@"未配置贴图优化包 / No texture overlay configured";return; }
    NSDictionary *trusted=[NSJSONSerialization JSONObjectWithData:trustedData options:0 error:nil];
    NSString *root=[doc stringByAppendingPathComponent:@"romfs_a16"];
    NSData *raw=[NSData dataWithContentsOfFile:[root stringByAppendingPathComponent:@"pack.json"]];
    if (!raw) { g_pack_message=@"可导入 A16 贴图补充包 / A16 texture pack available";fprintf(stderr,"boot: A16补充包未导入，保留原版解压路径\n");return; }
    if (![trusted isKindOfClass:NSDictionary.class] || ![data_digest(raw) isEqualToString:trusted[@"manifest_sha256"]]) {
        g_pack_message=@"贴图补充包不匹配 / Texture pack mismatch";fprintf(stderr,"boot: 【红】A16补充包索引与本构建不匹配，保留原版\n");return;
    }
    NSDictionary *manifest=[NSJSONSerialization JSONObjectWithData:raw options:0 error:nil];
    NSArray *files=manifest[@"files"];
    if (![manifest isKindOfClass:NSDictionary.class] || ![files isKindOfClass:NSArray.class] || files.count!=[trusted[@"files"] unsignedIntegerValue]) return;
    for (NSDictionary *entry in files) {
        NSString *rel=entry[@"path"];
        if (!safe_relative(rel) || !check_file([root stringByAppendingPathComponent:rel],entry[@"bytes"],entry[@"sha256"]) ||
            !check_file([romfs stringByAppendingPathComponent:rel],entry[@"source_bytes"],entry[@"source_sha256"])) {
            g_pack_message=@"贴图补充包校验失败 / Texture pack verification failed";
            fprintf(stderr,"boot: 【红】A16补充包或对应原资源校验失败：%s；保留原版\n",rel.UTF8String);return;
        }
    }
    g_validated_pack = root;
    id preference = [NSUserDefaults.standardUserDefaults objectForKey:@"NXUseA16Overlay"];
    dm_a16_pack_set_enabled(!preference || [preference boolValue]);
    fprintf(stderr,"boot: A16补充包已核验：%lu 文件，%s 个转换实例（既有ASTC/SNORM/HDR保留）\n",
        (unsigned long)files.count,[trusted[@"texture_instances"] description].UTF8String);
}

// Only a previously hash-verified directory can be enabled. Toggle before nnMain.
void dm_a16_pack_set_enabled(BOOL enabled) {
    if (!g_validated_pack) return;
    if (enabled) {
        setenv("DM_ROMFS_OVERLAY",g_validated_pack.fileSystemRepresentation,1);
        g_pack_message=@"A16 贴图补充包已启用 / A16 texture pack enabled";
    } else {
        unsetenv("DM_ROMFS_OVERLAY");
        g_pack_message=@"原版贴图（已保留补充包） / Original textures";
    }
    fprintf(stderr,"boot: A16补充包选择 %s\n",enabled ? "on" : "off");
}
