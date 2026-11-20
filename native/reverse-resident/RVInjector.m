/*
 * RVInjector.m — getting code into a running process, and calling it.
 *
 * Two jobs, one mechanism. Injecting a dylib and running an exported entry point
 * are both "call one already-mapped function inside the target", so both go through
 * `RVInvokeRemote`: allocate a small executable stub in the target, point a new
 * thread at it, and have the stub call an address we name.
 *
 * Why a stub instead of `thread_create_running` with PC = dlopen:
 *
 *   - the stub calls through a register, so the target runs its own code path and
 *     returns into the stub, which parks in a spin instead of falling off the end
 *     of the address space;
 *   - the return value is written to a slot in the target, so this side learns
 *     whether `dlopen` succeeded without a second round trip or a guess.
 *
 * The address need not be "the target's" copy: system libraries are mapped from the
 * shared cache at one slide per boot, so `dlsym` in this process and in the target
 * agree for anything in dyld/libSystem. Addresses of code inside a non-system image
 * are resolved from that image's symbol table instead, rebased onto the target's
 * load address.
 *
 * Arm64 constants are written out rather than assembled: this file has no compiler
 * at build time beyond clang itself, and spelling five instructions as hex keeps the
 * stub auditable. `RVStubWords` documents each one.
 */

#import "RVPrelude.h"

#import <signal.h>
#import <unistd.h>
#import <mach/arm/thread_status.h>
#import <mach/thread_act.h>
#import <mach/task.h>
#import <mach-o/fat.h>

/** Bytes of the code page the stub lives in; one page covers code and literals. */
#define RV_STUB_BYTES 4096u

/** Bytes of stack for the remote thread. `dlopen` recurses through dyld. */
#define RV_STACK_BYTES (64u * 1024u)

/** How long a remote call may take before the thread is torn down. */
#define RV_DEFAULT_WAIT_MS 5000u

/** Polling interval while waiting for the stub's result slot. */
#define RV_POLL_INTERVAL_MS 10u

/** Largest image this resolves symbols from, as a guard on the mmap. */
#define RV_MAX_IMAGE_BYTES (512ull * 1024ull * 1024ull)

/** The marshalling calls, declared here: the iPhoneOS SDK ships mach_vm.h as a stub. */
extern kern_return_t mach_vm_allocate(vm_map_t target_task,
                                      mach_vm_address_t *address,
                                      mach_vm_size_t size,
                                      int flags);

extern kern_return_t mach_vm_deallocate(vm_map_t target_task,
                                        mach_vm_address_t address,
                                        mach_vm_size_t size);

/** `RTLD_NOW`, spelled out so the stub's immediate is not a guess about dlfcn.h. */
#define RV_RTLD_NOW 0x2

#pragma mark - The stub

/*
 * RVStubWords, at byte offsets:
 *
 *   0x00  ldr x16, #40      0x58000150  ; x16 = *(stub + 0x28) = the function
 *   0x04  movz x1, #2       0xD2800041  ; RTLD_NOW
 *   0x08  blr x16           0xD63F0200  ; call it (x0 came from the thread state)
 *   0x0C  ldr x17, #36      0x58000131  ; x17 = *(stub + 0x30) = the result slot
 *   0x10  str x0, [x17]     0xF9000220  ; publish the return value
 *   0x14  ldr x18, #36      0x58000132  ; x18 = *(stub + 0x38) = the completion flag
 *   0x18  movz x19, #1      0xD2800033  ; "the call returned"
 *   0x1C  str x19, [x18]    0xF9000253  ; publish the flag LAST, after the value
 *   0x20  b .               0x14000000  ; park here until the caller kills us
 *   0x28  (u64) function address
 *   0x30  (u64) result slot address
 *   0x38  (u64) flag slot address
 *
 * The flag exists because a return value of zero is a real answer: `dlopen` hands
 * back NULL when it fails, and "not written yet" must not be confused with "wrote
 * zero". The flag is stored after the value, so a reader that sees the flag also
 * sees the value it belongs to.
 *
 * `b .` is deliberate: the thread must never return, because there is no caller to
 * return to. This side terminates it with `thread_terminate` once the flag is read.
 */
static const uint32_t RVStubWords[] = {
  0x58000150u,
  0xD2800041u,
  0xD63F0200u,
  0x58000131u,
  0xF9000220u,
  0x58000132u,
  0xD2800033u,
  0xF9000253u,
  0x14000000u,
};

