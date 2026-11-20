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
int DPSKNodeStart(NSArray<NSString *> *arguments);

NS_ASSUME_NONNULL_END
