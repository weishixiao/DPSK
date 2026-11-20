/**
 * Canonicalization at the seam, not only in the tools.
 *
 * The bridge is what any consumer of `ctx.reverse` goes through, so these are the
 * checks that hold even for a caller that never touched a tool schema: a pid written
 * as text, an address without `0x`, a hook whose library was never built. The last
 * one is the interesting case — `hook.install` without `dylibPath` must still be
 * framable, because the resident's refusal names the missing build step, which is a
 * better answer than a schema error here.
 */

import { describe, expect, it } from 'vitest'
import { ReverseArgsError } from '@deepseek-ai/dsh-reverse-protocol'
import { normalizeArguments } from '@deepseek-ai/dsh-reverse-bridge'

/** The field a rejection names, or a marker when nothing was thrown. */
function rejected(fn: () => unknown): string {
  try {
    fn()
  } catch (error) {
    if (error instanceof ReverseArgsError) return error.field
    throw error
  }
  return '(accepted)'
}

describe('pids written as text', () => {
  it('accepts a decimal string, which is what a model writes', () => {
    expect(normalizeArguments('process.images', { pid: '1234' })).toEqual({ pid: 1234 })
  })

  it('does not accept a hex string as a pid', () => {
    // 0x4d2 is 1234, but a pid field is decimal on the wire; guessing invites an
    // operation against a different process than the one the model meant.
    expect(rejected(() => normalizeArguments('process.images', { pid: '0x4d2' }))).toBe('pid')
  })

  it('trims padding but refuses a sign', () => {
    // coercePid trims before matching, so ' 12' is the same pid as '12'.
    expect(normalizeArguments('process.images', { pid: ' 12' })).toEqual({ pid: 12 })
    expect(rejected(() => normalizeArguments('process.images', { pid: '+12' }))).toBe('pid')
    expect(rejected(() => normalizeArguments('process.images', { pid: '-12' }))).toBe('pid')
  })
})

describe('process list filters', () => {
  it('passes a name fragment through untouched', () => {
    expect(normalizeArguments('process.list', { filter: 'SpringBoard' })).toEqual({ filter: 'SpringBoard' })
  })

  it('validates a filter that announces itself as a bundle id', () => {
    expect(normalizeArguments('process.list', { filter: 'com.burbn.instagram' }))
      .toEqual({ filter: 'com.burbn.instagram' })
    // The id regex allows any run of dots after the first character, so 'com..bad'
    // passes. Pinned rather than asserted as desirable: tightening it belongs with
    // the validator, not here.
    expect(normalizeArguments('process.list', { filter: 'com..bad' })).toEqual({ filter: 'com..bad' })
    expect(rejected(() => normalizeArguments('process.list', { filter: 'com.burbn.insta gram' }))).toBe('bundleId')
  })

  it('omits an absent or blank filter', () => {
    expect(normalizeArguments('process.list', {})).toEqual({})
    expect(normalizeArguments('process.list', { filter: '   ' })).toEqual({})
  })
})

describe('memory operations', () => {
  it('normalizes an address and applies the default scan limit', () => {
    expect(normalizeArguments('memory.read', { pid: 1, address: '1000', length: 16 }))
      .toEqual({ pid: 1, address: '0x1000', length: 16 })
    expect(normalizeArguments('memory.scan', { pid: 1, type: 'u64', value: '0' }))
      .toEqual({ pid: 1, type: 'u64', value: '0', limit: 500 })
  })

  it('carries a scan window through, validated', () => {
    expect(normalizeArguments('memory.scan', {
      pid: 1, type: 'u32', value: '9', range: { from: '0x1000', to: '0x2000' },
    })).toEqual({ pid: 1, type: 'u32', value: '9', limit: 500, range: { from: '0x1000', to: '0x2000' } })
    expect(rejected(() => normalizeArguments('memory.scan', {
      pid: 1, type: 'u32', value: '9', range: { from: '0x2000', to: '0x1000' },
    }))).toBe('range')
  })

  it('refuses a write whose value does not fit its width', () => {
    expect(rejected(() => normalizeArguments('memory.write', {
      pid: 1, address: '0x1000', type: 'u8', value: '300',
    }))).toBe('value')
  })
})

