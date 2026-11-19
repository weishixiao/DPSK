/*
 * RVProcess.m — what is running, what is mapped into it, and where its functions are.
 *
 * Images are found by walking the target's VM map and accepting a region that
 * begins with a Mach-O header, not by reading `dyld_all_image_infos`: the private
 * struct's layout differs between dyld versions, while a header at a region's start
 * is the same on every release. A header's own `LC_ID_DYLIB` supplies the install
 * name, so the result is usable as an image selector without any extra bookkeeping.
 */

#import "RVPrelude.h"

/** Bytes of load commands read per image; enough for every real binary's header. */
#define RV_MAX_LOAD_COMMANDS (64u * 1024u)

#pragma mark - Small reading helpers

/** Copy `length` bytes out of a task; NO when the range is not mapped. */
static BOOL RVReadTask(mach_port_t task, uint64_t address, void *buffer, mach_vm_size_t length) {
  mach_vm_size_t copied = 0;
  kern_return_t result = mach_vm_read_overwrite(task,
                                                (mach_vm_address_t)address,
                                                length,
                                                (mach_vm_address_t)(uintptr_t)buffer,
                                                &copied);
  return result == KERN_SUCCESS && copied == length;
}

/** The install name of a header's LC_ID_DYLIB, or nil for an executable. */
static NSString *RVInstallName(const struct mach_header_64 *header, const void *commands, size_t bytes) {
  const uint8_t *cursor = (const uint8_t *)commands;
  const uint8_t *end = cursor + bytes;
  for (uint32_t index = 0; index < header->ncmds && cursor + sizeof(struct load_command) <= end; index++) {
    const struct load_command *command = (const struct load_command *)cursor;
    if (command->cmd == LC_ID_DYLIB && command->cmdsize >= sizeof(struct dylib_command)) {
      const struct dylib_command *dylib = (const struct dylib_command *)command;
      const char *name = (const char *)cursor + dylib->dylib.name.offset;
      return [NSString stringWithUTF8String:name];
    }
    if (command->cmdsize < sizeof(struct load_command)) break;
    cursor += command->cmdsize;
  }
  return nil;
}

/** The LC_UUID of a header, rendered as the usual dashed UUID. */
static NSString *RVUUID(const void *commands, size_t bytes) {
  const uint8_t *cursor = (const uint8_t *)commands;
  const uint8_t *end = cursor + bytes;
  const uint8_t *commandStart = cursor;
  const struct load_command *header = (const struct load_command *)commandStart;
  for (uint32_t index = 0; index < 4096; index++) {
    if (cursor + sizeof(struct load_command) > end) break;
    const struct load_command *command = (const struct load_command *)cursor;
    if (command->cmd == LC_UUID && command->cmdsize >= sizeof(struct uuid_command)) {
      const struct uuid_command *uuid = (const struct uuid_command *)command;
      return [NSString stringWithFormat:
              @"%02X%02X%02X%02X-%02X%02X-%02X%02X-%02X%02X-%02X%02X%02X%02X%02X%02X",
              uuid->uuid[0], uuid->uuid[1], uuid->uuid[2], uuid->uuid[3],
              uuid->uuid[4], uuid->uuid[5], uuid->uuid[6], uuid->uuid[7],
              uuid->uuid[8], uuid->uuid[9], uuid->uuid[10], uuid->uuid[11],
              uuid->uuid[12], uuid->uuid[13], uuid->uuid[14], uuid->uuid[15]];
    }
    if (command->cmdsize < sizeof(struct load_command)) break;
    cursor += command->cmdsize;
    (void)header;
  }
  return nil;
}

