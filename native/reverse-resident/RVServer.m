/*
 * RVServer.m — the socket, the framing and the dispatch table.
 *
 * One listener, one thread per client, one JSON object per line. Each request is
 * answered by exactly one frame carrying the same `id`; a request whose operation
 * this resident does not serve is answered with `unsupported` rather than ignored,
 * so a caller never waits for a frame that will not come.
 */

#import "RVPrelude.h"

NSString *const RVSocketPath = @"/var/mobile/Library/DSHReverse/rvd.sock";
NSString *const RVStateDirectory = @"/var/mobile/Library/DSHReverse";

NSString *const RVCodeBadRequest = @"bad-request";
NSString *const RVCodeInvalidArgs = @"invalid-args";
NSString *const RVCodeNotConnected = @"not-connected";
NSString *const RVCodeTimeout = @"timeout";
NSString *const RVCodeCancelled = @"cancelled";
NSString *const RVCodeDenied = @"denied";
NSString *const RVCodeNotFound = @"not-found";
NSString *const RVCodeTargetGone = @"target-gone";
NSString *const RVCodeUnsupported = @"unsupported";
NSString *const RVCodeProtocolMismatch = @"protocol-mismatch";
NSString *const RVCodeRemoteError = @"remote-error";

@implementation RVError

+ (instancetype)errorWithCode:(NSString *)code message:(NSString *)message {
  RVError *error = [[RVError alloc] init];
  error.code = code;
  error.message = message.length > 0 ? message : @"the resident failed without a message";
  return error;
}

@end

/** Answer one operation. Returns the result object, or nil with `error` set. */
typedef id (^RVOperation)(NSDictionary *args, RVError **error);

#pragma mark - Argument helpers

static BOOL RVInteger(NSDictionary *args, NSString *key, long long *out, RVError **error) {
  id raw = args[key];
  if ([raw isKindOfClass:[NSNumber class]]) {
    *out = [(NSNumber *)raw longLongValue];
    return YES;
  }
  if (error != NULL) {
    *error = [RVError errorWithCode:RVCodeInvalidArgs
                            message:[NSString stringWithFormat:@"%@ must be an integer", key]];
  }
  return NO;
}

static BOOL RVString(NSDictionary *args, NSString *key, NSString **out, RVError **error) {
  id raw = args[key];
  if ([raw isKindOfClass:[NSString class]]) {
    *out = (NSString *)raw;
    return YES;
  }
  if (error != NULL) {
    *error = [RVError errorWithCode:RVCodeInvalidArgs
                            message:[NSString stringWithFormat:@"%@ must be a string", key]];
  }
  return NO;
}

/** Parse a `0x`-prefixed lowercase address; the harness always sends that form. */
static BOOL RVAddress(NSDictionary *args, NSString *key, uint64_t *out, RVError **error) {
  NSString *text = nil;
  if (!RVString(args, key, &text, error)) return NO;
  if (![text hasPrefix:@"0x"] || text.length < 3) {
    if (error != NULL) {
      *error = [RVError errorWithCode:RVCodeInvalidArgs
                              message:[NSString stringWithFormat:@"%@ must be 0x-prefixed hex", key]];
    }
    return NO;
  }
  NSScanner *scanner = [NSScanner scannerWithString:[text substringFromIndex:2]];
  unsigned long long value = 0;
  if (![scanner scanHexLongLong:&value] || !scanner.isAtEnd || value == 0) {
    if (error != NULL) {
      *error = [RVError errorWithCode:RVCodeInvalidArgs
                              message:[NSString stringWithFormat:@"%@ is not a usable address", key]];
    }
    return NO;
  }
  *out = (uint64_t)value;
  return YES;
}

#pragma mark - Operation table

/** Operations this build actually serves; `system.hello` reports it verbatim. */
static NSArray<NSString *> *RVServedOps(void) {
  static NSArray<NSString *> *ops;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    ops = @[
      @"system.hello",
      @"system.logs",
      @"process.list",
      @"process.images",
      @"process.symbols",
      @"macho.analyze",
      @"memory.read",
      @"memory.scan",
      @"memory.write",
    ];
  });
  return ops;
}

