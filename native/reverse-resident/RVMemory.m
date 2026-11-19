/*
 * RVMemory.m — reading, searching and overwriting bytes in another process.
 *
 * Every operation goes through `mach_vm_*` on a task right obtained by
 * `task_for_pid`. Writes take the region's own protection as the thing to restore,
 * so a write leaves the target's mapping as it found it: a scan right afterwards
 * must not observe an RWX region the target never had.
 *
 * Nothing here decides whether an operation is allowed. The harness asks the user
 * before a write reaches the socket; the resident's job is to do exactly what the
 * accepted frame says.
 */

#import "RVPrelude.h"

/** Largest block read per step while scanning. */
#define RV_SCAN_CHUNK (4u * 1024u * 1024u)

/** Bytes one scan may compare before it reports a truncated result. */
#define RV_SCAN_BUDGET (512ull * 1024ull * 1024ull)

/** Decode one value of `type` into its little-endian bytes. */
static BOOL RVEncodeValue(NSString *type, NSString *text, uint8_t *buffer, NSUInteger *length, RVError **error) {
  if ([type isEqualToString:@"u8"] || [type isEqualToString:@"i8"]) *length = 1;
  else if ([type isEqualToString:@"u16"] || [type isEqualToString:@"i16"]) *length = 2;
  else if ([type isEqualToString:@"u32"] || [type isEqualToString:@"i32"] || [type isEqualToString:@"float"]) *length = 4;
  else if ([type isEqualToString:@"u64"] || [type isEqualToString:@"i64"] || [type isEqualToString:@"double"]) *length = 8;
  else {
    if (error != NULL) {
      *error = [RVError errorWithCode:RVCodeInvalidArgs
                              message:[NSString stringWithFormat:@"unsupported value type %@", type]];
    }
    return NO;
  }

  if ([type isEqualToString:@"float"]) {
    float value = strtof(text.UTF8String, NULL);
    memcpy(buffer, &value, sizeof(value));
    return YES;
  }
  if ([type isEqualToString:@"double"]) {
    double value = strtod(text.UTF8String, NULL);
    memcpy(buffer, &value, sizeof(value));
    return YES;
  }

  BOOL negative = [text hasPrefix:@"-"];
  NSString *digits = negative ? [text substringFromIndex:1] : text;
  if ([digits hasPrefix:@"0x"] || [digits hasPrefix:@"0X"]) digits = [digits substringFromIndex:2];
  NSScanner *scanner = [NSScanner scannerWithString:digits];
  unsigned long long unsignedValue = 0;
  if (![scanner scanHexLongLong:&unsignedValue] || !scanner.isAtEnd) {
    if (error != NULL) {
      *error = [RVError errorWithCode:RVCodeInvalidArgs
                              message:[NSString stringWithFormat:@"\"%@\" is not a number", text]];
    }
    return NO;
  }

  uint64_t raw = negative
    ? (uint64_t)(-(int64_t)unsignedValue) & 0xffffffffffffffffull
    : unsignedValue;

  switch (*length) {
    case 1: buffer[0] = (uint8_t)(raw & 0xff); break;
    case 2: {
      uint16_t narrowed = (uint16_t)(raw & 0xffff);
      memcpy(buffer, &narrowed, sizeof(narrowed));
      break;
    }
    case 4: {
      uint32_t narrowed = (uint32_t)(raw & 0xffffffff);
      memcpy(buffer, &narrowed, sizeof(narrowed));
      break;
    }
    default: memcpy(buffer, &raw, sizeof(raw)); break;
  }
  return YES;
}

/** Render bytes as the protocol's `hex` and `ascii` pair. */
static void RVRenderBytes(const uint8_t *bytes, NSUInteger length, NSString **hex, NSString **ascii) {
  NSMutableString *hexText = [NSMutableString stringWithCapacity:length * 3];
  NSMutableString *asciiText = [NSMutableString stringWithCapacity:length];
  for (NSUInteger index = 0; index < length; index++) {
    if (index > 0) [hexText appendString:@" "];
    [hexText appendFormat:@"%02x", bytes[index]];
    uint8_t byte = bytes[index];
    [asciiText appendFormat:@"%c", (byte >= 0x20 && byte < 0x7f) ? byte : '.'];
  }
  *hex = hexText;
  *ascii = asciiText;
}

/** Decode the first `length` bytes of a little-endian value into the protocol's text form. */
static NSString *RVDecodeValue(const uint8_t *bytes, NSUInteger length) {
  if (length == 1) return [NSString stringWithFormat:@"%u", bytes[0]];
  if (length == 2) {
    uint16_t value;
    memcpy(&value, bytes, sizeof(value));
    return [NSString stringWithFormat:@"%u", value];
  }
  if (length == 4) {
    uint32_t value;
    memcpy(&value, bytes, sizeof(value));
    return [NSString stringWithFormat:@"%u", value];
  }
  uint64_t value;
  memcpy(&value, bytes, sizeof(value));
  return [NSString stringWithFormat:@"%llu", (unsigned long long)value];
}

