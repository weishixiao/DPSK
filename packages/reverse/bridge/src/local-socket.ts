/**
 * Local-socket Service Provider for the `ctx.reverse` seam.
 *
 * One Unix domain socket to the resident the SpringBoard tweak starts. The socket
 * is the transport because that is what survives the device's isolation: a
 * sandboxed or rootless-confined process can reach a socket file the jailbreak
 * root exposes, while a Mach service lookup is refused. The frames on it are the
 * protocol's NDJSON, so the two ends never share memory or a runtime.
 *
 * Responsibilities kept here, and nowhere else:
 * - dialing, handshake, and one request table over the connection;
 * - turning every transport and protocol failure into a classified error;
 * - the approval gate in front of every operation that changes the target.
 * @module @deepseek-ai/dsh-reverse-bridge/local-socket
 */

import { randomUUID } from 'node:crypto'
import { createConnection } from 'node:net'
import type { Socket } from 'node:net'
import { Context } from '@deepseek-ai/cordis'
import z from '@deepseek-ai/schemastery'
import {
  encodeFrame,
  isDangerousOp,
  LineFramer,
  parseResponse,
  PROTOCOL_VERSION,
} from '@deepseek-ai/dsh-reverse-protocol'
import type {
  DangerousOp,
  ReverseArg,
  ReverseErrorCode,
  ReverseOp,
  ReverseResponseFrame,
  ReverseResult,
} from '@deepseek-ai/dsh-reverse-protocol'
// Type-only: resolves the `ctx.approval` service declaration without depending on
// its implementation. The bridge works in compositions without it — every
// dangerous operation is then refused, which is the fail-closed direction.
// This is the repository's pattern for an optional service (see
// packages/subagent/subagent/src/child-agent.ts); it needs the project reference
// in tsconfig.json, which is what lets TypeScript see another package's sources.
import type {} from '@deepseek-ai/dsh-user-approval'
import { ReverseBridge, ReverseBridgeError } from './seam.ts'
import type { ReverseCallOptions, ReverseMutationOptions, ReverseState, ReverseStatus } from './seam.ts'
import { normalizeArguments } from './normalize.ts'

/** Provider configuration. */
export interface Config {
  /** Whether the bridge may dial at all; `false` fails every call instead of answering. */
  enabled: boolean
  /** Path of the socket the resident listens on. */
  socketPath: string
  /** Deadline of one request, including the resident's own work. */
  timeoutMs: number
  /** Deadline of a single dial. */
  connectTimeoutMs: number
}

/** Schema of the provider configuration. */
export const Config: z<Config> = z.object({
  enabled: z.boolean().default(true),
  socketPath: z.string().default('/var/mobile/Library/DSHReverse/rvd.sock'),
  timeoutMs: z.number().default(20_000),
  connectTimeoutMs: z.number().default(2_000),
})

/** One in-flight request, resolved by its response frame. */
interface PendingRequest {
  op: ReverseOp
  resolve: (value: unknown) => void
  reject: (error: Error) => void
  timer: ReturnType<typeof setTimeout>
  detach: () => void
}

/**
 * The resident connection.
 *
 * A single socket is reused for every request; requests are multiplexed by frame
 * id. A transport failure fails every pending request with `not-connected` and
 * drops the socket, so the next call dials again rather than writing into a dead
 * pipe.
 */
export class LocalSocketReverseBridge extends ReverseBridge {
  static Config = Config

  private socket: Socket | undefined
  private readonly framer = new LineFramer()
  private readonly pending = new Map<string, PendingRequest>()
  private connecting: Promise<void> | undefined
  private resident: ReverseResult<'system.hello'> | undefined
  private lastError: string | undefined
  private sequence = 0

  /**
   * @param ctx - host context; `ctx.approval` is looked up per mutation.
   * @param config - validated provider configuration.
   */
  constructor(ctx: Context, readonly config: Config) {
    super(ctx)
    ctx.effect(() => () => { this.dispose() })
  }

  get state(): ReverseState {
    if (!this.config.enabled) return 'disabled'
    if (this.connecting !== undefined) return 'connecting'
    if (this.socket !== undefined && !this.socket.destroyed) return 'ready'
    return 'offline'
  }

  /**
   * Report the connection. A disabled bridge reports without dialing; an idle one
   * dials so the caller learns whether a resident is reachable.
   * @param options - signal and timeout for the dial.
   * @returns the current status.
   */
  async status(options: ReverseCallOptions = {}): Promise<ReverseStatus> {
    if (this.config.enabled && this.state !== 'ready') {
      try {
        await this.ensureConnected(options.signal)
      } catch (error) {
        // Reporting is not the place to throw: the caller asked what the state is.
        this.lastError = error instanceof Error ? error.message : String(error)
      }
    }
    return {
      state: this.state,
      socketPath: this.config.socketPath,
      ...this.resident === undefined ? {} : { resident: this.resident },
      ...this.lastError === undefined ? {} : { lastError: this.lastError },
      pending: this.pending.size,
    }
  }

