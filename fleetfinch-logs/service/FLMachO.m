#import "FLMachO.h"

#import <fcntl.h>
#import <libkern/OSByteOrder.h>
#import <mach-o/fat.h>
#import <mach-o/loader.h>
#import <mach/machine.h>
#import <sys/sysctl.h>
#import <unistd.h>

#import "FLCommon.h"

static const uint32_t FLCommandsMost = 1024 * 1024;
static const uint32_t FLSlicesMost = 16;
static const uint64_t FLSignatureMost = 32 * 1024 * 1024;
static const uint32_t FLBlobsMost = 64;
static const uint32_t FLEntitlementsMost = 1024 * 1024;
static const uint32_t FLSignatureMagic = 0xfade0cc0;
static const uint32_t FLEntitlementsMagic = 0xfade7171;
static const uint32_t FLEntitlementsSlot = 5;
static const uint64_t FLStringsMost = 64 * 1024 * 1024;
static const uint32_t FLCacheImagesMost = 20000;
static const uint32_t FLCacheMappingsMost = 64;
static const size_t FLCachePathMost = 1024;
static const uint32_t FLHashStart = 2166136261u;
static const uint32_t FLHashStep = 16777619u;
static const char *const FLStringsSection = "__cstring";
static NSString *const FLCacheFolder = @"/System/Library/Caches/com.apple.dyld";
static NSString *const FLCachePrefix = @"dyld_shared_cache_";

struct FLCacheHeader {
  char magic[16];
  uint32_t mappingOffset;
  uint32_t mappingCount;
  uint32_t imagesOffset;
  uint32_t imagesCount;
};

struct FLCacheMapping {
  uint64_t address;
  uint64_t size;
  uint64_t fileOffset;
  uint32_t maxProtection;
  uint32_t initialProtection;
};

struct FLCacheImage {
  uint64_t address;
  uint64_t modified;
  uint64_t inode;
  uint32_t pathOffset;
  uint32_t padding;
};

typedef struct {
  uint32_t hash;
  uint32_t length;
  uint32_t index;
  uint32_t used;
  const char *bytes;
} FLNameSlot;

@implementation FLImage

- (BOOL)isProgram {
  return self.fileType == MH_EXECUTE;
}

- (BOOL)isPlugIn {
  return self.fileType == MH_BUNDLE;
}

@end

static NSString *FLCommandText(const uint8_t *command, uint32_t size, size_t field) {
  uint32_t start = 0;
  if (field + sizeof(start) > size) {
    return nil;
  }
  memcpy(&start, command + field, sizeof(start));
  if (start >= size) {
    return nil;
  }
  size_t length = strnlen((const char *)command + start, size - start);
  return [[NSString alloc] initWithBytes:command + start
                                  length:length
                                encoding:NSUTF8StringEncoding];
}

static void FLReadSegment(FLImage *image, const uint8_t *command, uint32_t size,
                          uint64_t slice) {
  struct segment_command segment;
  memcpy(&segment, command, sizeof(segment));
  if (strncmp(segment.segname, SEG_LINKEDIT, sizeof(segment.segname)) != 0) {
    image.segmentBytes += segment.vmsize;
  }
  if (strncmp(segment.segname, SEG_TEXT, sizeof(segment.segname)) != 0) {
    return;
  }
  for (uint32_t index = 0; index < segment.nsects; index++) {
    uint64_t at = sizeof(segment) + (uint64_t)index * sizeof(struct section);
    struct section section;
    if (at + sizeof(section) > size) {
      return;
    }
    memcpy(&section, command + at, sizeof(section));
    if (strncmp(section.sectname, FLStringsSection, sizeof(section.sectname)) == 0) {
      image.stringsAddress = section.addr;
      image.stringsOffset = slice + section.offset;
      image.stringsSize = section.size;
    }
  }
}

static void FLReadWideSegment(FLImage *image, const uint8_t *command, uint32_t size,
                              uint64_t slice) {
  struct segment_command_64 segment;
  memcpy(&segment, command, sizeof(segment));
  if (strncmp(segment.segname, SEG_LINKEDIT, sizeof(segment.segname)) != 0) {
    image.segmentBytes += segment.vmsize;
  }
  if (strncmp(segment.segname, SEG_TEXT, sizeof(segment.segname)) != 0) {
    return;
  }
  for (uint32_t index = 0; index < segment.nsects; index++) {
    uint64_t at = sizeof(segment) + (uint64_t)index * sizeof(struct section_64);
    struct section_64 section;
    if (at + sizeof(section) > size) {
      return;
    }
    memcpy(&section, command + at, sizeof(section));
    if (strncmp(section.sectname, FLStringsSection, sizeof(section.sectname)) == 0) {
      image.stringsAddress = section.addr;
      image.stringsOffset = slice + section.offset;
      image.stringsSize = section.size;
    }
  }
}

