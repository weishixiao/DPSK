// The in-process Node boot.
//
// Node is linked as `libnode.dylib`, embedded in DPSK.app/Frameworks and signed
// with the app (project.yml; `tooling/ios/prepare-engine.sh` builds it and
// rewrites its install name to `@rpath/libnode.dylib`). `node::Start` is then an
// ordinary imported function: nothing here dlopens by hand, and nothing creates
// a child process — the harness runs inside DPSK.app, in the app's own sandbox.

#import "NodeBridge.h"

#include <node.h>

#include <string>
#include <vector>

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"

int DPSKNodeStart(NSArray<NSString *> *arguments) {
  @autoreleasepool {
    std::vector<std::string> storage;
    storage.reserve(arguments.count);
    for (NSString *argument in arguments) {
      storage.emplace_back(argument.UTF8String ?: "");
    }

    std::vector<char *> argv;
    argv.reserve(storage.size() + 1);
    for (std::string &entry : storage) {
      argv.push_back(entry.data());
    }
    // POSIX says argv is NULL-terminated, and Node's platform setup walks it
    // (`uv_setup_args`) before it ever looks at argc.
    const int argc = static_cast<int>(argv.size());
    argv.push_back(nullptr);

    // Blocks for the whole life of the event loop. Node sets up its signals,
    // platform thread pool and main isolate here, so this must be the only call.
    return node::Start(argc, argv.data());
  }
}

#pragma clang diagnostic pop