/** True when a Theos toolchain is visible on this device. */
static BOOL RVTheosAvailable(void) {
  NSFileManager *files = [NSFileManager defaultManager];
  NSArray<NSString *> *candidates = @[
    @"/var/jb/usr/bin/make",
    @"/usr/bin/make",
    @"/opt/theos/bin/make",
    @"/var/mobile/theos/bin/make",
  ];
  for (NSString *path in candidates) {
    if ([files isExecutableFileAtPath:path]) return YES;
  }
  return NO;
}

#pragma mark - Log ring

/**
 * Answered requests, newest last, in a bounded ring.
 *
 * The panel exists so a session can be explained after the fact — which operation
 * ran, whether the resident refused it, and what it said — so an entry is written
 * for every answer the dispatcher produces, including the refusals. Requests that
 * arrive malformed enough to have no operation name are not logged: there is
 * nothing to name.
 */
@interface RVLogRing : NSObject
+ (instancetype)shared;
/** Append one answer; the oldest entry is dropped when the ring is full. */
- (void)recordOperation:(NSString *)operation
                     ok:(BOOL)ok
              elapsedMs:(NSInteger)elapsedMs
                 detail:(NSString *)detail;
/** The newest `limit` entries, oldest first, with how many were dropped for good. */
- (NSDictionary *)entriesWithLimit:(NSUInteger)limit;
@end

/** ISO-8601 in UTC with milliseconds: a log the panel shows is a moment, not a locale. */
static NSString *RVTimestamp(void) {
  static NSDateFormatter *formatter;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    NSDateFormatter *made = [[NSDateFormatter alloc] init];
    made.dateFormat = @"yyyy-MM-dd'T'HH:mm:ss.SSS'Z'";
    made.timeZone = [NSTimeZone timeZoneWithAbbreviation:@"UTC"];
    made.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    formatter = made;
  });
  return [formatter stringFromDate:[NSDate date]];
}

@implementation RVLogRing {
  NSMutableArray<NSDictionary *> *_entries;
  NSUInteger _dropped;
}

+ (instancetype)shared {
  static RVLogRing *ring;
  static dispatch_once_t once;
  dispatch_once(&once, ^{ ring = [[RVLogRing alloc] init]; });
  return ring;
}

- (instancetype)init {
  if ((self = [super init])) {
    _entries = [NSMutableArray arrayWithCapacity:RV_MAX_LOG_ENTRIES];
    _dropped = 0;
  }
  return self;
}

- (void)recordOperation:(NSString *)operation
                     ok:(BOOL)ok
              elapsedMs:(NSInteger)elapsedMs
                 detail:(NSString *)detail {
  // Two clients answer concurrently, so the ring and the date formatter behind
  // RVTimestamp() are both read and written under this one lock.
  @synchronized (self) {
    NSMutableDictionary *entry = [NSMutableDictionary dictionary];
    entry[@"at"] = RVTimestamp();
    entry[@"op"] = operation.length > 0 ? operation : @"-";
    entry[@"ok"] = @(ok);
    entry[@"elapsedMs"] = @(elapsedMs);
    NSString *text = detail;
    if (text.length > RV_MAX_LOG_DETAIL) {
      // Cut on a character boundary so a multi-byte character is never halved.
      NSRange range = [text rangeOfComposedCharacterSequencesForRange:NSMakeRange(0, RV_MAX_LOG_DETAIL)];
      text = [text substringWithRange:range];
    }
    if (text.length > 0) entry[@"detail"] = text;
    if (_entries.count >= RV_MAX_LOG_ENTRIES) {
      [_entries removeObjectAtIndex:0];
      _dropped += 1;
    }
    [_entries addObject:entry];
  }
}

- (NSDictionary *)entriesWithLimit:(NSUInteger)limit {
  @synchronized (self) {
    NSUInteger wanted = MIN(limit, _entries.count);
    NSArray<NSDictionary *> *slice = [_entries subarrayWithRange:NSMakeRange(_entries.count - wanted, wanted)];
    return @{ @"entries": slice, @"dropped": @(_dropped) };
  }
}

