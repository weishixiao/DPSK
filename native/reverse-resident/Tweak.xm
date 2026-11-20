/*
 * Tweak.xm — the SpringBoard entry point of the reverse resident.
 *
 * SpringBoard, not a standalone daemon: `task_for_pid` on a third-party app needs
 * the platform identity SpringBoard already holds, and a dylib inside it inherits
 * that. The tweak starts one listener and otherwise stays out of the way — it hooks
 * nothing of SpringBoard's own behaviour.
 *
 * Failure policy: this code runs inside the home screen's process. A bug here must
 * cost the resident, never the desktop, so startup is guarded, per-request work is
 * guarded again in RVServer's dispatcher, and an uncaught exception is logged
 * before the previous handler runs.
 */

#import <Foundation/Foundation.h>
#import <os/log.h>

#import "RVPrelude.h"

/** The handler that was installed before this tweak loaded, called after logging. */
static NSUncaughtExceptionHandler *RVPreviousHandler = NULL;

/** Log an uncaught exception and hand it to whoever handled it before. */
static void RVHandleUncaught(NSException *exception) {
  os_log_error(OS_LOG_DEFAULT,
               "rv: uncaught %{public}s in SpringBoard: %{public}s",
               exception.name.UTF8String ?: "exception",
               exception.reason.UTF8String ?: "");
  if (RVPreviousHandler != NULL) RVPreviousHandler(exception);
}

%ctor {
  @autoreleasepool {
    os_log(OS_LOG_DEFAULT, "rv: resident loading in SpringBoard");
    // Chain rather than replace: another tweak's handler, and the system's own
    // crash reporting, keep working exactly as they did.
    RVPreviousHandler = NSGetUncaughtExceptionHandler();
    NSSetUncaughtExceptionHandler(&RVHandleUncaught);

    @try {
      [[RVServer shared] start];
    } @catch (NSException *caught) {
      // A resident that cannot listen is a feature that is off, not a crash: the
      // bridge answers `offline` and the tools say so.
      os_log_error(OS_LOG_DEFAULT,
                   "rv: resident failed to start (%{public}s: %{public}s); reverse tools will report offline",
                   caught.name.UTF8String ?: "exception",
                   caught.reason.UTF8String ?: "");
    }
  }
}
