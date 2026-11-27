#import "FFCopy.h"

#import <copyfile.h>
#import <fcntl.h>
#import <sys/mount.h>
#import <sys/stat.h>
#import <sys/time.h>
#import <unistd.h>

#import "FFCleanup.h"

NSString *const FFPartSuffix = @".ffpart";

static const uint64_t FFSpareBytes = 8 * 1024 * 1024;
static const size_t FFCompareBytes = 64 * 1024;

BOOL FFIsInside(NSString *path, NSString *folder) {
  return [path isEqualToString:folder] || [path hasPrefix:[folder stringByAppendingString:@"/"]];
}

NSString *FFCleanPath(NSString *word) {
  NSString *path = word;
  while (path.length > 1 && [path hasSuffix:@"/"]) {
    path = [path substringToIndex:path.length - 1];
  }
  NSString *name = path.lastPathComponent;
  char resolved[PATH_MAX];
  if (![path hasPrefix:@"/"] || [name isEqualToString:@"."] || [name isEqualToString:@".."] ||
      realpath(path.stringByDeletingLastPathComponent.fileSystemRepresentation, resolved) == NULL) {
    return nil;
  }
  NSString *folder =
    [[NSFileManager defaultManager] stringWithFileSystemRepresentation:resolved
                                                                length:strlen(resolved)];
  return [folder stringByAppendingPathComponent:name];
}

BOOL FFOnSystemVolume(NSString *path) {
  struct statfs volume;
  return statfs(path.stringByDeletingLastPathComponent.fileSystemRepresentation, &volume) == 0 &&
         strcmp(volume.f_mntonname, "/") == 0;
}

void FFPruneEmptyFolders(NSString *folder, NSString *stop) {
  NSString *each = folder;
  while (FFIsInside(each, stop) && ![each isEqualToString:stop] &&
         rmdir(each.fileSystemRepresentation) == 0) {
    each = each.stringByDeletingLastPathComponent;
  }
}

static BOOL FFCopyEntry(NSString *from, NSString *to) {
  const char *source = from.fileSystemRepresentation;
  const char *target = to.fileSystemRepresentation;
  struct stat info;
  if (lstat(source, &info) != 0) {
    return NO;
  }
  if (S_ISDIR(info.st_mode)) {
    if (mkdir(target, S_IRWXU) != 0) {
      return NO;
    }
    NSFileManager *manager = [NSFileManager defaultManager];
    for (NSString *name in [manager contentsOfDirectoryAtPath:from error:NULL]) {
      @autoreleasepool {
        if (!FFCopyEntry([from stringByAppendingPathComponent:name],
                         [to stringByAppendingPathComponent:name])) {
          return NO;
        }
      }
    }
  } else if (S_ISLNK(info.st_mode)) {
    char link[PATH_MAX];
    ssize_t length = readlink(source, link, sizeof(link) - 1);
    if (length < 0) {
      return NO;
    }
    link[length] = '\0';
    if (symlink(link, target) != 0) {
      return NO;
    }
  } else if (S_ISREG(info.st_mode)) {
    copyfile_flags_t how = COPYFILE_DATA | COPYFILE_XATTR | COPYFILE_NOFOLLOW | COPYFILE_EXCL;
    if (copyfile(source, target, NULL, how) != 0) {
      return NO;
    }
  } else {
    return NO;
  }
  if (lchown(target, info.st_uid, info.st_gid) != 0) {
    return NO;
  }
  if (S_ISLNK(info.st_mode)) {
    return YES;
  }
  struct timeval times[2];
  times[0].tv_sec = info.st_atimespec.tv_sec;
  times[0].tv_usec = 0;
  times[1].tv_sec = info.st_mtimespec.tv_sec;
  times[1].tv_usec = (suseconds_t)(info.st_mtimespec.tv_nsec / 1000);
  return chmod(target, info.st_mode & 07777) == 0 && utimes(target, times) == 0;
}