@end

#pragma mark - Server

@interface RVServer ()
@property (nonatomic, assign) int listener;
@property (nonatomic, assign) BOOL running;
/** Operation name to its one handler; `system.hello` reports the keys. */
@property (nonatomic, strong) NSDictionary<NSString *, RVOperation> *operations;
@end

/** Read lines from one client and answer each. */
static void *RVClientLoop(void *raw);
/** Turn one request line into one response line. */
static NSData *RVAnswerLine(RVServer *server, NSString *line);
/** Assemble one response frame. */
static NSData *RVFrame(NSString *identifier, id result, RVError *error, NSDate *started);

@implementation RVServer

+ (instancetype)shared {
  static RVServer *server;
  static dispatch_once_t once;
  dispatch_once(&once, ^{ server = [[RVServer alloc] init]; });
  return server;
}

- (instancetype)init {
  if ((self = [super init])) {
    _listener = -1;
    _running = NO;
    _operations = [self buildTable];
  }
  return self;
}

/** The dispatch table: operation name to exactly one handler. */
- (NSDictionary<NSString *, RVOperation> *)buildTable {
  NSMutableDictionary<NSString *, RVOperation> *table = [NSMutableDictionary dictionary];

  table[@"system.hello"] = ^id(NSDictionary *args, RVError **error) {
    return @{
      @"version": @(RV_PROTOCOL_VERSION),
      @"resident": @"dsh-reverse-resident/0.1.0",
      @"ios": [[UIDevice currentDevice] systemVersion] ?: @"unknown",
      @"arch": @"arm64e",
      @"theos": @(RVTheosAvailable()),
      @"ops": RVServedOps(),
    };
  };

  table[@"system.logs"] = ^id(NSDictionary *args, RVError **error) {
    long long limit = 50;
    if (args[@"limit"] != nil && !RVInteger(args, @"limit", &limit, error)) return nil;
    if (limit < 1 || limit > (long long)RV_MAX_LOG_ENTRIES) {
      if (error != NULL) {
        *error = [RVError errorWithCode:RVCodeInvalidArgs
                                message:[NSString stringWithFormat:@"limit must be 1..%u", RV_MAX_LOG_ENTRIES]];
      }
      return nil;
    }
    return [[RVLogRing shared] entriesWithLimit:(NSUInteger)limit];
  };

  table[@"process.list"] = ^id(NSDictionary *args, RVError **error) {
    NSString *filter = [args[@"filter"] isKindOfClass:[NSString class]] ? args[@"filter"] : nil;
    return @{ @"processes": [RVProcess listWithFilter:filter error:error] };
  };

  table[@"process.images"] = ^id(NSDictionary *args, RVError **error) {
    long long pid = 0;
    if (!RVInteger(args, @"pid", &pid, error)) return nil;
    return @{ @"pid": @(pid), @"images": [RVProcess imagesOf:(pid_t)pid error:error] };
  };

  table[@"process.symbols"] = ^id(NSDictionary *args, RVError **error) {
    long long pid = 0;
    if (!RVInteger(args, @"pid", &pid, error)) return nil;
    NSString *image = nil;
    if (args[@"image"] != nil && !RVString(args, @"image", &image, error)) return nil;
    NSString *filter = nil;
    if (args[@"filter"] != nil && !RVString(args, @"filter", &filter, error)) return nil;
    long long limit = 200;
    if (args[@"limit"] != nil && !RVInteger(args, @"limit", &limit, error)) return nil;
    BOOL truncated = NO;
    NSArray *symbols = [RVProcess symbolsOf:(pid_t)pid
                                       image:image
                                      filter:filter
                                       limit:(NSUInteger)MAX(1, limit)
                                   truncated:&truncated
                                       error:error];
    if (symbols == nil) return nil;
    return @{ @"symbols": symbols, @"truncated": @(truncated) };
  };

  table[@"macho.analyze"] = ^id(NSDictionary *args, RVError **error) {
    NSString *path = nil;
    if (!RVString(args, @"path", &path, error)) return nil;
    long long limit = 200;
    if (args[@"stringsLimit"] != nil && !RVInteger(args, @"stringsLimit", &limit, error)) return nil;
    return [RVMachO analyzePath:path stringsLimit:(NSUInteger)MAX(0, limit) error:error];
  };

  table[@"memory.read"] = ^id(NSDictionary *args, RVError **error) {
    long long pid = 0, length = 0;
    uint64_t address = 0;
    if (!RVInteger(args, @"pid", &pid, error)) return nil;
    if (!RVAddress(args, @"address", &address, error)) return nil;
    if (!RVInteger(args, @"length", &length, error)) return nil;
    if (length < 1 || length > RV_MAX_READ_LENGTH) {
      if (error != NULL) {
        *error = [RVError errorWithCode:RVCodeInvalidArgs
                                message:[NSString stringWithFormat:@"length must be 1..%u", RV_MAX_READ_LENGTH]];
      }
      return nil;
    }
    return [RVMemory read:(pid_t)pid address:address length:(NSUInteger)length error:error];
  };

  table[@"memory.scan"] = ^id(NSDictionary *args, RVError **error) {
    long long pid = 0, limit = 500;
    NSString *type = nil, *value = nil;
    if (!RVInteger(args, @"pid", &pid, error)) return nil;
    if (!RVString(args, @"type", &type, error)) return nil;
    if (!RVString(args, @"value", &value, error)) return nil;
    if (args[@"limit"] != nil && !RVInteger(args, @"limit", &limit, error)) return nil;
    NSNumber *from = nil, *to = nil;
    NSDictionary *range = [args[@"range"] isKindOfClass:[NSDictionary class]] ? args[@"range"] : nil;
    if (range != nil) {
      uint64_t fromValue = 0, toValue = 0;
      if (!RVAddress(range, @"from", &fromValue, error)) return nil;
      if (!RVAddress(range, @"to", &toValue, error)) return nil;
      if (toValue <= fromValue) {
        if (error != NULL) {
          *error = [RVError errorWithCode:RVCodeInvalidArgs message:@"range.to must be above range.from"];
        }
        return nil;
      }
      from = @(fromValue);
      to = @(toValue);
    }
    return [RVMemory scan:(pid_t)pid
                     type:type
                    value:value
                    limit:(NSUInteger)MAX(1, limit)
                     from:from
                       to:to
                    error:error];
  };

  table[@"memory.write"] = ^id(NSDictionary *args, RVError **error) {
    long long pid = 0;
    uint64_t address = 0;
    NSString *type = nil, *value = nil;
    if (!RVInteger(args, @"pid", &pid, error)) return nil;
    if (!RVAddress(args, @"address", &address, error)) return nil;
    if (!RVString(args, @"type", &type, error)) return nil;
    if (!RVString(args, @"value", &value, error)) return nil;
    return [RVMemory write:(pid_t)pid address:address type:type value:value error:error];
  };

  // The two mutating operations that need code the resident does not carry yet.
  // They answer `unsupported` with the reason, never a silent success.
  table[@"hook.install"] = ^id(NSDictionary *args, RVError **error) {
    if (error != NULL) {
      *error = [RVError errorWithCode:RVCodeUnsupported
                              message:@"hook.install is not served by this resident build: it needs an "
                                      @"inline-hook engine inside the target process. Use the generated "
                                      @"Theos tweak from reverse_hook_install's saved source and load it "
                                      @"as a tweak instead."];
    }
    return nil;
  };

  table[@"inject.dylib"] = ^id(NSDictionary *args, RVError **error) {
    if (error != NULL) {
      *error = [RVError errorWithCode:RVCodeUnsupported
                              message:@"inject.dylib is not served by this resident build: it needs a "
                                      @"remote thread inside the target. Load the dylib with your "
                                      @"jailbreak's dylib injector or a SpringBoard tweak's filter."];
    }
    return nil;
  };

  return table;
}