FLImage *FLReadImage(int handle, uint64_t offset) {
  struct mach_header header;
  if (pread(handle, &header, sizeof(header), (off_t)offset) != (ssize_t)sizeof(header)) {
    return nil;
  }
  BOOL wide = header.magic == MH_MAGIC_64;
  if ((header.magic != MH_MAGIC && !wide) || header.sizeofcmds == 0 ||
      header.sizeofcmds > FLCommandsMost) {
    return nil;
  }
  uint64_t start = offset + (wide ? sizeof(struct mach_header_64) : sizeof(struct mach_header));
  uint32_t length = header.sizeofcmds;
  uint8_t *commands = malloc(length);
  if (commands == NULL || pread(handle, commands, length, (off_t)start) != (ssize_t)length) {
    free(commands);
    return nil;
  }
  FLImage *image = [FLImage new];
  image.fileType = header.filetype;
  NSMutableArray<NSString *> *links = [NSMutableArray new];
  NSMutableArray<NSString *> *weak = [NSMutableArray new];
  NSMutableArray<NSString *> *paths = [NSMutableArray new];
  uint64_t at = 0;
  for (uint32_t index = 0; index < header.ncmds; index++) {
    struct load_command command;
    if (at + sizeof(command) > length) {
      break;
    }
    memcpy(&command, commands + at, sizeof(command));
    if (command.cmdsize < sizeof(command) || at + command.cmdsize > length) {
      break;
    }
    const uint8_t *body = commands + at;
    uint32_t size = command.cmdsize;
    switch (command.cmd) {
      case LC_LOAD_DYLIB:
      case LC_LOAD_WEAK_DYLIB:
      case LC_REEXPORT_DYLIB:
      case LC_LAZY_LOAD_DYLIB:
      case LC_LOAD_UPWARD_DYLIB: {
        NSString *name = FLCommandText(body, size, offsetof(struct dylib_command, dylib.name));
        if (name.length > 0) {
          [links addObject:name];
          if (command.cmd == LC_LOAD_WEAK_DYLIB) {
            [weak addObject:name];
          }
        }
        break;
      }
      case LC_LOAD_DYLINKER: {
        NSString *name = FLCommandText(body, size, offsetof(struct dylinker_command, name));
        if (name.length > 0) {
          [links addObject:name];
        }
        break;
      }
      case LC_ID_DYLIB:
        image.installName = FLCommandText(body, size, offsetof(struct dylib_command, dylib.name));
        break;
      case LC_RPATH: {
        NSString *path = FLCommandText(body, size, offsetof(struct rpath_command, path));
        if (path.length > 0) {
          [paths addObject:path];
        }
        break;
      }
      case LC_CODE_SIGNATURE:
        if (size >= sizeof(struct linkedit_data_command)) {
          struct linkedit_data_command signature;
          memcpy(&signature, body, sizeof(signature));
          image.signatureOffset = offset + signature.dataoff;
          image.signatureSize = signature.datasize;
        }
        break;
      case LC_ENCRYPTION_INFO:
      case LC_ENCRYPTION_INFO_64:
        if (size >= sizeof(struct encryption_info_command)) {
          struct encryption_info_command encryption;
          memcpy(&encryption, body, sizeof(encryption));
          image.encrypted = encryption.cryptid != 0;
        }
        break;
      case LC_SEGMENT:
        if (size >= sizeof(struct segment_command)) {
          FLReadSegment(image, body, size, offset);
        }
        break;
      case LC_SEGMENT_64:
        if (size >= sizeof(struct segment_command_64)) {
          FLReadWideSegment(image, body, size, offset);
        }
        break;
      default:
        break;
    }
    at += command.cmdsize;
  }
  free(commands);
  image.links = links;
  image.weakLinks = weak;
  image.searchPaths = paths;
  return image;
}

static uint64_t FLBestSlice(int handle) {
  struct fat_header header;
  if (pread(handle, &header, sizeof(header), 0) != (ssize_t)sizeof(header) ||
      header.magic != FAT_CIGAM) {
    return 0;
  }
  int host = 0;
  int level = 0;
  size_t length = sizeof(host);
  sysctlbyname("hw.cputype", &host, &length, NULL, 0);
  length = sizeof(level);
  sysctlbyname("hw.cpusubtype", &level, &length, NULL, 0);
  uint32_t count = MIN(OSSwapBigToHostInt32(header.nfat_arch), FLSlicesMost);
  uint64_t best = 0;
  long score = -1;
  for (uint32_t index = 0; index < count; index++) {
    struct fat_arch slice;
    off_t at = (off_t)(sizeof(header) + index * sizeof(slice));
    if (pread(handle, &slice, sizeof(slice), at) != (ssize_t)sizeof(slice)) {
      break;
    }
    int type = (int)OSSwapBigToHostInt32((uint32_t)slice.cputype);
    int kind = (int)(OSSwapBigToHostInt32((uint32_t)slice.cpusubtype) & ~CPU_SUBTYPE_MASK);
    long fit = type == host && kind <= level ? 1 + kind : 0;
    if (fit > score) {
      score = fit;
      best = OSSwapBigToHostInt32(slice.offset);
    }
  }
  return best;
}