/** Offset of the function-address literal inside the stub page. */
#define RV_STUB_FUNCTION_OFFSET 0x28u

/** Offset of the result-slot literal inside the stub page. */
#define RV_STUB_RESULT_OFFSET 0x30u

/** Offset of the completion-flag literal inside the stub page. */
#define RV_STUB_FLAG_OFFSET 0x38u

#pragma mark - Remote primitives

/** True when `pid` names a live process this device lets us look at. */
static BOOL RVPidIsLive(pid_t pid) {
  return pid > 0 && kill(pid, 0) == 0;
}

/**
 * Read a process's main executable path, for messages that name the target.
 * @param pid - target.
 * @returns the path, or the pid as text when it cannot be read.
 */
static NSString *RVTargetLabel(pid_t pid) {
  char buffer[PROC_PIDPATHINFO_MAXSIZE];
  if (proc_pidpath(pid, buffer, sizeof(buffer)) > 0) {
    return [NSString stringWithUTF8String:buffer] ?: [NSString stringWithFormat:@"pid %d", pid];
  }
  return [NSString stringWithFormat:@"pid %d", pid];
}

/**
 * Call one function in another process and read back what it returned.
 *
 * Allocates the stub, a stack and a result slot in the target, runs a thread from
 * the stub, waits for the slot to fill, then tears all of it down. The target is
 * never suspended: a freshly allocated page has never been executed, so there is no
 * stale instruction cache to flush, and freezing a foreground app to poke at it is a
 * worse failure mode than the race this leaves.
 *
 * @param task - a send right for the target, owned by the caller.
 * @param targetPid - the pid behind `task`, for messages that name the target.
 * @param function - address of the function as seen by the target.
 * @param argument - value for x0 (a pointer, where the callee takes one).
 * @param waitMs - how long the flag may take to appear.
 * @param result - receives the callee's x0.
 * @param error - why the call could not be made or did not return.
 * @returns YES when the callee ran and published a result.
 */