#pragma mark - Socket lifecycle

- (void)start {
  @synchronized (self) {
    if (_running) return;
    NSFileManager *files = [NSFileManager defaultManager];
    [files createDirectoryAtPath:RVStateDirectory withIntermediateDirectories:YES attributes:nil error:nil];
    // A socket left by a previous SpringBoard instance refuses bind.
    [files removeItemAtPath:RVSocketPath error:nil];

    int listener = socket(AF_UNIX, SOCK_STREAM, 0);
    if (listener < 0) {
      os_log_error(OS_LOG_DEFAULT, "rv: socket() failed: %{errno}d", errno);
      return;
    }

    struct sockaddr_un address;
    memset(&address, 0, sizeof(address));
    address.sun_family = AF_UNIX;
    strncpy(address.sun_path, RVSocketPath.UTF8String, sizeof(address.sun_path) - 1);

    if (bind(listener, (struct sockaddr *)&address, sizeof(address)) != 0) {
      os_log_error(OS_LOG_DEFAULT, "rv: bind(%{public}s) failed: %{errno}d", RVSocketPath.UTF8String, errno);
      close(listener);
      return;
    }
    // 0666 so the harness, running as mobile in the same container's sandbox,
    // may dial it; the socket carries no other credential.
    chmod(RVSocketPath.UTF8String, 0666);
    if (listen(listener, 8) != 0) {
      os_log_error(OS_LOG_DEFAULT, "rv: listen failed: %{errno}d", errno);
      close(listener);
      return;
    }

    _listener = listener;
    _running = YES;
    os_log(OS_LOG_DEFAULT, "rv: resident listening on %{public}s", RVSocketPath.UTF8String);

    pthread_t thread;
    pthread_create(&thread, NULL, RVAceptLoop, (__bridge void *)self);
    pthread_detach(thread);
  }
}