FLImage *FLReadImageFile(int handle) {
  return FLReadImage(handle, FLBestSlice(handle));
}

NSDictionary *FLReadEntitlements(int handle, FLImage *image) {
  uint64_t base = image.signatureOffset;
  uint64_t size = image.signatureSize;
  uint32_t head[3];
  if (size < sizeof(head) || size > FLSignatureMost ||
      pread(handle, head, sizeof(head), (off_t)base) != (ssize_t)sizeof(head) ||
      OSSwapBigToHostInt32(head[0]) != FLSignatureMagic) {
    return nil;
  }
  uint32_t count = MIN(OSSwapBigToHostInt32(head[2]), FLBlobsMost);
  for (uint32_t index = 0; index < count; index++) {
    uint32_t entry[2];
    uint64_t at = sizeof(head) + (uint64_t)index * sizeof(entry);
    if (at + sizeof(entry) > size ||
        pread(handle, entry, sizeof(entry), (off_t)(base + at)) != (ssize_t)sizeof(entry)) {
      return nil;
    }
    if (OSSwapBigToHostInt32(entry[0]) != FLEntitlementsSlot) {
      continue;
    }
    uint64_t start = OSSwapBigToHostInt32(entry[1]);
    uint32_t blob[2];
    if (start + sizeof(blob) > size ||
        pread(handle, blob, sizeof(blob), (off_t)(base + start)) != (ssize_t)sizeof(blob) ||
        OSSwapBigToHostInt32(blob[0]) != FLEntitlementsMagic) {
      return nil;
    }
    uint32_t length = OSSwapBigToHostInt32(blob[1]);
    if (length <= sizeof(blob) || length > FLEntitlementsMost || start + length > size) {
      return nil;
    }
    NSMutableData *data = [NSMutableData dataWithLength:length - sizeof(blob)];
    off_t text = (off_t)(base + start + sizeof(blob));
    if (pread(handle, data.mutableBytes, data.length, text) != (ssize_t)data.length) {
      return nil;
    }
    id plist = [NSPropertyListSerialization propertyListWithData:data
                                                         options:NSPropertyListImmutable
                                                          format:NULL
                                                           error:NULL];
    return [plist isKindOfClass:[NSDictionary class]] ? plist : nil;
  }
  return nil;
}

@implementation FLSharedCache {
  struct FLCacheMapping *_mappings;
  uint32_t _mapped;
}

+ (NSArray<FLSharedCache *> *)caches {
  NSMutableArray<FLSharedCache *> *caches = [NSMutableArray new];
  NSFileManager *manager = [NSFileManager defaultManager];
  NSArray<NSString *> *names = [[manager contentsOfDirectoryAtPath:FLCacheFolder error:NULL]
    sortedArrayUsingSelector:@selector(compare:)];
  for (NSString *name in names) {
    if ([name hasPrefix:FLCachePrefix] && name.pathExtension.length == 0) {
      NSString *file = [FLCacheFolder stringByAppendingPathComponent:name];
      FLSharedCache *cache = [[FLSharedCache alloc] initWithPath:file];
      if (cache != nil) {
        [caches addObject:cache];
      }
    }
  }
  return caches;
}

- (instancetype)initWithPath:(NSString *)path {
  self = [super init];
  if (self) {
    _path = [path copy];
    _bytes = FLFileSize(path);
    _handle = open(path.fileSystemRepresentation, O_RDONLY);
    if (_handle < 0 || ![self readTables]) {
      return nil;
    }
  }
  return self;
}

- (void)dealloc {
  free(_mappings);
  if (_handle >= 0) {
    close(_handle);
  }
}