@implementation RVMemory

+ (mach_port_t)taskFor:(pid_t)pid error:(RVError **)error {
  if (pid <= 0) {
    if (error != NULL) *error = [RVError errorWithCode:RVCodeInvalidArgs message:@"pid must be positive"];
    return MACH_PORT_NULL;
  }
  mach_port_t task = MACH_PORT_NULL;
  kern_return_t result = task_for_pid(mach_task_self(), pid, &task);
  if (result != KERN_SUCCESS || task == MACH_PORT_NULL) {
    if (error != NULL) {
      *error = [RVError errorWithCode:RVCodeDenied
                              message:[NSString stringWithFormat:
                                       @"task_for_pid(%d) was refused (kern_return %d); the target has "
                                       @"hardened runtime or the resident lacks the task_for_pid entitlement",
                                       pid, result]];
    }
    return MACH_PORT_NULL;
  }
  return task;
}

+ (NSDictionary *)read:(pid_t)pid address:(uint64_t)address length:(NSUInteger)length error:(RVError **)error {
  mach_port_t task = [self taskFor:pid error:error];
  if (task == MACH_PORT_NULL) return nil;

  void *buffer = malloc(length);
  if (buffer == NULL) {
    mach_port_deallocate(mach_task_self(), task);
    if (error != NULL) *error = [RVError errorWithCode:RVCodeRemoteError message:@"out of memory"];
    return nil;
  }

  mach_vm_size_t copied = 0;
  kern_return_t result = mach_vm_read_overwrite(task,
                                                (mach_vm_address_t)address,
                                                (mach_vm_size_t)length,
                                                (mach_vm_address_t)(uintptr_t)buffer,
                                                &copied);
  mach_port_deallocate(mach_task_self(), task);

  if (result != KERN_SUCCESS || copied != length) {
    free(buffer);
    if (error != NULL) {
      *error = [RVError errorWithCode:result == KERN_INVALID_ADDRESS ? RVCodeNotFound : RVCodeRemoteError
                              message:[NSString stringWithFormat:@"reading %lu bytes at 0x%llx failed (kern_return %d)",
                                       (unsigned long)length, (unsigned long long)address, result]];
    }
    return nil;
  }

  NSString *hex = nil, *ascii = nil;
  RVRenderBytes(buffer, length, &hex, &ascii);
  free(buffer);
  return @{
    @"address": [NSString stringWithFormat:@"0x%llx", (unsigned long long)address],
    @"length": @(length),
    @"hex": hex,
    @"ascii": ascii,
  };
}

/** First byte of `needle` inside `haystack`, or NSNotFound. */
static NSUInteger RVFindBytes(const uint8_t *haystack, NSUInteger hayLength,
                              const uint8_t *needle, NSUInteger needleLength) {
  if (needleLength == 0 || hayLength < needleLength) return NSNotFound;
  // Scanned by hand: `memmem` is a GNU extension Darwin does not promise to keep.
  uint8_t first = needle[0];
  for (NSUInteger index = 0; index + needleLength <= hayLength; index++) {
    if (haystack[index] != first) continue;
    if (memcmp(haystack + index, needle, needleLength) == 0) return index;
  }
  return NSNotFound;
}