describe('hook.install', () => {
  const source = 'static void f(void) {}'

  it('keeps the built library when the caller has one', () => {
    expect(normalizeArguments('hook.install', {
      pid: 1,
      image: 'App',
      symbol: 'dpsk_hook_initialize',
      mode: 'replace',
      source,
      dylibPath: '/var/mobile/Tweaks/VIPHook/.theos/obj/VIPHook.dylib',
    })).toEqual({
      pid: 1,
      image: 'App',
      symbol: 'dpsk_hook_initialize',
      mode: 'replace',
      source,
      dylibPath: '/var/mobile/Tweaks/VIPHook/.theos/obj/VIPHook.dylib',
    })
  })

  it('frames without a library so the resident can say which step is missing', () => {
    const args = normalizeArguments('hook.install', {
      pid: 1, image: 'App', symbol: 'dpsk_hook_initialize', mode: 'log-only', source,
    })
    expect(args).toEqual({ pid: 1, image: 'App', symbol: 'dpsk_hook_initialize', mode: 'log-only', source })
    expect('dylibPath' in args).toBe(false)
  })

  it('still validates the library path when one is given', () => {
    expect(rejected(() => normalizeArguments('hook.install', {
      pid: 1, image: 'App', symbol: 's', mode: 'replace', source, dylibPath: 'relative/Foo.dylib',
    }))).toBe('dylibPath')
  })

  it('rejects a mode the resident does not implement', () => {
    expect(rejected(() => normalizeArguments('hook.install', {
      pid: 1, image: 'App', symbol: 's', mode: 'replace-everything', source,
    }))).toBe('mode')
  })

  it('rejects empty source', () => {
    expect(rejected(() => normalizeArguments('hook.install', {
      pid: 1, image: 'App', symbol: 's', mode: 'replace', source: '  ',
    }))).toBe('source')
  })
})

describe('inject.dylib', () => {
  it('accepts an absolute library path', () => {
    expect(normalizeArguments('inject.dylib', { pid: 1, dylibPath: '/var/jb/usr/lib/Foo.dylib' }))
      .toEqual({ pid: 1, dylibPath: '/var/jb/usr/lib/Foo.dylib' })
  })

  it('rejects a traversal', () => {
    expect(rejected(() => normalizeArguments('inject.dylib', {
      pid: 1, dylibPath: '/var/mobile/../../etc/passwd',
    }))).toBe('dylibPath')
  })
})

describe('limits and symbols', () => {
  it('clamps a symbol limit to what the resident will render', () => {
    expect(normalizeArguments('process.symbols', { pid: 1, limit: 5000 }))
      .toEqual({ pid: 1, limit: 2000 })
    expect(normalizeArguments('process.symbols', { pid: 1 }))
      .toEqual({ pid: 1, limit: 200 })
  })

  it('keeps an image selector and a filter when given', () => {
    expect(normalizeArguments('process.symbols', { pid: 1, image: 'libobjc.A.dylib', filter: 'class_' }))
      .toEqual({ pid: 1, image: 'libobjc.A.dylib', filter: 'class_', limit: 200 })
  })
})

describe('macho.analyze', () => {
  it('defaults the strings limit', () => {
    expect(normalizeArguments('macho.analyze', { path: '/var/containers/Bundle/App/App' }))
      .toEqual({ path: '/var/containers/Bundle/App/App', stringsLimit: 200 })
  })

  it('rejects a relative path', () => {
    expect(rejected(() => normalizeArguments('macho.analyze', { path: 'App.app/App' }))).toBe('path')
  })
})

describe('system.logs', () => {
  it('defaults the limit and clamps it to the ring', () => {
    expect(normalizeArguments('system.logs', {})).toEqual({ limit: 50 })
    expect(normalizeArguments('system.logs', { limit: 5000 })).toEqual({ limit: 200 })
  })
})