- (void)stop {
  @synchronized (self) {
    if (!_running) return;
    _running = NO;
    if (_listener >= 0) {
      shutdown(_listener, SHUT_RDWR);
      close(_listener);
      _listener = -1;
    }
  }
}

/** Accept loop: one detached thread per client. */
static void *RVAceptLoop(void *context) {
  RVServer *server = (__bridge RVServer *)context;
  while (server.running) {
    int client = accept(server.listener, NULL, NULL);
    if (client < 0) {
      if (errno == EINTR) continue;
      usleep(50 * 1000);
      continue;
    }
    pthread_t thread;
    pthread_create(&thread, NULL, RVClientLoop, (void *)(intptr_t)client);
    pthread_detach(thread);
  }
  return NULL;
}

/** Read lines from one client and answer each. */
static void *RVClientLoop(void *raw) {
  int client = (int)(intptr_t)raw;
  NSMutableData *pending = [NSMutableData data];
  uint8_t chunk[64 * 1024];
  RVServer *server = [RVServer shared];

  while (YES) {
    ssize_t got = read(client, chunk, sizeof(chunk));
    if (got <= 0) break;
    [pending appendBytes:chunk length:(NSUInteger)got];
    if (pending.length > RV_MAX_FRAME_BYTES) {
      os_log_error(OS_LOG_DEFAULT, "rv: client sent a frame larger than the cap; dropping it");
      break;
    }

    // Consume every complete line; the tail stays for the next read.
    NSUInteger start = 0;
    for (NSUInteger index = 0; index < pending.length; index++) {
      if (((const uint8_t *)pending.bytes)[index] != '\n') continue;
      NSData *line = [pending subdataWithRange:NSMakeRange(start, index - start)];
      start = index + 1;
      NSString *text = [[NSString alloc] initWithData:line encoding:NSUTF8StringEncoding];
      if (text.length == 0) continue;
      // One pool per request: a scan builds a large result array, and without this
      // the high-water mark of a long-lived client would be the sum of every answer.
      @autoreleasepool {
        NSData *response = RVAnswerLine(server, text);
        if (response == nil) continue;
        NSMutableData *framed = [response mutableCopy];
        [framed appendBytes:"\n" length:1];
        if (write(client, framed.bytes, framed.length) < 0) {
          os_log_error(OS_LOG_DEFAULT, "rv: write failed: %{errno}d", errno);
          close(client);
          return NULL;
        }
      }
    }
    if (start > 0) [pending replaceBytesInRange:NSMakeRange(0, start) withBytes:NULL length:0];
  }
  close(client);
  return NULL;
}