static BOOL RVInvokeRemote(mach_port_t task,
                           pid_t targetPid,
                           uint64_t function,
                           uint64_t argument,
                           uint32_t waitMs,
                           uint64_t *result,
                           RVError **error) {
  mach_vm_address_t stub = 0;
  mach_vm_address_t stack = 0;
  mach_vm_address_t slot = 0;
  thread_t thread = MACH_PORT_NULL;
  BOOL invoked = NO;

  kern_return_t allocated = mach_vm_allocate(task, &stub, RV_STUB_BYTES, VM_FLAGS_ANYWHERE);
  if (allocated != KERN_SUCCESS) {
    if (error != NULL) {
      *error = [RVError errorWithCode:RVCodeDenied
                              message:[NSString stringWithFormat:
                                         @"could not allocate a stub in the target (kern_return %d); "
                                         @"the target refuses foreign mappings", allocated]];
    }
    return NO;
  }
  if (mach_vm_allocate(task, &stack, RV_STACK_BYTES, VM_FLAGS_ANYWHERE) != KERN_SUCCESS
      || mach_vm_allocate(task, &slot, RV_STUB_BYTES, VM_FLAGS_ANYWHERE) != KERN_SUCCESS) {
    if (error != NULL) {
      *error = [RVError errorWithCode:RVCodeDenied message:@"could not allocate the remote stack or result slot"];
    }
    goto cleanup;
  }

  {
    // One page: instructions at 0, literals at 0x28/0x30/0x38.
    uint8_t page[RV_STUB_BYTES];
    memset(page, 0, sizeof(page));
    memcpy(page, RVStubWords, sizeof(RVStubWords));
    uint64_t functionLiteral = function;
    uint64_t resultLiteral = (uint64_t)slot;
    uint64_t flagLiteral = (uint64_t)(slot + 8);
    memcpy(page + RV_STUB_FUNCTION_OFFSET, &functionLiteral, sizeof(functionLiteral));
    memcpy(page + RV_STUB_RESULT_OFFSET, &resultLiteral, sizeof(resultLiteral));
    memcpy(page + RV_STUB_FLAG_OFFSET, &flagLiteral, sizeof(flagLiteral));

    if (mach_vm_write(task, stub, (vm_offset_t)page, (mach_msg_type_number_t)sizeof(page)) != KERN_SUCCESS) {
      if (error != NULL) {
        *error = [RVError errorWithCode:RVCodeDenied message:@"could not write the stub into the target"];
      }
      goto cleanup;
    }
    if (mach_vm_protect(task, stub, RV_STUB_BYTES, FALSE, VM_PROT_READ | VM_PROT_EXECUTE) != KERN_SUCCESS) {
      if (error != NULL) {
        *error = [RVError errorWithCode:RVCodeDenied
                                message:@"could not make the stub executable in the target"];
      }
      goto cleanup;
    }
  }

  {
    arm_thread_state64_t state;
    memset(&state, 0, sizeof(state));
    state.__x[0] = argument;
    state.__x[1] = RV_RTLD_NOW;
    state.__sp = (uint64_t)(stack + RV_STACK_BYTES);
    state.__pc = (uint64_t)stub;
    state.__lr = 0;

    kern_return_t created = thread_create_running(task,
                                                  ARM_THREAD_STATE64,
                                                  (thread_state_t)&state,
                                                  ARM_THREAD_STATE64_COUNT,
                                                  &thread);
    if (created != KERN_SUCCESS) {
      if (error != NULL) {
        *error = [RVError errorWithCode:RVCodeDenied
                                message:[NSString stringWithFormat:
                                           @"the target refused a remote thread (kern_return %d); "
                                           @"it is running in a mode that disallows task port injection",
                                           created]];
      }
      goto cleanup;
    }
  }

  {
    // The flag is read first and the value second, in that order: the stub writes
    // the value before the flag, so a flag that reads as 1 means the value is final.
    uint64_t flag = 0;
    uint32_t waited = 0;
    while (waited < waitMs) {
      mach_vm_size_t copied = 0;
      kern_return_t read = mach_vm_read_overwrite(task,
                                                  slot + 8,
                                                  sizeof(flag),
                                                  (mach_vm_address_t)(uintptr_t)&flag,
                                                  &copied);
      if (read == KERN_SUCCESS && copied == sizeof(flag) && flag != 0) {
        uint64_t value = 0;
        if (mach_vm_read_overwrite(task,
                                   slot,
                                   sizeof(value),
                                   (mach_vm_address_t)(uintptr_t)&value,
                                   &copied) == KERN_SUCCESS && copied == sizeof(value)) {
          invoked = YES;
          if (result != NULL) *result = value;
        }
        break;
      }
      usleep(RV_POLL_INTERVAL_MS * 1000u);
      waited += RV_POLL_INTERVAL_MS;
    }
    if (!invoked && error != NULL) {
      *error = [RVError errorWithCode:RVCodeTimeout
                              message:[NSString stringWithFormat:
                                         @"the remote call in %@ returned nothing within %u ms; "
                                         @"it was stopped and the thread killed",
                                         RVTargetLabel(targetPid), waitMs]];
    }
  }

cleanup:
  if (thread != MACH_PORT_NULL) {
    thread_terminate(thread);
    mach_port_deallocate(mach_task_self(), thread);
  }
  if (stub != 0) mach_vm_deallocate(task, stub, RV_STUB_BYTES);
  if (stack != 0) mach_vm_deallocate(task, stack, RV_STACK_BYTES);
  if (slot != 0) mach_vm_deallocate(task, slot, RV_STUB_BYTES);
  return invoked;
}

#pragma mark - Symbols

/**
 * Rebase one symbol table entry onto the target's load address.
 * @param base - target's load address for the image.
 * @param textVmaddr - linked vmaddr of `__TEXT` (usually zero for a dylib).
 * @param value - `n_value` of the symbol.
 * @returns the address the target would use.
 */
static uint64_t RVRebase(uint64_t base, uint64_t textVmaddr, uint64_t value) {
  return base + (value - textVmaddr);
}

/**
 * Find one symbol in one mapped image of a target.
 * @param pid - target process.
 * @param selector - image selector from the caller: install path, file name, or `base`.
 * @param name - symbol to find, exact or as a suffix of a mangled name.
 * @param error - why the lookup failed.
 * @returns the symbol's runtime address, or 0 with `error` set.
 */