  async call<K extends ReverseOp>(op: K, args: ReverseArg<K>, options: ReverseCallOptions = {}): Promise<ReverseResult<K>> {
    if (isDangerousOp(op)) {
      throw new ReverseBridgeError(
        'denied',
        `"${op}" changes the target and is not available through call(); use mutate() so the user decides`,
      )
    }
    return this.dispatch(op, args, options) as Promise<ReverseResult<K>>
  }

  async mutate<K extends DangerousOp>(
    op: K,
    args: ReverseArg<K>,
    options: ReverseMutationOptions,
  ): Promise<ReverseResult<K>> {
    await this.approve(op, options)
    return this.dispatch(op, args, options) as Promise<ReverseResult<K>>
  }

  /**
   * Close the socket and fail every pending request; the composition calls this on
   * unload so a reload does not leave a half-read frame behind.
   */
  dispose(): void {
    this.failAll(new ReverseBridgeError('not-connected', 'the reverse bridge was unloaded'))
    this.socket?.destroy()
    this.socket = undefined
    this.framer.reset()
  }

  /**
   * Ask the user before a dangerous operation reaches the resident.
   * @param op - the operation about to run.
   * @param options - the asking agent and the summary shown to the user.
   * @throws ReverseBridgeError `denied` unless the decision is `allowed-once`.
   */
  private async approve(op: DangerousOp, options: ReverseMutationOptions): Promise<void> {
    const approval = this.ctx.get('approval')
    if (approval === undefined) {
      throw new ReverseBridgeError(
        'denied',
        `"${op}" needs a human decision, and this composition has no approval service`,
      )
    }
    let outcome: Awaited<ReturnType<typeof approval.request>>
    try {
      outcome = await approval.request({
        agent: options.agent,
        toolName: options.toolName,
        reason: options.summary,
        ...options.callId === undefined ? {} : { callId: options.callId },
        ...options.signal === undefined ? {} : { signal: options.signal },
      })
    } catch (error) {
      throw new ReverseBridgeError(
        'denied',
        `"${op}" was not confirmed: ${error instanceof Error ? error.message : String(error)}`,
        { cause: error },
      )
    }
    if (outcome !== 'allowed-once') {
      throw new ReverseBridgeError('denied', `"${op}" was not confirmed (${outcome}); nothing was sent`)
    }
    this.ctx.logger.info(`[reverse] approved: ${op}`)
  }

  /**
   * Frame, send and await one request.
   * @param op - operation name.
   * @param args - canonical arguments.
   * @param options - signal and timeout.
   * @returns the resident's result payload.
   */
  private async dispatch(op: ReverseOp, args: unknown, options: ReverseCallOptions): Promise<unknown> {
    const socket = await this.ensureConnected(options.signal)
    return this.write(socket, op, args, options)
  }

  /**
   * Dial once, handshake once, and keep the socket.
   * @param signal - withdraws the dial.
   * @returns the connected socket.
   */
  private async ensureConnected(signal?: AbortSignal): Promise<Socket> {
    const live = this.socket
    if (live !== undefined && !live.destroyed && live.writable) return live
    if (!this.config.enabled) {
      throw new ReverseBridgeError('not-connected', 'the reverse bridge is disabled in this composition')
    }
    this.connecting ??= this.open(signal).finally(() => { this.connecting = undefined })
    await this.connecting
    const socket = this.socket
    if (socket === undefined) {
      throw new ReverseBridgeError(
        'not-connected',
        this.lastError ?? `no resident answered on ${this.config.socketPath}`,
      )
    }
    return socket
  }

  /**
   * Open the socket and complete the handshake.
   * @param signal - withdraws the dial.
   */
  private async open(signal?: AbortSignal): Promise<void> {
    const path = this.config.socketPath
    const socket = createConnection({ path })
    try {
      await new Promise<void>((resolve, reject) => {
        const timer = setTimeout(() => {
          reject(new ReverseBridgeError('not-connected', `dialing ${path} timed out`))
        }, this.config.connectTimeoutMs)
        const onAbort = (): void => {
          reject(new ReverseBridgeError('cancelled', `dialing ${path} was cancelled`))
        }
        const settle = (): void => {
          clearTimeout(timer)
          signal?.removeEventListener('abort', onAbort)
        }
        socket.once('connect', () => { settle(); resolve() })
        socket.once('error', (error: Error) => {
          settle()
          reject(new ReverseBridgeError('not-connected', `cannot dial ${path}: ${error.message}`, { cause: error }))
        })
        signal?.addEventListener('abort', onAbort, { once: true })
      })
    } catch (error) {
      socket.destroy()
      this.lastError = error instanceof Error ? error.message : String(error)
      throw error
    }

    this.socket = socket
    this.framer.reset()
    socket.on('data', (chunk: Buffer) => { this.onData(chunk) })
    socket.on('error', (error: Error) => {
      this.lastError = `socket error: ${error.message}`
      this.failAll(new ReverseBridgeError('not-connected', this.lastError, { cause: error }))
    })
    socket.on('close', () => {
      if (this.socket === socket) this.socket = undefined
      this.failAll(new ReverseBridgeError('not-connected', `the resident closed ${path}`))
    })

    const hello = await this.write(socket, 'system.hello', {}) as ReverseResult<'system.hello'>
    if (hello.version !== PROTOCOL_VERSION) {
      socket.destroy()
      this.socket = undefined
      throw new ReverseBridgeError(
        'protocol-mismatch',
        `the resident speaks protocol ${hello.version}, the harness speaks ${PROTOCOL_VERSION}; reinstall both halves`,
      )
    }
    this.resident = hello
    this.lastError = undefined
    this.ctx.logger.info(`[reverse] resident ready: ${hello.resident} (iOS ${hello.ios}, ${hello.arch})`)
  }

