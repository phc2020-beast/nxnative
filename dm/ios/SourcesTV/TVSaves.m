// Saves on Apple TV. tvOS keeps almost nothing an app writes: Documents cannot be written, and Library/Caches, where the game's files and saves live, can be purged while the app is not running.
// Its preferences do stay. The host's save sync (dm/host/save_sync.h) sends each save there as if they were a cloud folder, a few seconds after each save, and brings it back by itself when the folder
// in Library/Caches comes up empty. The host still packs, checks, decides and keeps backups; this moves the one file.
// LZFSE, for speed: Animal Crossing: New Horizons' island is 24 MB of encrypted files that nothing shrinks, and LZMA spent 3.6 s on it on an Apple M6 (longer on the A15) for no gain, while the app
// was closed 7 s after the save and the copy never landed; LZFSE takes 66 ms. Super Mario Odyssey's 2 MB File1.bin, 98% zeros, packs to 20 KB (9 KB with LZMA). Saves stored as "DMZ1" are LZMA.
// NSUserDefaults abort() the app past about 1 MB in all (measured on an A15, tvOS 27.2), so a save that would pass STORE_LIMIT goes to a plain file in Library/Preferences beside them instead.
// Deleting the app deletes these too: TVPort keeps another copy on the Mac. This replaces SaveSync.m and CloudSaves.m, which need iCloud Drive, and a free Apple ID has no iCloud.
#import <Foundation/Foundation.h>
#include <compression.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "save_sync.h"

#define STORE_LIMIT (900 * 1024)
#define HEADER 12   // "DMZ2" (LZFSE) or "DMZ1" (LZMA, before), then the packed save's size as a little-endian u64
static NSString *const PREFIX = @"dmsave:";

// <folder>/tv-saves/<player>/<title ID>/save.dmsync → a name that outlives the app's container, whose path changes with each install
static NSString *store_key(const char *cloud) {
    NSString *path = @(cloud);
    NSRange at = [path rangeOfString:@"/tv-saves/"];
    return [PREFIX stringByAppendingString:at.location == NSNotFound ? path.lastPathComponent : [path substringFromIndex:NSMaxRange(at)]];
}
static NSString *spill_path(NSString *key) {
    NSString *name = [[key substringFromIndex:PREFIX.length] stringByReplacingOccurrencesOfString:@"/" withString:@"_"];
    NSString *library = NSSearchPathForDirectoriesInDomains(NSLibraryDirectory, NSUserDomainMask, YES).firstObject;
    return [[library stringByAppendingPathComponent:@"Preferences/tv-saves"] stringByAppendingPathComponent:name];
}
static NSUInteger others_size(NSUserDefaults *d, NSString *key) {
    NSUInteger total = 0;
    NSDictionary *all = d.dictionaryRepresentation;
    for (NSString *k in all) if ([k hasPrefix:PREFIX] && ![k isEqualToString:key]) total += [all[k] length];
    return total;
}

int front_save_sync_store(const char *local, const char *cloud) {
    @autoreleasepool {
        NSData *raw = [NSData dataWithContentsOfFile:@(local)];
        if (!raw.length) { fprintf(stderr, "[dm] [RED] tv saves: cannot read %s\n", local); return 0; }
        size_t room = raw.length + raw.length / 8 + 65536;   // compression can grow what it cannot shrink, and fails rather than overrun
        NSMutableData *z = [NSMutableData dataWithLength:HEADER + room];
        memcpy(z.mutableBytes, "DMZ2", 4);
        uint64_t size = raw.length; memcpy((uint8_t *)z.mutableBytes + 4, &size, 8);
        size_t n = compression_encode_buffer((uint8_t *)z.mutableBytes + HEADER, room, raw.bytes, raw.length, NULL, COMPRESSION_LZFSE);
        if (!n) { fprintf(stderr, "[dm] [RED] tv saves: a %llu-byte save did not compress\n", (unsigned long long)size); return 0; }
        z.length = HEADER + n;
        NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
        NSString *key = store_key(cloud), *spill = spill_path(key);
        NSFileManager *fm = NSFileManager.defaultManager;
        if (others_size(d, key) + z.length > STORE_LIMIT) {
            [fm createDirectoryAtPath:spill.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil];
            if (![z writeToFile:spill atomically:YES]) { fprintf(stderr, "[dm] [RED] tv saves: writing %s failed\n", spill.fileSystemRepresentation); return 0; }
            [d removeObjectForKey:key]; [d synchronize];
            fprintf(stderr, "[dm] tv saves: %llu bytes packed to %zu, past the preferences' budget: kept in Library/Preferences\n", (unsigned long long)size, z.length);
            return 1;
        }
        [d setObject:z forKey:key];
        if (![d synchronize]) { fprintf(stderr, "[dm] [RED] tv saves: the preferences did not take the save\n"); return 0; }
        [fm removeItemAtPath:spill error:nil];
        fprintf(stderr, "[dm] tv saves: %llu bytes packed to %zu in the preferences\n", (unsigned long long)size, z.length);
        return 1;
    }
}

int front_save_sync_fetch(const char *cloud, const char *local) {
    @autoreleasepool {
        NSString *key = store_key(cloud);
        NSData *z = [NSUserDefaults.standardUserDefaults dataForKey:key] ?: [NSData dataWithContentsOfFile:spill_path(key)];
        if (!z) return 0;
        uint64_t size = 0;
        int lzfse = z.length > HEADER && !memcmp(z.bytes, "DMZ2", 4);
        if (z.length <= HEADER || (!lzfse && memcmp(z.bytes, "DMZ1", 4))) { fprintf(stderr, "[dm] [RED] tv saves: the stored save %s is damaged\n", key.UTF8String); return -1; }
        memcpy(&size, (const uint8_t *)z.bytes + 4, 8);
        NSMutableData *raw = [NSMutableData dataWithLength:size];
        if (!raw || compression_decode_buffer(raw.mutableBytes, size, (const uint8_t *)z.bytes + HEADER, z.length - HEADER, NULL, lzfse ? COMPRESSION_LZFSE : COMPRESSION_LZMA) != size) {
            fprintf(stderr, "[dm] [RED] tv saves: the stored save %s does not unpack\n", key.UTF8String); return -1; }
        if (![raw writeToFile:@(local) atomically:YES]) { fprintf(stderr, "[dm] [RED] tv saves: writing %s failed\n", local); return -1; }
        return 1;
    }
}

// Which folder a save goes through: named after the folder it lives in, so each player's stays their own. A launch environment that sets DM_SAVE_SYNC wins
void dm_cloud_saves_env(void) {
    if (getenv("DM_SAVE_SYNC")) return;
    NSString *caches = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES).firstObject;
    const char *save = getenv("DM_SAVE");
    NSString *folder = save ? @(save).lastPathComponent : @"save";
    setenv("DM_SAVE_SYNC", [caches stringByAppendingFormat:@"/tv-saves/%@", folder].fileSystemRepresentation, 1);
}
