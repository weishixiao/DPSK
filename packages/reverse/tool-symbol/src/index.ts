/**
 * Symbol lookup in a live process over `ctx.reverse`: the addresses a hook or a
 * memory read needs, resolved the way the resident sees them.
 * @module @deepseek-ai/dsh-tool-reverse-symbol
 */

import type { Context } from '@deepseek-ai/cordis'
import { defineTool } from '@deepseek-ai/dsh-tools'
import type { ReverseBridge } from '@deepseek-ai/dsh-reverse-bridge'
import { DEFAULT_SYMBOL_LIMIT, normalizeArguments } from '@deepseek-ai/dsh-reverse-bridge'

export const name = 'tool-reverse-symbol'
export const inject = ['tools', 'reverse']

/** How many symbols a rendered list shows. */
const RENDER_SYMBOLS = 60

/**
 * Register the symbol lookup tool.
 * @param ctx - registrant context with the tool registry and the reverse bridge.
 */
export function apply(ctx: Context): void {
  const reverse: ReverseBridge = ctx.reverse

  ctx.tools.register(defineTool({
    name: 'reverse_symbols',
    description:
      'Look up runtime symbols (functions, ObjC classes and methods, data) in a running process, '
      + 'optionally limited to one image and filtered by name. Each result carries its runtime address, '
      + 'which is what reverse_memory_read and reverse_hook_install take. Always pass a filter: an '
      + 'unfiltered lookup of a large target returns only the first page.',
    parameters: {
      pid: {
        type: 'integer',
        required: true,
        description: 'Process id from reverse_process_list.',
      },
      image: {
        type: 'string',
        description: 'Only this image: a full path, a path suffix, or a bare name such as "UIKit".',
      },
      filter: {
        type: 'string',
        description: 'Case-insensitive fragment of the symbol name, e.g. "isVip", "purchase", "TTAccount".',
      },
      limit: {
        type: 'integer',
        description: `Maximum symbols to return (default ${DEFAULT_SYMBOL_LIMIT}, at most 2000).`,
      },
    },
    output: {
      schema: {
        type: 'object',
        additionalProperties: false,
        properties: {
          symbols: {
            type: 'array',
            required: true,
            items: {
              type: 'object',
              additionalProperties: false,
              properties: {
                name: { type: 'string', required: true },
                address: { type: 'string', required: true },
                kind: { type: 'string', required: true, enum: ['function', 'data', 'objc-class', 'objc-method'] },
              },
            },
          },
          truncated: { type: 'boolean', required: true },
        },
      },
      render: (args, value) => {
        if (value.symbols.length === 0) {
          return [{
            type: 'text',
            text: args.filter === undefined
              ? `No symbols found in pid ${String(args.pid)}.`
              : `No symbol in pid ${String(args.pid)} matched "${args.filter}".`,
          }]
        }
        const rows = value.symbols.slice(0, RENDER_SYMBOLS).map(s => `${s.address}  ${s.kind.padEnd(11)}  ${s.name}`)
        const tail = value.truncated ? '\n... more symbols match; narrow the filter or raise limit' : ''
        return [{ type: 'text', text: `${value.symbols.length} symbols in pid ${String(args.pid)}:\n${rows.join('\n')}${tail}` }]
      },
    },
    async execute(args, exec) {
      const result = await reverse.call(
        'process.symbols',
        normalizeArguments('process.symbols', {
          pid: args.pid,
          ...args.image === undefined ? {} : { image: args.image },
          ...args.filter === undefined ? {} : { filter: args.filter },
          ...args.limit === undefined ? {} : { limit: args.limit },
        }),
        { signal: exec.signal },
      )
      return {
        symbols: result.symbols.map(s => ({ name: s.name, address: s.address, kind: s.kind })),
        truncated: result.truncated,
      }
    },
    presentCall: args => ({
      card: 'generic',
      title: args.filter === undefined ? 'Look up symbols' : `Look up symbols matching ${args.filter}`,
      kind: 'search',
      rawInput: args,
    }),
  }))
}