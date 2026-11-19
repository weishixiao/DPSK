/*
 * RVMachO.m — the structural report for one file on disk.
 *
 * Analysis reads the file, never the target process: a binary is what the App Store
 * shipped (or what the user built), and reporting its load commands, sections and
 * Objective-C names is what tells an analyst whether hooking it is plausible at all.
 * The arm64e slice is preferred, because that is the slice the device runs.
 */

#import "RVPrelude.h"

/** Printable strings shorter than this are noise. */
#define RV_MIN_STRING 9u

/** Arch name of a CPU type and subtype pair. */
static NSString *RVArchName(cpu_type_t type, cpu_subtype_t subtype) {
  if (type != CPU_TYPE_ARM64) return [NSString stringWithFormat:@"cputype-%d", type];
  if ((subtype & 0xff) == CPU_SUBTYPE_ARM64E) return @"arm64e";
  if ((subtype & 0xff) == CPU_SUBTYPE_ARM64_V8) return @"arm64v8";
  return @"arm64";
}

/** Platform name of an LC_BUILD_VERSION platform value. */
static NSString *RVPlatformName(uint32_t platform) {
  switch (platform) {
    case 1: return @"macos";
    case 2: return @"ios";
    case 3: return @"tvos";
    case 4: return @"watchos";
    case 5: return @"bridgeos";
    case 6: return @"maccatalyst";
    case 7: return @"ios-simulator";
    case 8: return @"tvos-simulator";
    case 9: return @"watchos-simulator";
    case 10: return @"driverkit";
    case 11: return @"visionos";
    default: return [NSString stringWithFormat:@"platform-%u", platform];
  }
}

/** The arm64 slice of a file, or the whole file when it is not fat. */
static NSData *RVSlice(NSData *file, uint64_t *sliceOffsetOut) {
  const uint8_t *bytes = file.bytes;
  if (file.length < sizeof(struct fat_header)) return file;

  uint32_t magic = 0;
  memcpy(&magic, bytes, sizeof(magic));
  if (magic != FAT_MAGIC && magic != FAT_CIGAM) {
    *sliceOffsetOut = 0;
    return file;
  }

  struct fat_header header;
  [file getBytes:&header range:NSMakeRange(0, sizeof(header))];
  BOOL swapped = magic == FAT_CIGAM;
  uint32_t count = swapped ? OSSwapInt32(header.nfat_arch) : header.nfat_arch;
  NSUInteger cursor = sizeof(header);

  uint32_t chosenOffset = 0, chosenSize = 0;
  BOOL chosenArm64e = NO;
  for (uint32_t index = 0; index < count; index++) {
    if (cursor + sizeof(struct fat_arch) > file.length) break;
    struct fat_arch arch;
    [file getBytes:&arch range:NSMakeRange(cursor, sizeof(arch))];
    cursor += sizeof(arch);
    cpu_type_t type = (cpu_type_t)(swapped ? OSSwapInt32((uint32_t)arch.cputype) : (uint32_t)arch.cputype);
    cpu_subtype_t subtype = (cpu_subtype_t)(swapped ? OSSwapInt32((uint32_t)arch.cpusubtype) : (uint32_t)arch.cpusubtype);
    uint32_t offset = swapped ? OSSwapInt32(arch.offset) : arch.offset;
    uint32_t size = swapped ? OSSwapInt32(arch.size) : arch.size;
    if (type != CPU_TYPE_ARM64) continue;
    BOOL isArm64e = (subtype & 0xff) == CPU_SUBTYPE_ARM64E;
    if (chosenOffset == 0 || (isArm64e && !chosenArm64e)) {
      chosenOffset = offset;
      chosenSize = size;
      chosenArm64e = isArm64e;
    }
  }
  if (chosenOffset == 0 || (uint64_t)chosenOffset + chosenSize > file.length) {
    *sliceOffsetOut = 0;
    return nil;
  }
  *sliceOffsetOut = chosenOffset;
  return [file subdataWithRange:NSMakeRange(chosenOffset, chosenSize)];
}

