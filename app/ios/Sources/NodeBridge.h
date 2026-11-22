// The one C entry the Swift side calls to boot Node inside the app process.
//
// Node is an embedded `Frameworks/libnode.dylib` (see project.yml), so this is an
// in-process runtime, not a separate framework or process: nothing is dyloaded by
// hand and nothing is spawned. `DPSKNodeStart` blocks until the Node event loop
// drains, so callers put it on a thread of their own (EngineRuntime does).

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Boot Node with `arguments` as its argv and run until the loop exits.
///
/// `arguments[0]` is the program name Node reports as `process.argv[0]`; the
/// rest are the real arguments. Returns Node's exit status; it never returns
/// while the engine is serving.
///
/// V8 and Node's per-process state live as long as the app, so this is callable
/// more than once: each call builds a fresh `Environment` on the already
/// initialized platform. That is what lets a stopped engine start again without
/// relaunching the app -- `node::Start`, which owns the platform, cannot.
///
/// `extern "C"`: the definition lives in NodeBridge.mm, and in an Objective-C++
/// translation unit a plain function gets C++ linkage. Swift imports this header
/// as C and then asks the linker for `_DPSKNodeStart`, so without this the archive
/// fails with "Undefined symbols for architecture arm64: _DPSKNodeStart".
#ifdef __cplusplus
extern "C" {
#endif

/// Exit status returned when a start is rejected before Node loaded anything.
/// Distinct from a script's own exit code so the app can say "the engine refused
/// to start" instead of guessing at a crash.
#define DPSK_NODE_REJECTED 64

int DPSKNodeStart(NSArray<NSString *> *arguments);

/// Ask the running engine to stop. Returns 1 if a run was active, 0 if not.
///
/// This is `node::Stop` on the live Environment, not a signal: the app and the
/// engine share a process, so an exit code cannot be faked without taking the UI
/// with it. A stopped engine may be started again with `DPSKNodeStart`.
int DPSKNodeStop(void);

#ifdef __cplusplus
}
#endif

NS_ASSUME_NONNULL_END