/** The mapped span of an image, from its segments. */
static mach_vm_size_t RVImageSpan(const void *commands, size_t bytes) {
  const uint8_t *cursor = (const uint8_t *)commands;
  const uint8_t *end = cursor + bytes;
  uint64_t highest = 0;
  for (int index = 0; index < 4096; index++) {
    if (cursor + sizeof(struct load_command) > end) break;
    const struct load_command *command = (const struct load_command *)cursor;
    if (command->cmd == LC_SEGMENT_64 && command->cmdsize >= sizeof(struct segment_command_64)) {
      const struct segment_command_64 *segment = (const struct segment_command_64 *)command;
      uint64_t top = segment->vmaddr + segment->vmsize;
      if (top > highest) highest = top;
    }
    if (command->cmdsize < sizeof(struct load_command)) break;
    cursor += command->cmdsize;
  }
  return (mach_vm_size_t)highest;
}

/** True for the header of a loadable image, as opposed to an embedded blob. */
static BOOL RVIsImageHeader(const struct mach_header_64 *header) {
  if (header->magic != MH_MAGIC_64 && header->magic != MH_CIGAM_64) return NO;
  if (header->cputype != CPU_TYPE_ARM64) return NO;
  switch (header->filetype) {
    case MH_EXECUTE:
    case MH_DYLIB:
    case MH_DYLINKER:
    case MH_BUNDLE:
    case MH_DYLIB_STUB:
      return YES;
    default:
      return NO;
  }
}

#pragma mark - Process list

/** Bundle identifier of the app whose executable is `path`, when it is one. */
static NSString *RVBundleIdForExecutable(NSString *path) {
  NSRange app = [path rangeOfString:@".app/" options:NSBackwardsSearch];
  if (app.location == NSNotFound) return nil;
  NSString *bundlePath = [path substringToIndex:app.location + 4];
  NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:
                        [bundlePath stringByAppendingPathComponent:@"Info.plist"]];
  NSString *identifier = info[@"CFBundleIdentifier"];
  return [identifier isKindOfClass:[NSString class]] ? identifier : nil;
}

@implementation RVProcess

+ (NSArray *)listWithFilter:(NSString *)filter error:(RVError **)error {
  int mib[4] = {CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0};
  size_t size = 0;
  if (sysctl(mib, 3, NULL, &size, NULL, 0) != 0) {
    if (error != NULL) {
      *error = [RVError errorWithCode:RVCodeRemoteError message:@"sysctl could not size the process table"];
    }
    return nil;
  }

  struct kinfo_proc *table = malloc(size);
  if (table == NULL) {
    if (error != NULL) *error = [RVError errorWithCode:RVCodeRemoteError message:@"out of memory"];
    return nil;
  }
  if (sysctl(mib, 3, table, &size, NULL, 0) != 0) {
    free(table);
    if (error != NULL) {
      *error = [RVError errorWithCode:RVCodeRemoteError message:@"sysctl could not read the process table"];
    }
    return nil;
  }

  NSUInteger count = size / sizeof(struct kinfo_proc);
  NSMutableArray *processes = [NSMutableArray arrayWithCapacity:count];
  NSString *needle = filter.lowercaseString;

  for (NSUInteger index = 0; index < count; index++) {
    struct kinfo_proc *entry = &table[index];
    pid_t pid = entry->kp_proc.p_pid;
    if (pid <= 0) continue;

    NSString *name = [NSString stringWithUTF8String:entry->kp_proc.p_comm] ?: @"";
    char pathBuffer[PROC_PIDPATHINFO_MAXSIZE];
    int pathLength = proc_pidpath(pid, pathBuffer, sizeof(pathBuffer));
    NSString *path = pathLength > 0 ? [NSString stringWithUTF8String:pathBuffer] : @"";

    NSString *bundleId = path.length > 0 ? RVBundleIdForExecutable(path) : nil;

    if (needle.length > 0) {
      BOOL matches = [name.lowercaseString containsString:needle]
        || [path.lowercaseString containsString:needle]
        || [bundleId.lowercaseString containsString:needle];
      if (!matches) continue;
    }

    NSMutableDictionary *record = [NSMutableDictionary dictionary];
    record[@"pid"] = @(pid);
    record[@"name"] = name;
    record[@"uid"] = @(entry->kp_eproc.e_ucred.cr_uid);
    record[@"path"] = path;
    if (bundleId != nil) record[@"bundleId"] = bundleId;
    [processes addObject:record];
  }
  free(table);

  [processes sortUsingComparator:^NSComparisonResult(NSDictionary *left, NSDictionary *right) {
    return [left[@"name"] compare:right[@"name"]];
  }];
  return processes;
}