  /**
   * Write one frame and await its response.
   * @param socket - the live socket.
   * @param op - operation name.
   * @param args - arguments already canonicalized by the caller path.
   * @param options - signal and timeout.
   * @returns the result payload.
   */
  private write(socket: Socket, op: ReverseOp, args: unknown, options: ReverseCallOptions = {}): Promise<unknown> {
    const signal = options.signal
    if (signal?.aborted === true) {
      return Promise.reject(new ReverseBridgeError('cancelled', `"${op}" was cancelled before it was sent`))
    }
    const id = `r${++this.sequence}-${randomUUID().slice(0, 8)}`
    const timeoutMs = options.timeoutMs ?? this.config.timeoutMs
    return new Promise<unknown>((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pending.delete(id)
        reject(new ReverseBridgeError('timeout', `"${op}" did not answer within ${timeoutMs}ms`))
      }, timeoutMs)
      const onAbort = (): void => {
        this.pending.delete(id)
        clearTimeout(timer)
        reject(new ReverseBridgeError('cancelled', `"${op}" was cancelled`))
      }
      signal?.addEventListener('abort', onAbort, { once: true })
      this.pending.set(id, {
        op,
        resolve,
        reject,
        timer,
        detach: () => {
          clearTimeout(timer)
          signal?.removeEventListener('abort', onAbort)
        },
      })
      try {
        socket.write(encodeFrame({ id, op, args }))
      } catch (error) {
        this.pending.delete(id)
        clearTimeout(timer)
        signal?.removeEventListener('abort', onAbort)
        reject(new ReverseBridgeError('not-connected', `cannot write to the resident: ${errorMessage(error)}`, { cause: error }))
        return
      }
    })
  }

  /**
   * Consume socket bytes and settle the requests they answer.
   * @param chunk - raw bytes from the socket.
   */
  private onData(chunk: Buffer): void {
    let frames: ReverseResponseFrame[]
    try {
      frames = this.framer.push(chunk.toString('utf8')).map(line => parseResponse(line))
    } catch (error) {
      // A malformed frame means the stream cannot be trusted any more: drop it
      // rather than resynchronizing on a guess.
      this.lastError = `malformed frame: ${errorMessage(error)}`
      this.ctx.logger.warn(`[reverse] ${this.lastError}`)
      this.socket?.destroy()
      this.socket = undefined
      this.framer.reset()
      this.failAll(new ReverseBridgeError('remote-error', this.lastError, { cause: error }))
      return
    }
    for (const frame of frames) this.settle(frame)
  }

  /**
   * Settle one request from its response frame.
   * @param frame - parsed response.
   */
  private settle(frame: ReverseResponseFrame): void {
    const pending = this.pending.get(frame.id)
    if (pending === undefined) {
      // A cancelled request's answer arrives late; nothing to do with it.
      this.ctx.logger.debug?.(`[reverse] <- unmatched response ${frame.id}`)
      return
    }
    this.pending.delete(frame.id)
    pending.detach()
    if (frame.ok) {
      pending.resolve(frame.result)
      return
    }
    pending.reject(new ReverseBridgeError(frame.error.code, frame.error.message))
  }

  /**
   * Fail every pending request with one error.
   * @param error - the failure to deliver.
   */
  private failAll(error: ReverseBridgeError): void {
    for (const [id, pending] of this.pending) {
      this.pending.delete(id)
      pending.detach()
      pending.reject(new ReverseBridgeError(error.code as ReverseErrorCode, error.message))
    }
  }
}

/**
 * Render an unknown thrown value as a message.
 * @param error - the thrown value.
 * @returns its message, or its text.
 */
function errorMessage(error: unknown): string {
  return error instanceof Error ? error.message : String(error)
}

export { normalizeArguments }
export default LocalSocketReverseBridge
