#import "FLDump.h"

#import <fcntl.h>
#import <sys/stat.h>
#import <sys/utsname.h>
#import <unistd.h>
#import <zlib.h>

#import "FLCommon.h"
#import "FLSystemInfo.h"

static const size_t FLBlock = 512;
static const size_t FLChunk = 64 * 1024;

typedef BOOL (^FLSink)(const void *bytes, size_t length);

static BOOL FLSplitName(NSString *name, char *header) {
  const char *full = name.UTF8String;
  size_t length = strlen(full);
  if (length <= 100) {
    memcpy(header, full, length);
    return YES;
  }
  for (size_t index = 0; index < length; index++) {
    if (full[index] != '/') {
      continue;
    }
    size_t rest = length - index - 1;
    if (index <= 155 && rest <= 100 && rest > 0) {
      memcpy(header + 345, full, index);
      memcpy(header, full + index + 1, rest);
      return YES;
    }
  }
  return NO;
}

static BOOL FLWriteHeader(FLSink sink, NSString *name, uint64_t size, time_t modified) {
  char header[512];
  memset(header, 0, sizeof(header));
  if (!FLSplitName(name, header)) {
    return NO;
  }
  snprintf(header + 100, 8, "%07o", 0644);
  snprintf(header + 108, 8, "%07o", 0);
  snprintf(header + 116, 8, "%07o", 0);
  snprintf(header + 124, 12, "%011llo", (unsigned long long)size);
  snprintf(header + 136, 12, "%011llo", (unsigned long long)modified);
  memset(header + 148, ' ', 8);
  header[156] = '0';
  memcpy(header + 257, "ustar", 6);
  memcpy(header + 263, "00", 2);
  unsigned sum = 0;
  for (size_t index = 0; index < sizeof(header); index++) {
    sum += (unsigned char)header[index];
  }
  snprintf(header + 148, 8, "%06o", sum);
  header[155] = ' ';
  return sink(header, sizeof(header));
}

static BOOL FLWritePadding(FLSink sink, uint64_t size) {
  size_t remainder = (size_t)(size % FLBlock);
  if (remainder == 0) {
    return YES;
  }
  char zeros[512] = {0};
  return sink(zeros, FLBlock - remainder);
}

static BOOL FLWriteData(FLSink sink, NSString *name, NSData *data) {
  return FLWriteHeader(sink, name, data.length, time(NULL)) &&
         sink(data.bytes, data.length) && FLWritePadding(sink, data.length);
}

static BOOL FLWriteFile(FLSink sink, NSString *name, NSString *path) {
  int handle = open(path.fileSystemRepresentation, O_RDONLY);
  if (handle < 0) {
    return YES;
  }
  struct stat info;
  if (fstat(handle, &info) != 0 || !S_ISREG(info.st_mode) ||
      !FLWriteHeader(sink, name, (uint64_t)info.st_size, info.st_mtime)) {
    close(handle);
    return YES;
  }
  BOOL written = YES;
  uint64_t remaining = (uint64_t)info.st_size;
  char *buffer = calloc(1, FLChunk);
  while (remaining > 0 && written) {
    size_t wanted = (size_t)MIN((uint64_t)FLChunk, remaining);
    ssize_t count = read(handle, buffer, wanted);
    if (count <= 0) {
      memset(buffer, 0, wanted);
      count = (ssize_t)wanted;
    }
    written = sink(buffer, (size_t)count);
    remaining -= (uint64_t)count;
  }
  free(buffer);
  close(handle);
  return written && FLWritePadding(sink, (uint64_t)info.st_size);
}

static NSString *FLManifest(NSTimeInterval newerThan) {
  struct utsname name;
  uname(&name);
  NSMutableString *text = [NSMutableString new];
  [text appendFormat:@"Finch Logs dump\n"];
  [text appendFormat:@"Version: %@\n", FLVersion];
  [text appendFormat:@"Made: %@\n", FLTimestamp([NSDate date])];
  [text appendFormat:@"Device: %s\n", name.nodename];
  [text appendFormat:@"Model: %s\n", name.machine];
  [text appendFormat:@"System: %@\n", FLSysctlString(@"kern.osversion") ?: @""];
  [text appendFormat:@"Kernel: %s\n", name.release];
  NSDate *boot = FLBootTime();
  if (boot != nil) {
    [text appendFormat:@"Started: %@\n", FLTimestamp(boot)];
  }
  if (newerThan > 0) {
    [text appendFormat:@"Holds: files changed in the last %@\n", FLFormatDuration(newerThan)];
  } else {
    [text appendString:@"Holds: every file in the store\n"];
  }
  return text;
}

BOOL FLWriteDump(int output, NSTimeInterval newerThan, BOOL compress) {
  gzFile packed = compress ? gzdopen(dup(output), "wb6") : NULL;
  if (compress && packed == NULL) {
    return NO;
  }
  FLSink sink = ^BOOL(const void *bytes, size_t length) {
    if (length == 0) {
      return YES;
    }
    if (packed != NULL) {
      return gzwrite(packed, bytes, (unsigned)length) == (int)length;
    }
    const char *cursor = bytes;
    size_t remaining = length;
    while (remaining > 0) {
      ssize_t count = write(output, cursor, remaining);
      if (count <= 0) {
        return NO;
      }
      cursor += count;
      remaining -= (size_t)count;
    }
    return YES;
  };
  BOOL written = FLWriteData(sink, @"finchlogs.txt",
                             [FLManifest(newerThan) dataUsingEncoding:NSUTF8StringEncoding]);
  NSFileManager *manager = [NSFileManager defaultManager];
  time_t now = time(NULL);
  for (NSString *folder in @[ @"archive", @"live" ]) {
    NSString *root = [FLRootPath stringByAppendingPathComponent:folder];
    NSArray *relatives = [[[manager enumeratorAtPath:root] allObjects]
      sortedArrayUsingSelector:@selector(compare:)];
    for (NSString *relative in relatives) {
      if (!written) {
        break;
      }
      @autoreleasepool {
        NSString *path = [root stringByAppendingPathComponent:relative];
        struct stat info;
        if (lstat(path.fileSystemRepresentation, &info) != 0 || !S_ISREG(info.st_mode) ||
            [relative hasSuffix:@".part"]) {
          continue;
        }
        if (newerThan > 0 && now - info.st_mtime > (time_t)newerThan) {
          continue;
        }
        written = FLWriteFile(sink, [folder stringByAppendingPathComponent:relative], path);
      }
    }
  }
  char zeros[1024] = {0};
  written = written && sink(zeros, sizeof(zeros));
  if (packed != NULL) {
    written = gzclose(packed) == Z_OK && written;
  }
  return written;
}