+ (NSDictionary *)scan:(pid_t)pid
                  type:(NSString *)type
                 value:(NSString *)value
                 limit:(NSUInteger)limit
                  from:(NSNumber *)from
                    to:(NSNumber *)to
                 error:(RVError **)error {
  uint8_t needle[8] = {0};
  NSUInteger needleLength = 0;
  if (!RVEncodeValue(type, value, needle, &needleLength, error)) return nil;

  mach_port_t task = [self taskFor:pid error:error];
  if (task == MACH_PORT_NULL) return nil;

  mach_vm_address_t address = from != nil ? (mach_vm_address_t)from.unsignedLongLongValue : 0;
  mach_vm_address_t ceiling = to != nil ? (mach_vm_address_t)to.unsignedLongLongValue : UINT64_MAX;
  uint8_t *chunk = malloc(RV_SCAN_CHUNK);
  if (chunk == NULL) {
    mach_port_deallocate(mach_task_self(), task);
    if (error != NULL) *error = [RVError errorWithCode:RVCodeRemoteError message:@"out of memory"];
    return nil;
  }

  NSMutableArray *matches = [NSMutableArray array];
  unsigned long long scanned = 0;
  BOOL truncated = NO;

  while (address < ceiling) {
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
    if ((info.protection & VM_PROT_READ) == 0) {
      address += size;
      continue;
    }

    uint64_t regionEnd = MIN((uint64_t)address + size, (uint64_t)ceiling);
    for (uint64_t offset = address; offset < regionEnd; offset += RV_SCAN_CHUNK) {
      if (scanned >= RV_SCAN_BUDGET) {
        truncated = YES;
        break;
      }
      mach_vm_size_t wanted = (mach_vm_size_t)MIN((uint64_t)RV_SCAN_CHUNK, regionEnd - offset);
      mach_vm_size_t copied = 0;
      kern_return_t readResult = mach_vm_read_overwrite(task,
                                                       (mach_vm_address_t)offset,
                                                       wanted,
                                                       (mach_vm_address_t)(uintptr_t)chunk,
                                                       &copied);
      if (readResult != KERN_SUCCESS || copied == 0) continue;
      scanned += copied;

      NSUInteger cursor = 0;
      while (cursor < copied) {
        NSUInteger hit = RVFindBytes(chunk + cursor, copied - cursor, needle, needleLength);
        if (hit == NSNotFound) break;
        NSUInteger absolute = cursor + hit;
        [matches addObject:@{
          @"address": [NSString stringWithFormat:@"0x%llx", (unsigned long long)(offset + absolute)],
          @"value": RVDecodeValue(chunk + absolute, needleLength),
        }];
        if (matches.count >= limit) {
          truncated = YES;
          break;
        }
        cursor = absolute + needleLength;
      }
      if (truncated) break;
    }
    if (truncated) break;
    address = (mach_vm_address_t)regionEnd;
  }

  free(chunk);
  mach_port_deallocate(mach_task_self(), task);
  return @{ @"matches": matches, @"scannedBytes": @(scanned), @"truncated": @(truncated) };
}

+ (NSDictionary *)write:(pid_t)pid
                address:(uint64_t)address
                   type:(NSString *)type
                  value:(NSString *)value
                  error:(RVError **)error {
  uint8_t needle[8] = {0};
  NSUInteger length = 0;
  if (!RVEncodeValue(type, value, needle, &length, error)) return nil;

  mach_port_t task = [self taskFor:pid error:error];
  if (task == MACH_PORT_NULL) return nil;

  // The bytes being replaced, so the answer says what changed.
  uint8_t previous[8] = {0};
  mach_vm_size_t copied = 0;
  kern_return_t readResult = mach_vm_read_overwrite(task,
                                                   (mach_vm_address_t)address,
                                                   length,
                                                   (mach_vm_address_t)(uintptr_t)previous,
                                                   &copied);
  if (readResult != KERN_SUCCESS || copied != length) {
    mach_port_deallocate(mach_task_self(), task);
    if (error != NULL) {
      *error = [RVError errorWithCode:RVCodeNotFound
                              message:[NSString stringWithFormat:@"0x%llx is not readable, so it cannot be written",
                                       (unsigned long long)address]];
    }
    return nil;
  }

  // Take the region's own protection as what to restore afterwards.
  mach_vm_address_t regionAddress = (mach_vm_address_t)address;
  mach_vm_size_t regionSize = 0;
  natural_t depth = 0;
  struct vm_region_submap_info_64 info;
  mach_msg_type_number_t count = VM_REGION_SUBMAP_INFO_COUNT_64;
  kern_return_t regionResult = mach_vm_region_recurse(task,
                                                      &regionAddress,
                                                      &regionSize,
                                                      &depth,
                                                      (vm_region_recurse_info_t)&info,
                                                      &count);
  vm_prot_t original = regionResult == KERN_SUCCESS ? (vm_prot_t)info.protection : (VM_PROT_READ | VM_PROT_WRITE);

  kern_return_t protectResult = mach_vm_protect(task,
                                               (mach_vm_address_t)address,
                                               length,
                                               0,
                                               VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY);
  if (protectResult != KERN_SUCCESS) {
    mach_port_deallocate(mach_task_self(), task);
    if (error != NULL) {
      *error = [RVError errorWithCode:RVCodeDenied
                              message:[NSString stringWithFormat:@"0x%llx is not writable (kern_return %d)",
                                       (unsigned long long)address, protectResult]];
    }
    return nil;
  }

  kern_return_t writeResult = mach_vm_write(task,
                                           (mach_vm_address_t)address,
                                           (vm_offset_t)(uintptr_t)needle,
                                           (mach_msg_type_number_t)length);
  mach_vm_protect(task, (mach_vm_address_t)address, length, 0, original);
  mach_port_deallocate(mach_task_self(), task);

  if (writeResult != KERN_SUCCESS) {
    if (error != NULL) {
      *error = [RVError errorWithCode:RVCodeRemoteError
                              message:[NSString stringWithFormat:@"writing 0x%llx failed (kern_return %d)",
                                       (unsigned long long)address, writeResult]];
    }
    return nil;
  }

  return @{
    @"address": [NSString stringWithFormat:@"0x%llx", (unsigned long long)address],
    @"previous": RVDecodeValue(previous, length),
    @"written": RVDecodeValue(needle, length),
  };
}

@end