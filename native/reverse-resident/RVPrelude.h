/*
 * RVPrelude.h — shared declarations of the reverse resident.
 *
 * The resident is a SpringBoard tweak, not a daemon: it runs inside SpringBoard's
 * own task, which is what gives it the platform entitlements a jailed helper would
 * lack (task_for_pid on other apps, Mach-O access to /var/containers). Everything a
 * caller can reach travels over one Unix domain socket as NDJSON, exactly as
 * `@deepseek-ai/dsh-reverse-protocol` frames it.
 *
 * Keep this header free of Cordis/TypeScript vocabulary: the two ends share the
 * wire format, nothing else.
 */

#import <Foundation/Foundation.h>

#import <dlfcn.h>
#import <mach/mach.h>
#import <mach/vm_map.h>
#import <mach/vm_prot.h>
#import <mach/vm_region.h>
#import <mach-o/dyld.h>
#import <mach-o/fat.h>
#import <mach-o/loader.h>
#import <mach-o/nlist.h>
#import <os/log.h>
#import <pthread.h>
#import <string.h>
#import <sys/socket.h>
#import <sys/stat.h>
#import <sys/sysctl.h>
#import <sys/un.h>
#import <UIKit/UIKit.h>

/** Protocol revision this resident speaks; a client sending another refuses to pair. */
#define RV_PROTOCOL_VERSION 1

/**
 * `proc_pidpath`, declared here because the iPhoneOS SDK ships no libproc.h.
 * The symbol is in libSystem on every iOS version this resident supports.
 */
extern int proc_pidpath(int pid, void *buffer, uint32_t buffersize);

/**
 * Longest path `proc_pidpath` writes; `libproc.h` would have defined it.
 */
#ifndef PROC_PIDPATHINFO_MAXSIZE
#define PROC_PIDPATHINFO_MAXSIZE (4 * MAXPATHLEN)
#endif

/**
 * The `mach_vm_*` bindings used below, declared here rather than included: the
 * iPhoneOS SDK ships `mach/mach_vm.h` as an `#error` stub, while every one of these
 * symbols is exported by libSystem on every iOS version the resident supports.
 */
extern kern_return_t mach_vm_read_overwrite(vm_map_read_t target_task,
                                            mach_vm_address_t address,
                                            mach_vm_size_t size,
                                            mach_vm_address_t data,
                                            mach_vm_size_t *outsize);

extern kern_return_t mach_vm_region_recurse(vm_map_read_t target_task,
                                            mach_vm_address_t *address,
                                            mach_vm_size_t *size,
                                            natural_t *nesting_depth,
                                            vm_region_recurse_info_t info,
                                            mach_msg_type_number_t *infoCnt);

extern kern_return_t mach_vm_protect(vm_map_t target_task,
                                     mach_vm_address_t address,
                                     mach_vm_size_t size,
                                     boolean_t set_maximum,
                                     vm_prot_t new_protection);

extern kern_return_t mach_vm_write(vm_map_t target_task,
                                   mach_vm_address_t address,
                                   vm_offset_t data,
                                   mach_msg_type_number_t dataCnt);

/** Largest single request line accepted, matching the harness side's frame cap. */
#define RV_MAX_FRAME_BYTES (8u * 1024u * 1024u)

/** Bytes one `memory.read` may ask for. */
#define RV_MAX_READ_LENGTH (1024u * 1024u)

/** Answered requests the resident keeps for `system.logs`; older ones are dropped. */
#define RV_MAX_LOG_ENTRIES (200u)

/** Longest failure text one log entry carries before it is cut. */
#define RV_MAX_LOG_DETAIL (400u)

/** Socket the resident listens on, inside the jailbreak-writable data container. */
FOUNDATION_EXPORT NSString *const RVSocketPath;

/** Directory the socket lives in; created if absent. */
FOUNDATION_EXPORT NSString *const RVStateDirectory;

/** Stable failure classes on the wire; the strings are the protocol's, not ours. */
extern NSString *const RVCodeBadRequest;
extern NSString *const RVCodeInvalidArgs;
extern NSString *const RVCodeNotConnected;
extern NSString *const RVCodeTimeout;
extern NSString *const RVCodeCancelled;
extern NSString *const RVCodeDenied;
extern NSString *const RVCodeNotFound;
extern NSString *const RVCodeTargetGone;
extern NSString *const RVCodeUnsupported;
extern NSString *const RVCodeProtocolMismatch;
extern NSString *const RVCodeRemoteError;

/** A failure that becomes one response frame's `error` object. */
@interface RVError : NSObject

/** One of the RVCode* constants. */
@property (nonatomic, copy) NSString *code;

/** Model-facing sentence naming what failed and where. */
@property (nonatomic, copy) NSString *message;

/**
 * Build a failure.
 * @param code one of the RVCode* constants.
 * @param message what failed, phrased for a reader.
 */
+ (instancetype)errorWithCode:(NSString *)code message:(NSString *)message;

@end

/** Handles one operation's already-validated arguments. */
typedef id (^RVHandler)(NSDictionary *args, RVError **error);

/**
 * The in-process server: one listening socket, one thread per client, one
 * request table.
 *
 * A malformed line drops that connection instead of resynchronizing: a client that
 * cannot frame correctly receives nothing more, which keeps a partial write from
 * being interpreted as a different operation.
 */
@interface RVServer : NSObject

/** The process-wide server. */
+ (instancetype)shared;

/** Start listening; safe to call more than once. */
- (void)start;

/** Stop listening and close every client. */
- (void)stop;

@end

/** Process discovery and image enumeration. */
@interface RVProcess : NSObject

/** Live processes as protocol `process.list` records. */
+ (NSArray *)listWithFilter:(NSString *)filter error:(RVError **)error;

/** Images mapped into one process. */
+ (NSArray *)imagesOf:(pid_t)pid error:(RVError **)error;

/** Symbols of one image in one process. */
+ (NSArray *)symbolsOf:(pid_t)pid
                 image:(NSString *)image
                filter:(NSString *)filter
                 limit:(NSUInteger)limit
             truncated:(BOOL *)truncated
                 error:(RVError **)error;

@end

/** Static Mach-O analysis of one file on disk. */
@interface RVMachO : NSObject

/** The protocol's `macho.analyze` report for one path. */
+ (NSDictionary *)analyzePath:(NSString *)path stringsLimit:(NSUInteger)limit error:(RVError **)error;

@end

/** Memory access in another process. */
@interface RVMemory : NSObject

/** Read `length` bytes at `address`, hex and ASCII rendered. */
+ (NSDictionary *)read:(pid_t)pid address:(uint64_t)address length:(NSUInteger)length error:(RVError **)error;

/** Search one process for a value. */
+ (NSDictionary *)scan:(pid_t)pid
                  type:(NSString *)type
                 value:(NSString *)value
                 limit:(NSUInteger)limit
                  from:(NSNumber *)from
                    to:(NSNumber *)to
                 error:(RVError **)error;

/** Overwrite one value, reporting what was there before. */
+ (NSDictionary *)write:(pid_t)pid
                address:(uint64_t)address
                   type:(NSString *)type
                  value:(NSString *)value
                  error:(RVError **)error;

/**
 * Open `pid` for machine access.
 * @returns a send right the caller must release with mach_port_deallocate.
 */
+ (mach_port_t)taskFor:(pid_t)pid error:(RVError **)error;

@end
