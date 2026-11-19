/**
 * The two operations that put code into a target: a Substrate hook and a dylib
 * injection. Both change the running process, both go through `mutate()`, and both
 * approval prompts show the generated source or the library path before anything
 * is sent.
 * @module @deepseek-ai/dsh-tool-reverse-tweak
 */

import type { Context } from '@deepseek-ai/cordis'
import { defineTool, ToolContextUnavailableError } from '@deepseek-ai/dsh-tools'
import type { ReverseBridge } from '@deepseek-ai/dsh-reverse-bridge'
import { normalizeArguments } from '@deepseek-ai/dsh-reverse-bridge'

export const name = 'tool-reverse-tweak'
export const inject = ['tools', 'reverse']

/** Lines of generated source an approval prompt shows before eliding. */
const SUMMARY_SOURCE_LINES = 24

/** Deadline of the process label lookup in an approval summary. */
const LABEL_TIMEOUT_MS = 1_500

/**
 * Register the hook and injection tools.
 * @param ctx - registrant context with the tool registry and the reverse bridge.
 */
export function apply(ctx: Context): void {
  const reverse: ReverseBridge = ctx.reverse

  ctx.tools.register(defineTool({
    name: 'reverse_hook_install',
    description:
      'Install one Substrate hook in a running process at a symbol you have already resolved with '
      + 'reverse_symbols. You supply the generated source: a complete MSHookFunction / '
      + 'MSHookMessageEx statement with its replacement function, in the style the resident compiles '
      + 'in place. This changes the target, so it always stops for the user\'s decision, and the prompt '
      + 'shows the source you wrote. Prefer mode "log-only" when you only need to see whether a '
      + 'path is reached; use "replace" to change behaviour such as a VIP or purchase check.',
    parameters: {
      pid: { type: 'integer', required: true, description: 'Process id.' },
      image: { type: 'string', required: true, description: 'Image that owns the symbol, as returned by reverse_symbols or reverse_process_images.' },
      symbol: { type: 'string', required: true, description: 'Symbol or ObjC method to hook, e.g. "_objc_msgSend" is not valid here — use the method name such as "-[TTVipManager isVip]".' },
      mode: {
        type: 'string',
        required: true,
        enum: ['replace', 'log-only'],
        description: 'replace changes behaviour; log-only observes without altering the result.',
      },
      source: {
        type: 'string',
        required: true,
        description: 'Complete hook source: the original declaration, your replacement function, and the MSHook* call. No includes; the resident provides them.',
      },
    },
    output: {
      schema: {
        type: 'object',
        additionalProperties: false,
        properties: {
          handle: { type: 'string', required: true },
          mode: { type: 'string', required: true },
          original: { type: 'string' },
        },
      },
      render: (_args, value) => ({
        type: 'text',
        text: `Hook ${value.handle} installed (${value.mode})`
          + `${value.original === undefined ? '' : `, original at ${value.original}`}.`,
      }),
    },
    async execute(args, exec) {
      if (exec.agent === undefined) {
        throw new ToolContextUnavailableError('reverse_hook_install needs an agent turn to ask for approval')
      }
      const typed = normalizeArguments('hook.install', {
        pid: args.pid,
        image: args.image,
        symbol: args.symbol,
        mode: args.mode,
        source: args.source,
      })
      const label = await targetLabel(reverse, typed.pid, exec.signal)
      const result = await reverse.mutate('hook.install', typed, {
        agent: exec.agent,
        toolName: 'reverse_hook_install',
        callId: exec.rootCallId,
        signal: exec.signal,
        summary: [
          `Hook installation in ${label}`,
          `image ${typed.image}, symbol ${typed.symbol}, mode ${typed.mode}`,
          'source:',
          indent(elide(typed.source, SUMMARY_SOURCE_LINES)),
        ].join('\n'),
      })
      return {
        handle: result.handle,
        mode: result.mode,
        ...result.original === null ? {} : { original: result.original },
      }
    },
    presentCall: args => ({
      card: 'generic',
      title: `Hook ${args.symbol}`,
      kind: 'other',
      rawInput: { pid: args.pid, image: args.image, symbol: args.symbol, mode: args.mode },
    }),
  }))

  ctx.tools.register(defineTool({
    name: 'reverse_inject_dylib',
    description:
      'Load a dylib into a running process by absolute path, typically one built on this device with '
      + 'Theos. This changes the target, so it always stops for the user\'s decision. The library must '
      + 'be built for the target\'s architecture and its installation must be the one the resident can '
      + 'read; a path outside the jailbreak root is refused.',
    parameters: {
      pid: { type: 'integer', required: true, description: 'Process id.' },
      dylibPath: { type: 'string', required: true, description: 'Absolute path of the built dylib, e.g. /var/jb/usr/lib/TweakInject/Foo.dylib.' },
    },
    output: {
      schema: {
        type: 'object',
        additionalProperties: false,
        properties: {
          injected: { type: 'boolean', required: true },
          image: { type: 'string' },
        },
      },
      render: (_args, value) => ({
        type: 'text',
        text: value.injected
          ? `Loaded ${value.image ?? 'the library'} into the target.`
          : 'The resident did not load the library.',
      }),
    },
    async execute(args, exec) {
      if (exec.agent === undefined) {
        throw new ToolContextUnavailableError('reverse_inject_dylib needs an agent turn to ask for approval')
      }
      const typed = normalizeArguments('inject.dylib', { pid: args.pid, dylibPath: args.dylibPath })
      const label = await targetLabel(reverse, typed.pid, exec.signal)
      const result = await reverse.mutate('inject.dylib', typed, {
        agent: exec.agent,
        toolName: 'reverse_inject_dylib',
        callId: exec.rootCallId,
        signal: exec.signal,
        summary: [
          `Dylib injection into ${label}`,
          `library ${typed.dylibPath}`,
        ].join('\n'),
      })
      return {
        injected: result.injected,
        ...result.image === null ? {} : { image: result.image },
      }
    },
    presentCall: args => ({
      card: 'generic',
      title: 'Inject dylib',
      kind: 'other',
      rawInput: args,
    }),
  }))
}

/**
 * Name a process for an approval prompt, falling back to its pid.
 * @param reverse - the bridge.
 * @param pid - target pid.
 * @param signal - the tool call's signal.
 * @returns `pid 1234 com.foo.App` where the resident knows it, else `pid 1234`.
 */
async function targetLabel(reverse: ReverseBridge, pid: number, signal: AbortSignal): Promise<string> {
  try {
    const result = await reverse.call('process.list', {}, { signal, timeoutMs: LABEL_TIMEOUT_MS })
    const found = result.processes.find(p => p.pid === pid)
    return found === undefined ? `pid ${String(pid)}` : `pid ${String(pid)} ${found.bundleId ?? found.name}`
  } catch (error) {
    // The label is decoration on the prompt; a failed lookup must not block the
    // user from deciding about the operation itself.
    void error
    return `pid ${String(pid)}`
  }
}

/**
 * Cut source down to the lines a prompt can show.
 * @param source - generated source.
 * @param maxLines - how many lines to keep.
 * @returns the first `maxLines` lines, with a marker when the rest is elided.
 */
function elide(source: string, maxLines: number): string {
  const lines = source.split('\n')
  if (lines.length <= maxLines) return source
  return `${lines.slice(0, maxLines).join('\n')}\n... ${lines.length - maxLines} more lines`
}

/**
 * Indent a block so it reads as one quoted part of the prompt.
 * @param text - the block.
 * @returns the block, indented by two spaces.
 */
function indent(text: string): string {
  return text.split('\n').map(line => `  ${line}`).join('\n')
}