/** Every NUL-terminated string inside one file range, filtered and capped. */
static void RVCollectStrings(NSData *slice, uint64_t offset, uint64_t size,
                             NSUInteger limit, NSMutableArray<NSString *> *out) {
  if (size == 0 || offset + size > slice.length) return;
  const uint8_t *bytes = (const uint8_t *)slice.bytes + offset;
  NSUInteger index = 0;
  while (index < size && out.count < limit) {
    NSUInteger start = index;
    while (index < size && bytes[index] >= 0x20 && bytes[index] < 0x7f) index++;
    NSUInteger length = index - start;
    if (length >= RV_MIN_STRING && out.count < limit) {
      NSString *text = [[NSString alloc] initWithBytes:bytes + start
                                                length:length
                                              encoding:NSUTF8StringEncoding];
      if (text.length >= RV_MIN_STRING) [out addObject:text];
    }
    index++;
  }
}

@implementation RVMachO

+ (NSDictionary *)analyzePath:(NSString *)path stringsLimit:(NSUInteger)limit error:(RVError **)error {
  if (![path hasPrefix:@"/"]) {
    if (error != NULL) {
      *error = [RVError errorWithCode:RVCodeInvalidArgs message:@"path must be absolute"];
    }
    return nil;
  }

  NSError *readError = nil;
  NSData *file = [NSData dataWithContentsOfFile:path options:NSDataReadingMappedIfSafe error:&readError];
  if (file == nil) {
    if (error != NULL) {
      *error = [RVError errorWithCode:RVCodeNotFound
                              message:[NSString stringWithFormat:@"%@ could not be read: %@",
                                       path, readError.localizedDescription ?: @"no reason given"]];
    }
    return nil;
  }

  uint64_t sliceOffset = 0;
  NSData *slice = RVSlice(file, &sliceOffset);
  if (slice == nil || slice.length < sizeof(struct mach_header_64)) {
    if (error != NULL) {
      *error = [RVError errorWithCode:RVCodeUnsupported message:@"the file has no arm64 Mach-O slice"];
    }
    return nil;
  }

  struct mach_header_64 header;
  [slice getBytes:&header range:NSMakeRange(0, sizeof(header))];
  if (header.magic != MH_MAGIC_64) {
    if (error != NULL) {
      *error = [RVError errorWithCode:RVCodeUnsupported message:@"the arm64 slice is not a 64-bit Mach-O image"];
    }
    return nil;
  }

  NSUInteger commandBytes = MIN((NSUInteger)header.sizeofcmds, slice.length - sizeof(header));
  NSData *commands = [slice subdataWithRange:NSMakeRange(sizeof(header), commandBytes)];

  NSMutableArray *dependencies = [NSMutableArray array];
  NSMutableArray *sections = [NSMutableArray array];
  NSMutableArray *strings = [NSMutableArray array];
  NSMutableArray<NSValue *> *stringSections = [NSMutableArray array];
  NSString *platform = @"unknown";
  BOOL encrypted = NO;
  uint32_t symbolCount = 0;

  const uint8_t *cursor = commands.bytes;
  const uint8_t *end = cursor + commands.length;
  for (uint32_t index = 0; index < header.ncmds && cursor + sizeof(struct load_command) <= end; index++) {
    const struct load_command *command = (const struct load_command *)cursor;
    switch (command->cmd) {
      case LC_SEGMENT_64: {
        if (command->cmdsize < sizeof(struct segment_command_64)) break;
        const struct segment_command_64 *segment = (const struct segment_command_64 *)command;
        const struct section_64 *section = (const struct section_64 *)(cursor + sizeof(*segment));
        for (uint32_t sectionIndex = 0;
             sectionIndex < segment->nsects && (const uint8_t *)(section + 1) <= end;
             sectionIndex++, section++) {
          [sections addObject:@{
            @"segment": [[NSString alloc] initWithBytes:section->segname length:16 encoding:NSUTF8StringEncoding]
              ?: @"",
            @"name": [[NSString alloc] initWithBytes:section->sectname length:16 encoding:NSUTF8StringEncoding]
              ?: @"",
            @"address": [NSString stringWithFormat:@"0x%llx", (unsigned long long)section->addr],
            @"size": @(section->size),
          }];
          // __cstring and the Objective-C name tables are where printable text lives.
          if (strncmp(section->sectname, "__cstring", 16) == 0
              || strncmp(section->sectname, "__objc_methname", 16) == 0
              || strncmp(section->sectname, "__objc_classname", 16) == 0) {
            [stringSections addObject:[NSValue valueWithBytes:&section->offset objCType:@encode(uint32_t)]];
          }
        }
        break;
      }
      case LC_LOAD_DYLIB:
      case LC_LOAD_WEAK_DYLIB:
      case LC_REEXPORT_DYLIB:
      case LC_LOAD_UPWARD_DYLIB: {
        if (command->cmdsize < sizeof(struct dylib_command)) break;
        const struct dylib_command *dylib = (const struct dylib_command *)command;
        const char *name = (const char *)cursor + dylib->dylib.name.offset;
        [dependencies addObject:@{
          @"name": [NSString stringWithUTF8String:name] ?: @"",
          @"weak": @(command->cmd == LC_LOAD_WEAK_DYLIB),
        }];
        break;
      }
      case LC_ENCRYPTION_INFO_64: {
        if (command->cmdsize >= sizeof(struct encryption_info_command_64)) {
          const struct encryption_info_command_64 *encryption = (const struct encryption_info_command_64 *)command;
          encrypted = encryption->cryptid != 0;
        }
        break;
      }
      case LC_BUILD_VERSION: {
        if (command->cmdsize >= sizeof(struct build_version_command)) {
          const struct build_version_command *version = (const struct build_version_command *)command;
          platform = RVPlatformName(version->platform);
        }
        break;
      }
      case LC_VERSION_MIN_IPHONEOS:
        if ([platform isEqualToString:@"unknown"]) platform = @"ios";
        break;
      case LC_SYMTAB: {
        if (command->cmdsize >= sizeof(struct symtab_command)) {
          symbolCount = ((const struct symtab_command *)command)->nsyms;
        }
        break;
      }
      default:
        break;
    }
    if (command->cmdsize < sizeof(struct load_command)) break;
    cursor += command->cmdsize;
  }

  for (NSValue *wrapper in stringSections) {
    uint32_t offset = 0;
    [wrapper getValue:&offset];
    if (offset == 0 || offset >= slice.length) continue;
    // The section's own length is not in the wrapper; the rest of the slice bounds it.
    NSUInteger available = MIN((NSUInteger)(slice.length - offset), (NSUInteger)1024 * 1024);
    RVCollectStrings(slice, offset, available, limit, strings);
  }
  if (strings.count == 0 && limit > 0) {
    RVCollectStrings(slice, sizeof(header) + commandBytes, slice.length - sizeof(header) - commandBytes, limit, strings);
  }

  NSMutableArray<NSString *> *objcClasses = [NSMutableArray array];
  NSMutableArray<NSString *> *objcMethods = [NSMutableArray array];
  for (NSString *text in strings) {
    if ([text hasPrefix:@"_OBJC_CLASS_$_"] || [text hasPrefix:@"OBJC_CLASS_$_"]) {
      [objcClasses addObject:[text stringByReplacingOccurrencesOfString:@"_OBJC_CLASS_$_" withString:@""]];
    } else if ([text containsString:@":"] && [text hasPrefix:@"_"]) {
      // A method name table entry looks like `_selector` or `_initWithFrame:`.
      if ([objcMethods count] < limit) [objcMethods addObject:text];
    }
  }

  uint64_t size = 0;
  NSDictionary *attributes = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:nil];
  size = [attributes[NSFileSize] unsignedLongLongValue];

  return @{
    @"path": path,
    @"size": @(size > 0 ? size : file.length),
    @"arch": RVArchName(header.cputype, header.cpusubtype),
    @"platform": platform,
    @"executable": @(header.filetype == MH_EXECUTE),
    @"encrypted": @(encrypted),
    @"flags": @(header.flags),
    @"dependencies": dependencies,
    @"sections": sections,
    @"objcClasses": objcClasses,
    @"objcMethods": objcMethods,
    @"symbolCount": @(symbolCount),
    @"strings": strings,
  };
}

@end