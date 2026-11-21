/**
 * Service Definition for the `ctx.reverse` capability seam: one local connection
 * to the SpringBoard resident, shaped as a request table rather than a raw socket.
 *
 * Two calls, not one, because the split is a safety property and not a
 * convenience: {@link ReverseBridge.call} refuses every operation that changes
 * the target, and only {@link ReverseBridge.mutate} — which cannot run without a
 * user decision — reaches them. A consumer that would rather not think about it
 * cannot accidentally write memory.
 * @module @deepseek-ai/dsh-reverse-bridge/seam
 */

import { Service } from '@deepseek-ai/cordis'
import type { Context } from '@deepseek-ai/cordis'
import type { Agent } from '@deepseek-ai/dsh-agent'
import type { ToolCallId } from '@deepseek-ai/dsh-llm'
import type {
  DangerousOp,
  ReverseArg,
  ReverseErrorCode,
  ReverseOp,
  ReverseResult,
} from '@deepseek-ai/dsh-reverse-protocol'

declare module '@deepseek-ai/cordis' {
  interface Context {
    reverse: ReverseBridge
  }
}

/** Connection state of the bridge, as the status tool reports it. */
export type ReverseState = 'disabled' | 'offline' | 'connecting' | 'ready'

/** A failure the bridge classifies itself, before any resident is involved. */
export class ReverseBridgeError extends Error {
  /**
   * @param code - the stable failure class.
   * @param message - what went wrong, phrased for the model.
   * @param options - standard error options, used to keep a cause.
   */
  constructor(readonly code: ReverseErrorCode, message: string, options?: ErrorOptions) {
    super(message, options)
    this.name = 'ReverseBridgeError'
  }
}

/** One call's per-request options. */
export interface ReverseCallOptions {
  /** Withdraws the call; the resident is told to cancel when it already received it. */
  signal?: AbortSignal | undefined
  /** Overrides the bridge's default request deadline. */
  timeoutMs?: number | undefined
}

/** Options of an operation that changes the target or the device. */
export interface ReverseMutationOptions extends ReverseCallOptions {
  /** The agent whose turn asks; the approval prompt routes here and the audit lands on its session. */
  agent: Agent
  /** The tool asking, used for the prompt's title and the audit record. */
  toolName: string
  /** The tool call being decided, so a UI can attach the prompt to what the model already streamed. */
  callId?: ToolCallId | undefined
  /**
   * What exactly will change, in the user's terms: process, operation, address or
   * symbol, and the value or generated source. This is the text a person reads
   * before deciding, so it never repeats the tool's own description.
   */
  summary: string
}

/** What the bridge can report about itself. */
export interface ReverseStatus {
  /** Current connection state. */
  state: ReverseState
  /** The socket path the bridge dials. */
  socketPath: string
  /** The resident's handshake, once it answered one. */
  resident?: ReverseResult<'system.hello'> | undefined
  /** Why the last attempt failed, cleared by the next success. */
  lastError?: string | undefined
  /** Requests waiting for a response. */
  pending: number
}

/**
 * The local bridge to the SpringBoard resident.
 *
 * Implementations must honor these semantics:
 * - {@link call} refuses a dangerous operation with `denied`, never forwarding it.
 * - {@link mutate} asks the approval service first and sends only on
 *   `'allowed-once'`; a missing approval service, a rejected decision, an
 *   unavailable answerer, or an aborted signal all leave the target untouched.
 * - Every failure is a {@link ReverseBridgeError} with one of the protocol's
 *   codes, so a tool can report a stable class instead of a raw socket error.
 * - `state` is `'disabled'` when the composition turned the bridge off; a
 *   disabled bridge fails every call instead of pretending to answer.
 */
export abstract class ReverseBridge extends Service {
  constructor(ctx: Context) {
    super(ctx, 'reverse')
  }

  /** Current connection state. */
  abstract get state(): ReverseState

  /**
   * Report the connection, dialing once when that is cheap and safe.
   * @param options - abort signal and timeout.
   * @returns the current status, including the resident handshake when reachable.
   */
  abstract status(options?: ReverseCallOptions): Promise<ReverseStatus>

  /**
   * Run one read-only operation.
   * @param op - the operation; a dangerous one is refused.
   * @param args - validated arguments.
   * @param options - signal and timeout.
   * @returns the resident's result.
   */
  abstract call<K extends ReverseOp>(op: K, args: ReverseArg<K>, options?: ReverseCallOptions): Promise<ReverseResult<K>>

  /**
   * Run one operation that changes the target, after the user approves exactly it.
   * @param op - the dangerous operation.
   * @param args - validated arguments.
   * @param options - the asking agent, the summary shown to the user, signal and timeout.
   * @returns the resident's result.
   */
  abstract mutate<K extends DangerousOp>(
    op: K,
    args: ReverseArg<K>,
    options: ReverseMutationOptions,
  ): Promise<ReverseResult<K>>
}
