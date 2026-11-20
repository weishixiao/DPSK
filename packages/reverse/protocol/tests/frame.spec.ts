/**
 * Line framing over the local socket.
 *
 * The resident and the bridge both trust this file for one thing: a JSON object is
 * never handed on half-read. The cases that matter are the ugly ones — a chunk split
 * mid-object, a CRLF peer, a blank line, and a line that grows past the cap.
 */

import { describe, expect, it } from 'vitest'
import {
  FrameError,
  LineFramer,
  MAX_FRAME_BYTES,
  encodeFrame,
  parseResponse,
} from '@deepseek-ai/dsh-reverse-protocol'

describe('LineFramer', () => {
  it('emits nothing until the newline arrives', () => {
    const framer = new LineFramer()
    expect(framer.push('{"id":"a"')).toEqual([])
    expect(framer.push(',"ok":true}')).toEqual([])
    expect(framer.push('\n')).toEqual(['{"id":"a","ok":true}'])
  })

  it('emits several lines from one chunk, in order', () => {
    const framer = new LineFramer()
    expect(framer.push('one\ntwo\nthree')).toEqual(['one', 'two'])
    expect(framer.push('\n')).toEqual(['three'])
  })

  it('drops the CR of a CRLF peer', () => {
    const framer = new LineFramer()
    expect(framer.push('one\r\ntwo\r\n')).toEqual(['one', 'two'])
  })

  it('ignores blank and whitespace-only lines', () => {
    const framer = new LineFramer()
    expect(framer.push('\n\n   \n{"a":1}\n')).toEqual(['{"a":1}'])
  })

  it('refuses a pending line past the cap instead of buffering forever', () => {
    const framer = new LineFramer()
    expect(() => framer.push('x'.repeat(MAX_FRAME_BYTES + 1))).toThrow(FrameError)
    // The buffer was dropped, so the next peer starts clean rather than inheriting it.
    expect(framer.push('{"a":1}\n')).toEqual(['{"a":1}'])
  })

  it('drops a partial line on reset', () => {
    const framer = new LineFramer()
    framer.push('{"half":')
    framer.reset()
    expect(framer.push('{"a":1}\n')).toEqual(['{"a":1}'])
  })
})

describe('encodeFrame', () => {
  it('ends the line with exactly one newline', () => {
    expect(encodeFrame({ id: 'a', op: 'memory.read', args: {} })).toBe('{"id":"a","op":"memory.read","args":{}}\n')
  })

  it('refuses a value JSON cannot render', () => {
    expect(() => encodeFrame(undefined)).toThrow(FrameError)
    expect(() => encodeFrame(() => 1)).toThrow(FrameError)
  })

  it('refuses a frame past the cap', () => {
    expect(() => encodeFrame({ blob: 'x'.repeat(MAX_FRAME_BYTES) })).toThrow(FrameError)
  })
})

describe('parseResponse', () => {
  it('reads a success frame and defaults a missing elapsedMs', () => {
    expect(parseResponse('{"id":"a","ok":true,"result":{"hex":"00"}}'))
      .toEqual({ id: 'a', ok: true, result: { hex: '00' }, elapsedMs: 0 })
    expect(parseResponse('{"id":"a","ok":true,"result":1,"elapsedMs":7}').elapsedMs).toBe(7)
  })

  it('reads a failure frame', () => {
    expect(parseResponse('{"id":"a","ok":false,"error":{"code":"denied","message":"no"},"elapsedMs":2}'))
      .toEqual({ id: 'a', ok: false, error: { code: 'denied', message: 'no' }, elapsedMs: 2 })
  })

  it('keeps a known code and replaces an unknown one', () => {
    const known = parseResponse('{"id":"a","ok":false,"error":{"code":"target-gone","message":"x"}}')
    expect(known.ok === false && known.error.code).toBe('target-gone')
    const unknown = parseResponse('{"id":"a","ok":false,"error":{"code":"wat","message":"x"}}')
    expect(unknown.ok === false && unknown.error.code).toBe('remote-error')
  })

  it('substitutes a message when the peer sent none', () => {
    const frame = parseResponse('{"id":"a","ok":false,"error":{"code":"denied"}}')
    expect(frame.ok === false && frame.error.message.length > 0).toBe(true)
  })

  it('rejects what is not a response frame', () => {
    expect(() => parseResponse('not json')).toThrow(FrameError)
    expect(() => parseResponse('[]')).toThrow(FrameError)
    expect(() => parseResponse('{"ok":true}')).toThrow(FrameError)
    expect(() => parseResponse('{"id":"a"}')).toThrow(FrameError)
  })
})
