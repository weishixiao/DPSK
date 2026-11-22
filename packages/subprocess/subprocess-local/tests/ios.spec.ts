import { describe, expect, it } from 'vitest'
import { Context } from '@deepseek-ai/cordis'
import { SubprocessError } from '@deepseek-ai/dsh-subprocess'
import type { SubprocessSpawnSpec, SubprocessTerminalSpawnSpec } from '@deepseek-ai/dsh-subprocess'
import { IosSubprocessRuntime, IOS_SUBPROCESS_UNAVAILABLE } from '../src/ios.ts'

function spawnSpec(argv: readonly string[], overrides: Partial<SubprocessSpawnSpec> = {}): SubprocessSpawnSpec {
  return {
    argv,
    cwd: '/',
    stdio: {
      stdin: 'ignore',
      stdout: { maxBytes: 64_000 },
      stderr: { maxBytes: 64_000 },
    },
    graceMs: 200,
    ...overrides,
  }
}

function terminalSpec(
  argv: readonly string[],
  overrides: Partial<SubprocessTerminalSpawnSpec> = {},
): SubprocessTerminalSpawnSpec {
  return {
    argv,
    cwd: '/',
    rows: 24,
    cols: 80,
    terminalType: 'xterm-256color',
    graceMs: 200,
    ...overrides,
  }
}

/** Read one rejection as a value so its code and message can be asserted together. */
async function rejection(promise: Promise<unknown>): Promise<SubprocessError> {
  const error = await promise.then(
    () => { throw new Error('expected a rejection') },
    (reason: unknown) => { return reason },
  )
  expect(error).toBeInstanceOf(SubprocessError)
  return error as SubprocessError
}

describe('IosSubprocessRuntime', () => {
  it('refuses a spawn instead of letting the platform report a missing program', async () => {
    const ctx = new Context()
    await ctx.plugin(IosSubprocessRuntime)

    const handle = ctx.subprocess.spawn(spawnSpec(['bash', '-c', 'echo hello']))
    expect(handle.stdin).toBeUndefined()
    expect(handle.stdout).toBeUndefined()
    expect(handle.stderr).toBeUndefined()
    expect(handle.control).toBeUndefined()
    expect(handle.collected).toEqual({})

    const error = await rejection(handle.done)
    expect(error.code).toBe('SUBPROCESS_SPAWN_FAILED')
    expect(error.message).toBe(`subprocess-ios cannot start "bash": ${IOS_SUBPROCESS_UNAVAILABLE}`)
  })

  it('terminates and reports quiescence for a range that never started', async () => {
    const ctx = new Context()
    await ctx.plugin(IosSubprocessRuntime)

    const handle = ctx.subprocess.spawn(spawnSpec(['git']))
    // Attach inside the same tick: the refusal is already settled at spawn time.
    const settled = handle.done.catch((reason: unknown) => reason)
    expect(() => { handle.terminate() }).not.toThrow()
    expect(await handle.waitForExit()).toBe(true)
    expect(await handle.waitForExit(new AbortController().signal)).toBe(true)
    // A bound that already expired gave up before the (empty) range was observed.
    expect(await handle.waitForExit(AbortSignal.abort())).toBe(false)
    expect(await settled).toBeInstanceOf(SubprocessError)
  })

  it('names the program it could not start, or says the request named none', async () => {
    const ctx = new Context()
    await ctx.plugin(IosSubprocessRuntime)

    expect((await rejection(ctx.subprocess.spawn(spawnSpec([])).done)).message)
      .toBe(`subprocess-ios cannot start the requested program: ${IOS_SUBPROCESS_UNAVAILABLE}`)
    expect((await rejection(ctx.subprocess.spawn(spawnSpec([''])).done)).message)
      .toBe(`subprocess-ios cannot start the requested program: ${IOS_SUBPROCESS_UNAVAILABLE}`)
  })

  it('honors a pre-aborted signal before refusing a spawn', async () => {
    const ctx = new Context()
    await ctx.plugin(IosSubprocessRuntime)

    const reason = new Error('deadline passed')
    expect(() => ctx.subprocess.spawn(spawnSpec(['git'], { signal: AbortSignal.abort(reason) }))).toThrow(reason)
  })

  it('refuses executable lookup with the same platform reason', async () => {
    const ctx = new Context()
    await ctx.plugin(IosSubprocessRuntime)

    const error = await rejection(ctx.subprocess.resolveExecutable('git'))
    expect(error.code).toBe('SUBPROCESS_SPAWN_FAILED')
    expect(error.message).toBe(`subprocess-ios cannot start "git": ${IOS_SUBPROCESS_UNAVAILABLE}`)

    const reason = new Error('lookup cancelled')
    await expect(ctx.subprocess.resolveExecutable('git', undefined, AbortSignal.abort(reason)))
      .rejects.toBe(reason)
  })

  it('reports a POSIX platform without inventing a shell', async () => {
    const ctx = new Context()
    await ctx.plugin(IosSubprocessRuntime)

    await expect(ctx.subprocess.terminalEnvironment()).resolves.toEqual({ platform: 'posix' })

    const reason = new Error('inspection cancelled')
    await expect(ctx.subprocess.terminalEnvironment(AbortSignal.abort(reason))).rejects.toBe(reason)
  })

  it('reports the missing terminal as an unavailable PTY', async () => {
    const ctx = new Context()
    await ctx.plugin(IosSubprocessRuntime)

    const error = await rejection(ctx.subprocess.spawnTerminal(terminalSpec(['zsh'])))
    expect(error.code).toBe('SUBPROCESS_PTY_UNAVAILABLE')
    expect(error.message).toBe(`subprocess-ios cannot allocate a terminal for "zsh": ${IOS_SUBPROCESS_UNAVAILABLE}`)

    expect((await rejection(ctx.subprocess.spawnTerminal(terminalSpec([])))).message)
      .toBe(`subprocess-ios cannot allocate a terminal for the requested program: ${IOS_SUBPROCESS_UNAVAILABLE}`)
    expect((await rejection(ctx.subprocess.spawnTerminal(terminalSpec([''])))).message)
      .toBe(`subprocess-ios cannot allocate a terminal for the requested program: ${IOS_SUBPROCESS_UNAVAILABLE}`)

    const reason = new Error('allocation cancelled')
    await expect(ctx.subprocess.spawnTerminal(terminalSpec(['zsh'], { signal: AbortSignal.abort(reason) })))
      .rejects.toBe(reason)
  })
})