static uint64_t RVLookupInImages(pid_t pid, NSString *selector, NSString *name, RVError **error) {
  NSArray<NSDictionary *> *images = [RVProcess imagesOf:pid error:error];
  if (images == nil) return 0;

  NSMutableArray<NSDictionary *> *candidates = [NSMutableArray array];
  for (NSDictionary *image in images) {
    if (selector.length == 0) {
      [candidates addObject:image];
      continue;
    }
    NSString *path = image[@"path"];
    if ([path isEqualToString:selector]
        || [path.lastPathComponent isEqualToString:selector]
        || [image[@"base"] isEqualToString:selector]) {
      [candidates addObject:image];
    }
  }

  for (NSDictionary *image in candidates) {
    NSString *path = image[@"path"];
    if (path.length == 0) continue;
    NSData *file = [NSData dataWithContentsOfFile:path
                                          options:NSDataReadingMappedIfSafe
                                            error:nil];
    if (file == nil || file.length > RV_MAX_IMAGE_BYTES || file.length < sizeof(struct mach_header_64)) {
      continue;
    }
    const struct mach_header_64 *header = (const struct mach_header_64 *)file.bytes;
    if (header->magic != MH_MAGIC_64 || header->cputype != CPU_TYPE_ARM64) continue;

    const uint8_t *cursor = (const uint8_t *)file.bytes + sizeof(struct mach_header_64);
    const uint8_t *end = cursor + header->sizeofcmds;
    if ((const uint8_t *)file.bytes + file.length < end) continue;

    const struct symtab_command *symbols = NULL;
    uint64_t textVmaddr = 0;
    for (uint32_t index = 0; index < header->ncmds; index += 1) {
      if (cursor + sizeof(struct load_command) > end) break;
      const struct load_command *command = (const struct load_command *)cursor;
      if (command->cmdsize < sizeof(struct load_command) || cursor + command->cmdsize > end) break;
      if (command->cmd == LC_SEGMENT_64) {
        const struct segment_command_64 *segment = (const struct segment_command_64 *)cursor;
        if (strncmp(segment->segname, "__TEXT", sizeof(segment->segname)) == 0) {
          textVmaddr = segment->vmaddr;
        }
      } else if (command->cmd == LC_SYMTAB) {
        symbols = (const struct symtab_command *)cursor;
      }
      cursor += command->cmdsize;
    }
    if (symbols == NULL) continue;

    const struct nlist_64 *table = (const struct nlist_64 *)((const uint8_t *)file.bytes + symbols->symoff);
    const char *strings = (const char *)file.bytes + symbols->stroff;
    if ((const uint8_t *)table + (size_t)symbols->nsyms * sizeof(struct nlist_64) > (const uint8_t *)file.bytes + file.length) {
      continue;
    }
    if (symbols->stroff + symbols->strsize > file.length) continue;

    uint64_t loadAddress = strtoull([image[@"base"] UTF8String], NULL, 0);
    for (uint32_t index = 0; index < symbols->nsyms; index += 1) {
      const struct nlist_64 *entry = &table[index];
      if ((entry->n_type & N_STAB) != 0) continue;
      if ((entry->n_type & N_TYPE) != N_SECT) continue;
      if (entry->n_un.n_strx == 0 || entry->n_un.n_strx >= symbols->strsize) continue;
      const char *raw = strings + entry->n_un.n_strx;
      NSString *symbol = [NSString stringWithUTF8String:raw];
      if (symbol == nil) continue;
      BOOL matches = [symbol isEqualToString:name]
        || [symbol isEqualToString:[@"_" stringByAppendingString:name]]
        || [symbol hasSuffix:[@"_" stringByAppendingString:name]];
      if (!matches) continue;
      return RVRebase(loadAddress, textVmaddr, entry->n_value);
    }
  }

  if (error != NULL) {
    *error = [RVError errorWithCode:RVCodeNotFound
                            message:[NSString stringWithFormat:
                                       @"no symbol %@ in %@ of %@",
                                       name,
                                       selector.length == 0 ? @"any image" : selector,
                                       RVTargetLabel(pid)]];
  }
  return 0;
}

#pragma mark - Public surface

@implementation RVInjector

+ (uint64_t)addressOf:(NSString *)symbol
            inProcess:(pid_t)pid
                image:(NSString *)selector
                error:(RVError **)error {
  if (symbol.length == 0) {
    if (error != NULL) *error = [RVError errorWithCode:RVCodeInvalidArgs message:@"symbol must not be empty"];
    return 0;
  }

  // A symbol of a system library lives in the shared cache at one address for every
  // process, so this process's binding is the target's too.
  void *local = dlsym(RTLD_DEFAULT, symbol.UTF8String);
  if (local != NULL && selector.length == 0) return (uint64_t)(uintptr_t)local;

  return RVLookupInImages(pid, selector, symbol, error);
}