/** Every region of a task that begins with an image header. */
+ (NSArray *)imagesOf:(pid_t)pid error:(RVError **)error {
  mach_port_t task = [RVMemory taskFor:pid error:error];
  if (task == MACH_PORT_NULL) return nil;

  NSMutableArray *images = [NSMutableArray array];
  mach_vm_address_t address = 0;
  char mainPath[PROC_PIDPATHINFO_MAXSIZE];
  int mainPathLength = proc_pidpath(pid, mainPath, sizeof(mainPath));

  while (YES) {
    mach_vm_size_t size = 0;
    natural_t depth = 0;
    struct vm_region_submap_info_64 info;
    mach_msg_type_number_t count = VM_REGION_SUBMAP_INFO_COUNT_64;
    kern_return_t result = mach_vm_region_recurse(task,
                                                  &address,
                                                  &size,
                                                  &depth,
                                                  (vm_region_recurse_info_t)&info,
                                                  &count);
    if (result != KERN_SUCCESS) break;
    if (info.is_submap) {
      depth += 1;
      continue;
    }

    if ((info.protection & VM_PROT_READ) != 0 && size >= sizeof(struct mach_header_64)) {
      struct mach_header_64 header;
      if (RVReadTask(task, address, &header, sizeof(header)) && RVIsImageHeader(&header)) {
        size_t commandBytes = MIN((size_t)header.sizeofcmds, (size_t)RV_MAX_LOAD_COMMANDS);
        void *commands = calloc(1, commandBytes + 1);
        if (commands != NULL) {
          if (RVReadTask(task, address + sizeof(header), commands, commandBytes)) {
            NSString *installName = RVInstallName(&header, commands, commandBytes);
            NSString *path = installName;
            if (path == nil && (header.filetype == MH_EXECUTE || header.filetype == MH_DYLINKER)
                && mainPathLength > 0) {
              path = [NSString stringWithUTF8String:mainPath];
            }
            NSMutableDictionary *image = [NSMutableDictionary dictionary];
            image[@"path"] = path ?: @"";
            image[@"base"] = [NSString stringWithFormat:@"0x%llx", (unsigned long long)address];
            mach_vm_size_t span = RVImageSpan(commands, commandBytes);
            image[@"size"] = @((unsigned long long)(span > 0 ? span : size));
            NSString *uuid = RVUUID(commands, commandBytes);
            if (uuid != nil) image[@"uuid"] = uuid;
            image[@"arch"] = header.cpusubtype == CPU_SUBTYPE_ARM64E ? @"arm64e" : @"arm64";
            [images addObject:image];
          }
          free(commands);
        }
      }
    }
    address += size;
  }

  mach_port_deallocate(mach_task_self(), task);
  [images sortUsingComparator:^NSComparisonResult(NSDictionary *left, NSDictionary *right) {
    return [left[@"base"] compare:right[@"base"]];
  }];
  return images;
}

#pragma mark - Symbols

/** Pick the image a selector names: a base address, an install path, or a file name. */
static NSDictionary *RVSelectImage(NSArray<NSDictionary *> *images, NSString *selector) {
  if (selector.length == 0) return images.firstObject;
  if ([selector hasPrefix:@"0x"]) {
    for (NSDictionary *image in images) {
      if ([image[@"base"] isEqualToString:selector]) return image;
    }
  }
  for (NSDictionary *image in images) {
    NSString *path = image[@"path"];
    if ([path isEqualToString:selector] || [path.lastPathComponent isEqualToString:selector]) return image;
    if (path.length > 0 && [path.lastPathComponent isEqualToString:selector.lastPathComponent]) return image;
  }
  return nil;
}

