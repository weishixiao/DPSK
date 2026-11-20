/**
 * The approval gate in front of everything that changes a target.
 *
 * This is the property the whole reverse workbench rests on: the model cannot reach
 * `memory.write`, `hook.install` or `inject.dylib` without a human decision, and a
 * composition with no approval service refuses rather than proceeding. The tests are
 * written against a bridge whose socket does not exist — so anything that reaches the
 * transport fails with `not-connected`, and anything refused at the gate fails with
 * `denied` *before* dialing. The distinction is the assertion: it proves the gate sits
 * in front of the wire, not behind it.
 */

import { describe, expect, it, vi } from 'vitest'
import { Context } from '@deepseek-ai/cordis'
import { LocalSocketReverseBridge } from '@deepseek-ai/dsh-reverse-bridge'
import { ReverseBridgeError } from '@deepseek-ai/dsh-reverse-bridge'
import type { ReverseMutationOptions } from '@deepseek-ai/dsh-reverse-bridge'

/** A socket path nothing listens on: reaching the transport always fails. */
const NO_RESIDENT = '/tmp/dpsk-reverse-test-does-not-exist.sock'

/** Minimal mutation options; the gate reads `summary` and passes the rest through. */
function mutation(overrides: Partial<ReverseMutationOptions> = {}): ReverseMutationOptions {
  return {
    agent: {} as ReverseMutationOptions['agent'],
    toolName: 'reverse_memory_write',
    summary: 'write 8 bytes',
    ...overrides,
  }
}

/** A bridge over a dead socket, with an optional approval service. */
function bridgeWith(approval?: unknown) {
  const ctx = new Context()
  if (approval !== undefined) ctx.provide('approval', approval as never)
  const bridge = new LocalSocketReverseBridge(ctx, {
    enabled: true,
    socketPath: NO_RESIDENT,
    timeoutMs: 200,
    connectTimeoutMs: 50,
  })
  return { bridge, ctx }
}

/** Run one call and return the code it failed with. */
async function codeOf(run: () => Promise<unknown>): Promise<string> {
  try {
    await run()
  } catch (error) {
    if (error instanceof ReverseBridgeError) return error.code
    throw error
  }
  return '(resolved)'
}

describe('call() refuses what changes the target', () => {
  it('rejects memory.write, hook.install and inject.dylib outright', async () => {
    const { bridge } = bridgeWith({ request: vi.fn() })
    for (const op of ['memory.write', 'hook.install', 'inject.dylib'] as const) {
      const args = op === 'memory.write'
        ? { pid: 1, address: '0x1000', type: 'u8' as const, value: '1' }
        : op === 'hook.install'
          ? { pid: 1, image: 'App', symbol: 's', mode: 'replace' as const, source: 'x' }
          : { pid: 1, dylibPath: '/var/jb/usr/lib/Foo.dylib' }
      expect(await codeOf(() => bridge.call(op, args as never))).toBe('denied')
    }
  })

  it('does not even ask, because the refusal is structural', async () => {
    const request = vi.fn()
    const { bridge } = bridgeWith({ request })
    await codeOf(() => bridge.call('memory.write', { pid: 1, address: '0x1000', type: 'u8', value: '1' } as never))
    expect(request).not.toHaveBeenCalled()
  })
})

describe('mutate() needs a decision', () => {
  it('refuses when the composition has no approval service', async () => {
    const { bridge } = bridgeWith(undefined)
    expect(await codeOf(() => bridge.mutate('memory.write',
      { pid: 1, address: '0x1000', type: 'u8', value: '1' }, mutation()))).toBe('denied')
  })

  it('refuses every answer that is not allowed-once', async () => {
    for (const answer of ['denied', 'allowed-for-session', 'timeout'] as const) {
      const { bridge } = bridgeWith({ request: vi.fn(async () => answer) })
      expect(await codeOf(() => bridge.mutate('memory.write',
        { pid: 1, address: '0x1000', type: 'u8', value: '1' }, mutation()))).toBe('denied')
    }
  })

  it('passes the summary through to the prompt, unmodified', async () => {
    const request = vi.fn(async () => 'denied' as const)
    const { bridge } = bridgeWith({ request })
    const summary = 'write 8 bytes at 0x1000 in pid 1234 com.example.app'
    await codeOf(() => bridge.mutate('memory.write',
      { pid: 1, address: '0x1000', type: 'u64', value: '0' }, mutation({ summary })))
    expect(request).toHaveBeenCalledOnce()
    expect((request.mock.calls[0] as unknown as [{ reason: string }])[0].reason).toBe(summary)
  })

  it('turns a throwing approval into a denial, never a send', async () => {
    const { bridge } = bridgeWith({ request: vi.fn(async () => { throw new Error('outside an open turn') }) })
    expect(await codeOf(() => bridge.mutate('memory.write',
      { pid: 1, address: '0x1000', type: 'u8', value: '1' }, mutation()))).toBe('denied')
  })

  it('proceeds past the gate once approved, and only then reaches the transport', async () => {
    const { bridge } = bridgeWith({ request: vi.fn(async () => 'allowed-once' as const) })
    // Approved: the refusal now comes from the missing socket, which proves the gate
    // let it through instead of denying it.
    expect(await codeOf(() => bridge.mutate('memory.write',
      { pid: 1, address: '0x1000', type: 'u8', value: '1' }, mutation()))).toBe('not-connected')
  })
})

describe('read-only operations do not ask', () => {
  it('dials without an approval service at all', async () => {
    const { bridge } = bridgeWith(undefined)
    // No gate, no socket: the failure is transport, not permission.
    expect(await codeOf(() => bridge.call('process.list', {}))).toBe('not-connected')
  })
})