static BOOL FFSameContents(const char *first, const char *second) {
  int one = open(first, O_RDONLY | O_NOFOLLOW);
  int other = open(second, O_RDONLY | O_NOFOLLOW);
  char *block = malloc(2 * FFCompareBytes);
  BOOL same = one >= 0 && other >= 0 && block != NULL;
  while (same) {
    ssize_t got = read(one, block, FFCompareBytes);
    ssize_t matched = got <= 0 ? got : read(other, block + FFCompareBytes, (size_t)got);
    if (got < 0 || matched != got) {
      same = NO;
    } else if (got == 0) {
      same = read(other, block + FFCompareBytes, 1) == 0;
      break;
    } else {
      same = memcmp(block, block + FFCompareBytes, (size_t)got) == 0;
    }
  }
  free(block);
  if (one >= 0) {
    close(one);
  }
  if (other >= 0) {
    close(other);
  }
  return same;
}

static BOOL FFSameEntry(NSString *from, NSString *to) {
  const char *source = from.fileSystemRepresentation;
  const char *target = to.fileSystemRepresentation;
  struct stat first, second;
  if (lstat(source, &first) != 0 || lstat(target, &second) != 0 ||
      first.st_mode != second.st_mode || first.st_uid != second.st_uid ||
      first.st_gid != second.st_gid) {
    return NO;
  }
  if (S_ISREG(first.st_mode)) {
    return first.st_size == second.st_size && FFSameContents(source, target);
  }
  if (S_ISLNK(first.st_mode)) {
    char one[PATH_MAX], other[PATH_MAX];
    ssize_t length = readlink(source, one, sizeof(one));
    return length >= 0 && length == readlink(target, other, sizeof(other)) &&
           memcmp(one, other, (size_t)length) == 0;
  }
  if (!S_ISDIR(first.st_mode)) {
    return NO;
  }
  NSFileManager *manager = [NSFileManager defaultManager];
  NSArray<NSString *> *names = [manager contentsOfDirectoryAtPath:from error:NULL];
  NSArray<NSString *> *copied = [manager contentsOfDirectoryAtPath:to error:NULL];
  if (names == nil || copied == nil ||
      ![[NSSet setWithArray:names] isEqualToSet:[NSSet setWithArray:copied]]) {
    return NO;
  }
  for (NSString *name in names) {
    @autoreleasepool {
      if (!FFSameEntry([from stringByAppendingPathComponent:name],
                       [to stringByAppendingPathComponent:name])) {
        return NO;
      }
    }
  }
  return YES;
}

BOOL FFSameTree(NSString *first, NSString *second) {
  return FFSameEntry(first, second);
}

NSString *FFCopyTree(NSString *from, NSString *to) {
  NSFileManager *manager = [NSFileManager defaultManager];
  NSString *folder = to.stringByDeletingLastPathComponent;
  NSString *part = [to stringByAppendingString:FFPartSuffix];
  struct stat info;
  if (lstat(to.fileSystemRepresentation, &info) == 0) {
    return [NSString stringWithFormat:@"there is already something at %@", to];
  }
  [manager createDirectoryAtPath:folder
     withIntermediateDirectories:YES
                      attributes:@{NSFilePosixPermissions : @0755}
                           error:NULL];
  [manager removeItemAtPath:part error:NULL];
  uint64_t space = FFSpaceTaken(from, NULL, NULL);
  if (FFRoomAt(folder) < space + FFSpareBytes) {
    return [NSString stringWithFormat:@"there is not room for %@ where %@ is",
                                      FFFormatBytes(space), folder];
  }
  if (!FFCopyEntry(from, part) || !FFSameEntry(from, part)) {
    [manager removeItemAtPath:part error:NULL];
    return [NSString stringWithFormat:@"the copy at %@ did not come out the same", to];
  }
  if (rename(part.fileSystemRepresentation, to.fileSystemRepresentation) != 0) {
    [manager removeItemAtPath:part error:NULL];
    return [NSString stringWithFormat:@"the copy could not be named %@: %s", to, strerror(errno)];
  }
  return nil;
}