/** The file a selector's symbols are read from. */
static NSString *RVImageFile(NSDictionary *image, pid_t pid) {
  NSString *path = image[@"path"];
  if (path.length > 0 && [[NSFileManager defaultManager] fileExistsAtPath:path]) return path;
  char buffer[PROC_PIDPATHINFO_MAXSIZE];
  if (proc_pidpath(pid, buffer, sizeof(buffer)) > 0) {
    NSString *main = [NSString stringWithUTF8String:buffer];
    if ([image[@"path"] length] == 0 || [[image[@"path"] lastPathComponent] isEqualToString:main.lastPathComponent]) {
      return main;
    }
  }
  return nil;
}

/** Load commands of a file slice's arm64 header, or nil when it has none. */
static NSData *RVSliceCommands(NSData *file, off_t *textVMAddress, uint64_t *baseAddress) {
  const uint8_t *bytes = file.bytes;
  NSUInteger length = file.length;
  if (length < sizeof(struct mach_header_64)) return nil;
  const struct mach_header_64 *header = (const struct mach_header_64 *)bytes;
  if (header->magic != MH_MAGIC_64) return nil;
  NSUInteger commandBytes = MIN((NSUInteger)header->sizeofcmds,
                                length - sizeof(struct mach_header_64));
  NSData *commands = [file subdataWithRange:NSMakeRange(sizeof(struct mach_header_64), commandBytes)];

  const uint8_t *cursor = commands.bytes;
  const uint8_t *end = cursor + commands.length;
  for (uint32_t index = 0; index < header->ncmds && cursor + sizeof(struct load_command) <= end; index++) {
    const struct load_command *command = (const struct load_command *)cursor;
    if (command->cmd == LC_SEGMENT_64 && command->cmdsize >= sizeof(struct segment_command_64)) {
      const struct segment_command_64 *segment = (const struct segment_command_64 *)command;
      if (strcmp(segment->segname, "__TEXT") == 0) {
        *textVMAddress = (off_t)segment->vmaddr;
        if (baseAddress != NULL) *baseAddress = segment->vmaddr;
      }
    }
    if (command->cmdsize < sizeof(struct load_command)) break;
    cursor += command->cmdsize;
  }
  return commands;
}

