/*
 * Tweak.xm — the SpringBoard entry point of the reverse resident.
 *
 * SpringBoard, not a standalone daemon: `task_for_pid` on a third-party app needs
 * the platform identity SpringBoard already holds, and a dylib inside it inherits
 * that. The tweak starts one listener and otherwise stays out of the way — it hooks
 * nothing of SpringBoard's own behaviour.
 */

#import <Foundation/Foundation.h>
#import <os/log.h>

#import "RVPrelude.h"

%ctor {
  @autoreleasepool {
    os_log(OS_LOG_DEFAULT, "rv: resident loading in SpringBoard");
    [[RVServer shared] start];
  }
}