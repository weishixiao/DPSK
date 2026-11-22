/**
 * The iOS provider for the subprocess seam.
 *
 * An app that runs the harness inside its own process cannot fork or exec:
 * iOS gives a sandboxed app no child process at all, so a bundled helper, a
 * system binary, and a shell are equally unavailable. The platform's own
 * failure mode is a bare `EPERM`/`ENOENT` from `spawn`, which consumers report
 * as "the program is missing" — true enough on macOS, misleading on a phone.
 *
 * This provider replaces that accident with a decision: every spawn request is
 * accepted and refused with a message that names the platform limit and the
 * tools that still work, and a terminal request reports the missing PTY. Tools
 * that need no process keep running, and the ones that do fail the same way
 * every time, with a reason a model can act on.
 *
 * Mount it in place of the host provider, keeping the row id:
 *
 * ```yaml
 * - id: subprocess
 *   name: '@deepseek-ai/dsh-subprocess-local/ios'
 * ```
 *
 * @module @deepseek-ai/dsh-subprocess-local/ios
 */

import { SubprocessError, SubprocessRuntime } from '@deepseek-ai/dsh-subprocess'
import type {
  SubprocessCollectedOutputs,
  SubprocessHandle,
  SubprocessOutcome,
  SubprocessSpawnSpec,
  SubprocessTerminalEnvironment,
  SubprocessTerminalHandle,
  SubprocessTerminalSpawnSpec,
} from '@deepseek-ai/dsh-subprocess'

/**
 * The one sentence every refusal carries: what iOS does not provide, and what
 * the caller can do instead. Exported so the app's own documentation and tests
 * quote the same words the model reads.
 */
export const IOS_SUBPROCESS_UNAVAILABLE = 'iOS runs this harness inside an app sandbox, which cannot fork or exec a child process: no shell, terminal, or bundled executable can start here. Use the file tools (read, write, edit) instead, and treat any step that needs a command as something the user has to run on a computer.'

/** No streams, no readers, and a refusal on `done`: what a spawn that cannot happen returns. */
class RefusedSubprocessHandle implements SubprocessHandle {
  readonly stdin = undefined

  readonly stdout = undefined

  readonly stderr = undefined

  readonly control = undefined

  readonly collected: SubprocessCollectedOutputs = {}

  readonly done: Promise<SubprocessOutcome>

  constructor(error: SubprocessError) {
    this.done = Promise.reject(error)
    // The handle exists before any caller can await it. Mark the rejection as
    // observed so an abandoned handle never reaches the host's unhandled-rejection
    // path; an awaiting caller still sees the same rejection.
    void this.done.catch(() => undefined)
  }

  terminate(): void {
    // Nothing was started, so there is no range to terminate.
  }

  waitForExit(signal?: AbortSignal): Promise<boolean> {
    // No managed range ever exists, so quiescence is immediate; a bound that
    // already expired still reports that it gave up first.
    return Promise.resolve(signal?.aborted !== true)
  }
}

/**
 * iOS subprocess service: refuses every spawn and terminal allocation with a
 * structured failure instead of relying on the platform's errno. It takes no
 * config, because the platform decision is not deployment-varying.
 */
export class IosSubprocessRuntime extends SubprocessRuntime {
  /** @inheritdoc */
  resolveExecutable(
    command: string,
    _env?: Readonly<Record<string, string>>,
    signal?: AbortSignal,
  ): Promise<string> {
    signal?.throwIfAborted()
    return Promise.reject(this.refusal(command))
  }

  /** @inheritdoc */
  terminalEnvironment(signal?: AbortSignal): Promise<SubprocessTerminalEnvironment> {
    signal?.throwIfAborted()
    // The platform family is POSIX; there is no shell to name, and the empty
    // answer is what a consumer reads as "pick your own fallback".
    return Promise.resolve({ platform: 'posix' })
  }

  /** @inheritdoc */
  spawn(spec: SubprocessSpawnSpec): SubprocessHandle {
    spec.signal?.throwIfAborted()
    return new RefusedSubprocessHandle(this.refusal(spec.argv[0]))
  }

  /** @inheritdoc */
  spawnTerminal(spec: SubprocessTerminalSpawnSpec): Promise<SubprocessTerminalHandle> {
    spec.signal?.throwIfAborted()
    return Promise.reject(new SubprocessError(
      `subprocess-ios cannot allocate a terminal for ${programName(spec.argv[0])}: ${IOS_SUBPROCESS_UNAVAILABLE}`,
      'SUBPROCESS_PTY_UNAVAILABLE',
    ))
  }

  private refusal(program: string | undefined): SubprocessError {
    return new SubprocessError(
      `subprocess-ios cannot start ${programName(program)}: ${IOS_SUBPROCESS_UNAVAILABLE}`,
      'SUBPROCESS_SPAWN_FAILED',
    )
  }
}

/** Name the program a caller asked for, or say that it named none. */
function programName(program: string | undefined): string {
  return program === undefined || program === '' ? 'the requested program' : JSON.stringify(program)
}

export default IosSubprocessRuntime
