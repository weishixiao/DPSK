// The in-process Node boot.
//
// Node is linked as `libnode.dylib`, embedded in DPSK.app/Frameworks and signed
// with the app (project.yml; `tooling/ios/prepare-engine.sh` builds it and
// rewrites its install name to `@rpath/libnode.dylib`). Nothing here dlopens by
// hand and nothing creates a child process: the harness runs inside DPSK.app, in
// the app's own sandbox.
//
// The split follows dsh-Go's iOS host (`runtime/ios/host/node_runner.cc`),
// which is the working reference for an embedded Node on this platform:
//
//   * The *process* initializes once -- V8, the platform, Node's per-process
//     state. `node::Start` does all of that and owns the result for the life of
//     the process, so it can be called exactly once and a failed call is final.
//   * Each *run* gets its own `Environment` built on that platform. Stopping a
//     run disposes only the Environment, so the engine can be started again
//     without relaunching the app -- which on iOS means without the user having
//     to quit and reopen it.
//
// The previous version called `node::Start` directly. It worked for one run and
// left the app with no way back: a failed or finished boot was permanent, and the
// UI could only advise a restart.

#import "NodeBridge.h"

#include <node.h>

#include <cstdio>
#include <memory>
#include <mutex>
#include <string>
#include <vector>

namespace {

std::mutex environment_mutex;
node::Environment *active_environment = nullptr;
bool running = false;
bool stop_requested = false;

// Set by the first start and reused by every later one. Node's platform cannot
// be replaced once V8 has been initialized on it.
std::shared_ptr<node::InitializationResult> initialization;
std::unique_ptr<node::MultiIsolatePlatform> platform;

int RejectStartup(const char *code) {
  // Never echo paths or arguments: this line can reach a log the user shares.
  std::fprintf(stderr, "%s: invalid embedded Node startup\n", code);
  return DPSK_NODE_REJECTED;
}

/// Run one Environment to completion. Called on the engine thread.
int RunEnvironment(const std::vector<std::string> &args, const std::vector<std::string> &exec_args) {
  std::vector<std::string> errors;
  const auto flags = static_cast<node::EnvironmentFlags::Flags>(
      node::EnvironmentFlags::kNoGlobalSearchPaths |
      node::EnvironmentFlags::kNoCreateInspector |
      node::EnvironmentFlags::kNoStartDebugSignalHandler);
  auto setup = node::CommonEnvironmentSetup::Create(platform.get(), &errors, args, exec_args, flags);
  if (!setup) {
    for (const auto &error : errors) std::fprintf(stderr, "%s\n", error.c_str());
    return RejectStartup("ERR_IOS_HOST_ENVIRONMENT");
  }
  auto *isolate = setup->isolate();
  auto *env = setup->env();
  int explicit_exit = 0;
  bool has_explicit_exit = false;
  int result = 1;
  {
    v8::Locker locker(isolate);
    v8::Isolate::Scope isolate_scope(isolate);
    v8::HandleScope handle_scope(isolate);
    v8::Context::Scope context_scope(setup->context());
    node::SetProcessExitHandler(env, [&](node::Environment *exiting, int code) {
      explicit_exit = code;
      has_explicit_exit = true;
      node::Stop(exiting);
    });
    {
      std::lock_guard<std::mutex> lock(environment_mutex);
      active_environment = env;
      // A stop that arrived between the thread starting and this point must not
      // be lost: the run it asked to stop is the one that just appeared.
      if (stop_requested) node::Stop(env);
    }
    // An empty callback selects Node's normal CLI entry and its --import chain.
    if (!node::LoadEnvironment(env, node::StartExecutionCallback{}).IsEmpty()) {
      result = node::SpinEventLoop(env).FromMaybe(1);
    }
    {
      std::lock_guard<std::mutex> lock(environment_mutex);
      active_environment = nullptr;
      // A stop is not a failure: report success for a run that ended because it
      // was asked to.
      if (stop_requested && !has_explicit_exit) result = 0;
    }
    node::Stop(env);
  }
  return has_explicit_exit ? explicit_exit : result;
}

}  // namespace

int DPSKNodeStart(NSArray<NSString *> *arguments) {
  @autoreleasepool {
    std::vector<std::string> storage;
    storage.reserve(arguments.count);
    for (NSString *argument in arguments) {
      storage.emplace_back(argument.UTF8String ?: "");
    }
    if (storage.empty()) return RejectStartup("ERR_IOS_HOST_ARGV");

    {
      std::lock_guard<std::mutex> lock(environment_mutex);
      if (running) return RejectStartup("ERR_IOS_HOST_ALREADY_STARTED");
      running = true;
      stop_requested = false;
    }

    int status = 0;
    if (!initialization) {
      initialization = node::InitializeOncePerProcess(storage, {
          node::ProcessInitializationFlags::kNoStdioInitialization,
          node::ProcessInitializationFlags::kNoDefaultSignalHandling,
          node::ProcessInitializationFlags::kNoInitializeV8,
          node::ProcessInitializationFlags::kNoInitializeNodeV8Platform,
          node::ProcessInitializationFlags::kDisableNodeOptionsEnv,
          node::ProcessInitializationFlags::kNoParseGlobalDebugVariables,
          node::ProcessInitializationFlags::kNoAdjustResourceLimits,
      });
      for (const auto &error : initialization->errors()) std::fprintf(stderr, "%s\n", error.c_str());
      if (initialization->early_return()) {
        status = initialization->exit_code();
      } else {
        platform = node::MultiIsolatePlatform::Create(4);
        v8::V8::InitializePlatform(platform.get());
        v8::V8::Initialize();
      }
    } else if (initialization->early_return()) {
      status = initialization->exit_code();
    }

    if (status == 0) {
      // Process options are already fixed; only the arguments Node reads as argv
      // belong to this run.
      status = RunEnvironment(storage, initialization->exec_args());
    }

    {
      std::lock_guard<std::mutex> lock(environment_mutex);
      running = false;
    }
    return status;
  }
}

int DPSKNodeStop(void) {
  std::lock_guard<std::mutex> lock(environment_mutex);
  if (!running) return 0;
  stop_requested = true;
  if (active_environment != nullptr) node::Stop(active_environment);
  return 1;
}