/** Turn one request line into one response line. */
static NSData *RVAnswerLine(RVServer *server, NSString *line) {
  NSDate *started = [NSDate date];
  id parsed = [NSJSONSerialization JSONObjectWithData:[line dataUsingEncoding:NSUTF8StringEncoding]
                                             options:0
                                               error:nil];
  if (![parsed isKindOfClass:[NSDictionary class]]) {
    return RVFrame(nil, nil, [RVError errorWithCode:RVCodeBadRequest message:@"request is not a JSON object"], started);
  }
  NSDictionary *request = parsed;
  NSString *identifier = [request[@"id"] isKindOfClass:[NSString class]] ? request[@"id"] : nil;
  NSString *operation = [request[@"op"] isKindOfClass:[NSString class]] ? request[@"op"] : nil;
  NSDictionary *args = [request[@"args"] isKindOfClass:[NSDictionary class]] ? request[@"args"] : @{};

  if (identifier == nil || operation == nil) {
    return RVFrame(identifier, nil, [RVError errorWithCode:RVCodeBadRequest message:@"request needs an id and an op"], started);
  }

  // Every answer from here on is logged, a refusal included: the panel's job is to
  // say what the resident was asked and what it said back.
  NSData *(^finish)(id, RVError *) = ^NSData *(id result, RVError *failure) {
    NSInteger elapsed = (NSInteger)(-[started timeIntervalSinceNow] * 1000.0);
    NSString *detail = failure == nil
      ? nil
      : [NSString stringWithFormat:@"%@: %@", failure.code, failure.message];
    [[RVLogRing shared] recordOperation:operation ok:(failure == nil) elapsedMs:elapsed detail:detail];
    return RVFrame(identifier, result, failure, started);
  };

  RVOperation handler = server.operations[operation];
  if (handler == nil) {
    RVError *unknown = [RVError errorWithCode:RVCodeUnsupported
                                      message:[NSString stringWithFormat:@"the resident does not serve %@", operation]];
    return finish(nil, unknown);
  }

  RVError *error = nil;
  id result = nil;
  // SpringBoard is the host process: an exception that escaped here would take the
  // home screen down with it. The handler is third-party code by construction, so
  // the boundary is the dispatcher's, and the caller still gets a frame.
  @try {
    result = handler(args, &error);
  } @catch (NSException *caught) {
    os_log_error(OS_LOG_DEFAULT,
                 "rv: %{public}s raised %{public}s: %{public}s",
                 operation.UTF8String,
                 caught.name.UTF8String ?: "exception",
                 caught.reason.UTF8String ?: "");
    return finish(nil, [RVError errorWithCode:RVCodeRemoteError
                                       message:[NSString stringWithFormat:@"the resident raised %@ while serving %@: %@",
                                                caught.name ?: @"an exception",
                                                operation,
                                                caught.reason ?: @"no reason given"]]);
  }
  if (error != nil || result == nil) {
    RVError *failure = error ?: [RVError errorWithCode:RVCodeRemoteError message:@"operation produced no result"];
    return finish(nil, failure);
  }
  return finish(result, nil);
}

/** Assemble one response frame. */
static NSData *RVFrame(NSString *identifier, id result, RVError *error, NSDate *started) {
  NSMutableDictionary *frame = [NSMutableDictionary dictionary];
  frame[@"id"] = identifier ?: @"";
  frame[@"elapsedMs"] = @((NSInteger)(-[started timeIntervalSinceNow] * 1000.0));
  if (error != nil) {
    frame[@"ok"] = @NO;
    frame[@"error"] = @{ @"code": error.code, @"message": error.message };
  } else {
    frame[@"ok"] = @YES;
    frame[@"result"] = result;
  }
  NSData *data = [NSJSONSerialization dataWithJSONObject:frame options:0 error:nil];
  return data;
}

@end