- (BOOL)readTables {
  struct FLCacheHeader header;
  if (pread(_handle, &header, sizeof(header), 0) != (ssize_t)sizeof(header) ||
      strncmp(header.magic, "dyld_v1", 7) != 0 || header.mappingCount == 0 ||
      header.mappingCount > FLCacheMappingsMost || header.imagesCount > FLCacheImagesMost) {
    return NO;
  }
  size_t mapped = header.mappingCount * sizeof(struct FLCacheMapping);
  size_t listed = header.imagesCount * sizeof(struct FLCacheImage);
  _mappings = malloc(mapped);
  struct FLCacheImage *entries = malloc(MAX(listed, sizeof(struct FLCacheImage)));
  if (_mappings == NULL || entries == NULL ||
      pread(_handle, _mappings, mapped, header.mappingOffset) != (ssize_t)mapped ||
      pread(_handle, entries, listed, header.imagesOffset) != (ssize_t)listed) {
    free(entries);
    return NO;
  }
  _mapped = header.mappingCount;
  NSMutableArray<NSMutableDictionary *> *images = [NSMutableArray new];
  NSMutableDictionary<NSNumber *, NSMutableDictionary *> *known = [NSMutableDictionary new];
  for (uint32_t index = 0; index < header.imagesCount; index++) {
    @autoreleasepool {
      char name[FLCachePathMost] = {0};
      if (pread(_handle, name, sizeof(name) - 1, entries[index].pathOffset) <= 0) {
        continue;
      }
      NSString *path = [NSString stringWithUTF8String:name];
      if (path.length == 0) {
        continue;
      }
      NSNumber *address = @(entries[index].address);
      NSMutableDictionary *image = known[address];
      if (image != nil) {
        NSMutableArray *aliases = image[@"aliases"] ?: [NSMutableArray new];
        [aliases addObject:path];
        image[@"aliases"] = aliases;
        continue;
      }
      uint64_t offset = 0;
      if (![self offset:&offset ofAddress:entries[index].address]) {
        continue;
      }
      image = [NSMutableDictionary new];
      image[@"path"] = path;
      image[@"offset"] = @(offset);
      known[address] = image;
      [images addObject:image];
    }
  }
  free(entries);
  _images = images;
  return YES;
}

- (BOOL)offset:(uint64_t *)offset ofAddress:(uint64_t)address {
  for (uint32_t index = 0; index < _mapped; index++) {
    if (address >= _mappings[index].address &&
        address - _mappings[index].address < _mappings[index].size) {
      *offset = _mappings[index].fileOffset + (address - _mappings[index].address);
      return YES;
    }
  }
  return NO;
}

@end

@implementation FLNameSet {
  FLNameSlot *_slots;
  uint32_t _mask;
  uint32_t _shortest;
  uint32_t _longest;
  NSMutableArray<NSData *> *_kept;
}

- (instancetype)initWithNames:(NSArray<NSString *> *)names {
  self = [super init];
  if (self) {
    uint32_t room = 16;
    while (room < 4 * names.count) {
      room *= 2;
    }
    _slots = calloc(room, sizeof(FLNameSlot));
    _mask = room - 1;
    _shortest = UINT32_MAX;
    _kept = [NSMutableArray new];
    for (NSUInteger index = 0; _slots != NULL && index < names.count; index++) {
      NSData *text = [names[index] dataUsingEncoding:NSUTF8StringEncoding];
      if (text.length == 0) {
        continue;
      }
      [_kept addObject:text];
      const uint8_t *bytes = text.bytes;
      uint32_t hash = FLHashStart;
      for (NSUInteger at = 0; at < text.length; at++) {
        hash = (hash ^ bytes[at]) * FLHashStep;
      }
      uint32_t slot = hash & _mask;
      while (_slots[slot].used) {
        slot = (slot + 1) & _mask;
      }
      _slots[slot].used = 1;
      _slots[slot].hash = hash;
      _slots[slot].length = (uint32_t)text.length;
      _slots[slot].index = (uint32_t)index;
      _slots[slot].bytes = text.bytes;
      _shortest = MIN(_shortest, (uint32_t)text.length);
      _longest = MAX(_longest, (uint32_t)text.length);
    }
  }
  return self;
}

- (void)dealloc {
  free(_slots);
}

- (void)scan:(int)handle
      offset:(uint64_t)offset
        size:(uint64_t)size
        into:(NSMutableIndexSet *)found {
  if (_slots == NULL || size == 0 || size > FLStringsMost) {
    return;
  }
  uint8_t *bytes = malloc((size_t)size);
  ssize_t held = bytes == NULL ? 0 : pread(handle, bytes, (size_t)size, (off_t)offset);
  uint64_t at = 0;
  while (held > 0 && at < (uint64_t)held) {
    uint32_t hash = FLHashStart;
    uint64_t start = at;
    while (at < (uint64_t)held && bytes[at] != 0) {
      hash = (hash ^ bytes[at]) * FLHashStep;
      at++;
    }
    uint64_t length = at - start;
    at++;
    if (length < _shortest || length > _longest) {
      continue;
    }
    uint32_t slot = hash & _mask;
    while (_slots[slot].used) {
      if (_slots[slot].hash == hash && _slots[slot].length == length &&
          memcmp(_slots[slot].bytes, bytes + start, (size_t)length) == 0) {
        [found addIndex:_slots[slot].index];
        break;
      }
      slot = (slot + 1) & _mask;
    }
  }
  free(bytes);
}

@end
