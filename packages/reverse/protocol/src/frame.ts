/**
 * Framing for the local socket: one JSON object per line, UTF-8. A line is
 * complete at `\n`; a partial tail waits for the next chunk, so a reader never
 * parses half an object.
 *
 * Line framing, not length prefixes, because both ends already speak JSON and a
 * line keeps a captured stream readable while debugging a resident.
 * @module @deepseek-ai/dsh-reverse-protocol/frame
 */

import type { ReverseResponseFrame, ReverseWireError } from './types.ts'

/**
 * Largest single frame accepted. A one-mebibyte memory read renders as hex plus
 * ASCII, well under this; a larger line means the peer is broken, not verbose.
 */
export const MAX_FRAME_BYTES = 8 << 20

/** A frame that is not valid JSON, or not the shape the protocol promises. */
export class FrameError extends Error {
  /**
   * @param message - what is wrong with the frame.
   */
  constructor(message: string) {
    super(message)
    this.name = 'FrameError'
  }
}

/**
 * Incremental line splitter.
 *
 * Reusable across connections: {@link reset} drops a partial line so one broken
 * peer cannot poison the buffer of the next.
 */
export class LineFramer {
  private buffer = ''

  /**
   * Feed one decoded chunk.
   * @param chunk - text decoded from the socket.
   * @returns every complete line, in order, without their `\n`.
   * @throws FrameError when a pending line exceeds {@link MAX_FRAME_BYTES}.
   */
  push(chunk: string): string[] {
    this.buffer += chunk
    const lines: string[] = []
    let index = this.buffer.indexOf('\n')
    while (index >= 0) {
      const line = this.buffer.slice(0, index)
      this.buffer = this.buffer.slice(index + 1)
      const trimmed = line.endsWith('\r') ? line.slice(0, -1) : line
      if (trimmed.trim().length > 0) lines.push(trimmed)
      index = this.buffer.indexOf('\n')
    }
    if (this.buffer.length > MAX_FRAME_BYTES) {
      this.buffer = ''
      throw new FrameError(`pending frame exceeds ${MAX_FRAME_BYTES} bytes`)
    }
    return lines
  }

  /** Drop any partial line. */
  reset(): void {
    this.buffer = ''
  }
}

/**
 * Render one frame as a line ready for the socket.
 * @param value - the frame.
 * @returns JSON text ending in `\n`.
 * @throws FrameError when the frame is larger than {@link MAX_FRAME_BYTES}.
 */
export function encodeFrame(value: unknown): string {
  const text = JSON.stringify(value)
  if (text === undefined) throw new FrameError('frame is not serializable')
  const line = `${text}\n`
  if (Buffer.byteLength(line, 'utf8') > MAX_FRAME_BYTES) {
    throw new FrameError(`frame exceeds ${MAX_FRAME_BYTES} bytes`)
  }
  return line
}

/** Error codes a peer may report. */
const ERROR_CODES = new Set<string>([
  'bad-request', 'invalid-args', 'not-connected', 'timeout', 'cancelled', 'denied',
  'not-found', 'target-gone', 'unsupported', 'protocol-mismatch', 'remote-error',
])

/**
 * Parse one response line.
 * @param line - a complete line from {@link LineFramer}.
 * @returns the response frame.
 * @throws FrameError when the line is not JSON or not a response frame.
 */
export function parseResponse(line: string): ReverseResponseFrame {
  let parsed: unknown
  try {
    parsed = JSON.parse(line)
  } catch {
    throw new FrameError('response is not JSON')
  }
  if (typeof parsed !== 'object' || parsed === null) throw new FrameError('response is not an object')
  const frame = parsed as Record<string, unknown>
  if (typeof frame.id !== 'string') throw new FrameError('response has no id')
  const elapsedMs = typeof frame.elapsedMs === 'number' ? frame.elapsedMs : 0
  if (frame.ok === true) return { id: frame.id, ok: true, result: frame.result, elapsedMs }
  if (frame.ok !== false) throw new FrameError('response has no ok flag')
  return { id: frame.id, ok: false, error: toWireError(frame.error), elapsedMs }
}

/**
 * Narrow an unknown error payload, falling back to a generic code.
 * @param raw - the frame's error field.
 * @returns a well-formed wire error.
 */
function toWireError(raw: unknown): ReverseWireError {
  if (typeof raw === 'object' && raw !== null) {
    const record = raw as Record<string, unknown>
    const code = typeof record.code === 'string' && ERROR_CODES.has(record.code) ? record.code : 'remote-error'
    const message = typeof record.message === 'string' && record.message.length > 0
      ? record.message
      : 'the resident reported a failure without a message'
    return { code: code as ReverseWireError['code'], message }
  }
  return { code: 'remote-error', message: 'the resident reported a malformed error' }
}