/** Read a symtab from a file, rebased onto the image's runtime base. */
static NSArray *RVSymbolsFromFile(NSString *file,
                                 uint64_t imageBase,
                                 NSString *filter,
                                 NSUInteger limit,
                                 BOOL *truncated,
                                 RVError **error) {
  NSData *data = [NSData dataWithContentsOfFile:file options:NSDataReadingMappedIfSafe error:nil];
  if (data.length < sizeof(struct mach_header_64)) {
    if (error != NULL) {
      *error = [RVError errorWithCode:RVCodeNotFound message:@"the image's file could not be read on this device"];
    }
    return nil;
  }

  off_t textVM = 0;
  NSData *commands = RVSliceCommands(data, &textVM, NULL);
  if (commands == nil) {
    if (error != NULL) {
      *error = [RVError errorWithCode:RVCodeUnsupported message:@"the image's file has no arm64 Mach-O slice"];
    }
    return nil;
  }

  const struct mach_header_64 *header = (const struct mach_header_64 *)data.bytes;
  int64_t symoff = -1, stroff = -1;
  uint32_t nsyms = 0;

  const uint8_t *cursor = commands.bytes;
  const uint8_t *end = cursor + commands.length;
  for (uint32_t index = 0; index < header->ncmds && cursor + sizeof(struct load_command) <= end; index++) {
    const struct load_command *command = (const struct load_command *)cursor;
    if (command->cmd == LC_SYMTAB && command->cmdsize >= sizeof(struct symtab_command)) {
      const struct symtab_command *symtab = (const struct symtab_command *)command;
      symoff = (int64_t)symtab->symoff;
      stroff = (int64_t)symtab->stroff;
      nsyms = symtab->nsyms;
    }
    if (command->cmdsize < sizeof(struct load_command)) break;
    cursor += command->cmdsize;
  }

  if (symoff < 0 || stroff < 0 || nsyms == 0) {
    if (error != NULL) {
      *error = [RVError errorWithCode:RVCodeUnsupported message:@"the image is stripped: it carries no symbol table"];
    }
    return nil;
  }

  NSMutableArray *symbols = [NSMutableArray array];
  NSUInteger stride = sizeof(struct nlist_64);
  NSString *needle = filter.lowercaseString;
  for (uint32_t index = 0; index < nsyms; index++) {
    if (symbols.count >= limit) {
      *truncated = YES;
      break;
    }
    NSUInteger offset = (NSUInteger)symoff + index * stride;
    if (offset + stride > data.length) break;
    struct nlist_64 entry;
    [data getBytes:&entry range:NSMakeRange(offset, sizeof(entry))];
    if ((entry.n_type & N_STAB) != 0) continue;
    if ((entry.n_type & N_TYPE) != N_SECT) continue;
    if (entry.n_un.n_strx == 0) continue;

    NSUInteger nameOffset = (NSUInteger)stroff + entry.n_un.n_strx;
    if (nameOffset >= data.length) continue;
    const char *nameBytes = (const char *)data.bytes + nameOffset;
    NSUInteger nameLength = strnlen(nameBytes, data.length - nameOffset);
    if (nameLength == 0) continue;
    NSString *name = [[NSString alloc] initWithBytes:nameBytes
                                              length:nameLength
                                            encoding:NSUTF8StringEncoding] ?: @"";
    if (name.length == 0) continue;
    if (needle.length > 0 && ![name.lowercaseString containsString:needle]) continue;

    // Rebase: `n_value` is the link-time vmaddr, and the image's runtime base is
    // where __TEXT's vmaddr landed, so the delta carries the slide.
    uint64_t runtime = imageBase + (entry.n_value - textVM);
    NSString *kind = @"data";
    if ([name hasPrefix:@"_OBJC_CLASS_$_"] || [name hasPrefix:@"_OBJC_METACLASS_$_"]) {
      kind = @"objc-class";
    } else if ([name hasPrefix:@"_$s"] || [name hasPrefix:@"_"]) {
      kind = @"function";
    }
    [symbols addObject:@{
      @"name": name,
      @"address": [NSString stringWithFormat:@"0x%llx", (unsigned long long)runtime],
      @"kind": kind,
    }];
  }
  return symbols;
}

+ (NSArray *)symbolsOf:(pid_t)pid
                 image:(NSString *)image
                filter:(NSString *)filter
                 limit:(NSUInteger)limit
             truncated:(BOOL *)truncated
                 error:(RVError **)error {
  NSArray *images = [self imagesOf:pid error:error];
  if (images == nil) return nil;
  NSDictionary *selected = RVSelectImage(images, image ?: @"");
  if (selected == nil) {
    if (error != NULL) {
      *error = [RVError errorWithCode:RVCodeNotFound message:@"no loaded image matches that selector"];
    }
    return nil;
  }

  NSString *file = RVImageFile(selected, pid);
  if (file == nil) {
    if (error != NULL) {
      *error = [RVError errorWithCode:RVCodeNotFound message:@"the image has no readable file on this device"];
    }
    return nil;
  }

  NSString *baseText = selected[@"base"];
  uint64_t base = 0;
  NSScanner *scanner = [NSScanner scannerWithString:
                        [baseText hasPrefix:@"0x"] ? [baseText substringFromIndex:2] : baseText];
  [scanner scanHexLongLong:&base];

  return RVSymbolsFromFile(file, base, filter ?: @"", limit, truncated, error);
}

@end