+ (NSDictionary *)inject:(pid_t)pid
               dylibPath:(NSString *)path
                  caller:(uint64_t)callerAddress
                   error:(RVError **)error {
  if (!RVPidIsLive(pid)) {
    if (error != NULL) {
      *error = [RVError errorWithCode:RVCodeTargetGone
                              message:[NSString stringWithFormat:@"pid %d is no longer running", pid]];
    }
    return nil;
  }

  NSFileManager *files = [NSFileManager defaultManager];
  if (path.length == 0 || ![path isAbsolutePath]) {
    if (error != NULL) {
      *error = [RVError errorWithCode:RVCodeInvalidArgs
                              message:@"dylibPath must be an absolute path"];
    }
    return nil;
  }
  BOOL directory = NO;
  if (![files fileExistsAtPath:path isDirectory:&directory] || directory) {
    if (error != NULL) {
      *error = [RVError errorWithCode:RVCodeNotFound
                              message:[NSString stringWithFormat:@"%@ is not a file", path]];
    }
    return nil;
  }
  if (![files isReadableFileAtPath:path]) {
    if (error != NULL) {
      *error = [RVError errorWithCode:RVCodeDenied
                              message:[NSString stringWithFormat:
                                         @"%@ is not readable by SpringBoard; install it under the "
                                         @"jailbreak root so the resident can open it", path]];
    }
    return nil;
  }

  mach_port_t task = [RVMemory taskFor:pid error:error];
  if (task == MACH_PORT_NULL) return nil;

  // The target's own `dlopen`. Nothing in the shared cache moves between processes.
  uint64_t remoteDlopen = (uint64_t)(uintptr_t)dlsym(RTLD_DEFAULT, "dlopen");
  if (remoteDlopen == 0) {
    if (error != NULL) {
      *error = [RVError errorWithCode:RVCodeUnsupported
                              message:@"this process has no dlopen binding to call in the target"];
    }
    mach_port_deallocate(mach_task_self(), task);
    return nil;
  }

  // The path has to live in the target for the duration of the call.
  NSData *encoded = [path dataUsingEncoding:NSUTF8StringEncoding];
  mach_vm_address_t remotePath = 0;
  mach_vm_size_t pathBytes = (mach_vm_size_t)encoded.length + 1;
  if (mach_vm_allocate(task, &remotePath, pathBytes, VM_FLAGS_ANYWHERE) != KERN_SUCCESS
      || mach_vm_write(task, remotePath, (vm_offset_t)encoded.bytes, (mach_msg_type_number_t)encoded.length) != KERN_SUCCESS) {
    if (error != NULL) {
      *error = [RVError errorWithCode:RVCodeDenied message:@"could not place the dylib path in the target"];
    }
    if (remotePath != 0) mach_vm_deallocate(task, remotePath, pathBytes);
    mach_port_deallocate(mach_task_self(), task);
    return nil;
  }

  uint64_t handle = 0;
  BOOL loaded = RVInvokeRemote(task, pid, remoteDlopen, (uint64_t)remotePath, RV_DEFAULT_WAIT_MS, &handle, error);
  mach_vm_deallocate(task, remotePath, pathBytes);
  mach_port_deallocate(mach_task_self(), task);

  if (!loaded) return nil;
  if (handle == 0) {
    if (error != NULL) {
      *error = [RVError errorWithCode:RVCodeRemoteError
                              message:[NSString stringWithFormat:
                                         @"dlopen(\"%@\") returned NULL in %@: the file is not a dylib "
                                         @"the target can load, its architecture does not match, or a "
                                         @"dependency is missing",
                                         path,
                                         RVTargetLabel(pid)]];
    }
    return nil;
  }

  NSMutableDictionary *result = [NSMutableDictionary dictionary];
  result[@"injected"] = @YES;
  result[@"image"] = path;
  if (callerAddress != 0) result[@"caller"] = [NSString stringWithFormat:@"0x%llx", callerAddress];
  return result;
}

+ (NSDictionary *)call:(pid_t)pid
               address:(uint64_t)address
              argument:(uint64_t)argument
                 label:(NSString *)label
                 error:(RVError **)error {
  mach_port_t task = [RVMemory taskFor:pid error:error];
  if (task == MACH_PORT_NULL) return nil;

  uint64_t returned = 0;
  BOOL called = RVInvokeRemote(task, pid, address, argument, RV_DEFAULT_WAIT_MS, &returned, error);
  mach_port_deallocate(mach_task_self(), task);
  if (!called) return nil;

  return @{
    @"label": label ?: @"",
    @"returned": [NSString stringWithFormat:@"0x%llx", (unsigned long long)returned],
  };
}

@end
