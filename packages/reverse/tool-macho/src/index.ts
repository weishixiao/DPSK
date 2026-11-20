/**
 * Static Mach-O inspection over `ctx.reverse`: read the binary on disk without
 * loading it, so a target can be understood before anything is attached to it.
 * @module @deepseek-ai/dsh-tool-reverse-macho
 */

import type { Context } from '@deepseek-ai/cordis'
import z from '@deepseek-ai/schemastery'
import { defineTool } from '@deepseek-ai/dsh-tools'
import type { ReverseBridge } from '@deepseek-ai/dsh-reverse-bridge'
import { DEFAULT_STRING_LIMIT, normalizeArguments } from '@deepseek-ai/dsh-reverse-bridge'

export const name = 'tool-reverse-macho'
export const inject = ['tools', 'reverse']

/** Configuration of this tool package. */
export interface Config {
  /**
   * Register this package's tools. Defaults to true. A profile that does not want
   * the capability at all sets it false, and the model never sees the tool.
   */
  enabled?: boolean
}

/** Schema for {@link Config}. */
export const Config: z<Config> = z.object({
  enabled: z.boolean().default(true),
})

/** How many rows of each list a rendered summary shows. */
const RENDER_ROWS = 30

/**
 * Register the Mach-O analysis tool.
 * @param ctx - registrant context with the tool registry and the reverse bridge.
 * @param config - whether this package registers its tools at all.
 */
export function apply(ctx: Context, config: Config): void {
  if ((config as Required<Config>).enabled === false) return
  const reverse: ReverseBridge = ctx.reverse

  ctx.tools.register(defineTool({
    name: 'reverse_macho_analyze',
    description:
      'Analyse a Mach-O binary on the device by path: arch, platform, encryption, linked libraries, '
      + 'sections, Objective-C classes and methods, symbol count, and interesting strings (URLs, class '
      + 'names, purchase and error wording). Use it to plan an analysis without attaching to a running '
      + 'process. It reads only; it never loads or modifies the file.',
    parameters: {
      path: {
        type: 'string',
        required: true,
        description: 'Absolute path of the binary, from reverse_process_images or the app bundle, e.g. /var/containers/Bundle/Application/.../App.app/App.',
      },
      stringsLimit: {
        type: 'integer',
        description: `How many strings to return (default ${DEFAULT_STRING_LIMIT}, at most 2000).`,
      },
    },
    output: {
      schema: {
        type: 'object',
        additionalProperties: false,
        properties: {
          path: { type: 'string', required: true },
          size: { type: 'integer', required: true },
          arch: { type: 'string', required: true },
          platform: { type: 'string', required: true },
          executable: { type: 'boolean', required: true },
          encrypted: { type: 'boolean', required: true },
          flags: { type: 'integer', required: true },
          dependencies: {
            type: 'array',
            required: true,
            items: {
              type: 'object',
              additionalProperties: false,
              properties: {
                name: { type: 'string', required: true },
                weak: { type: 'boolean', required: true },
              },
            },
          },
          sections: {
            type: 'array',
            required: true,
            items: {
              type: 'object',
              additionalProperties: false,
              properties: {
                segment: { type: 'string', required: true },
                name: { type: 'string', required: true },
                address: { type: 'string', required: true },
                size: { type: 'integer', required: true },
              },
            },
          },
          objcClasses: { type: 'array', required: true, items: { type: 'string' } },
          objcMethods: { type: 'array', required: true, items: { type: 'string' } },
          symbolCount: { type: 'integer', required: true },
          strings: { type: 'array', required: true, items: { type: 'string' } },
        },
      },
      render: (_args, value) => {
        const lines = [
          value.path,
          `${value.size} bytes, ${value.arch}, ${value.platform}`
            + `${value.executable ? ', executable' : ''}${value.encrypted ? ', ENCRYPTED (decrypt before static analysis)' : ''}`,
          `dependencies (${value.dependencies.length}): ${list(value.dependencies.map(d => `${d.name}${d.weak ? ' (weak)' : ''}`))}`,
          `sections (${value.sections.length}): ${list(value.sections.map(s => `${s.segment},${s.name}@${s.address}+${s.size}`))}`,
          `objc classes (${value.objcClasses.length}): ${list(value.objcClasses)}`,
          `objc methods (${value.objcMethods.length}): ${list(value.objcMethods)}`,
          `symbols: ${value.symbolCount}`,
        ]
        if (value.strings.length > 0) {
          lines.push(`strings (${value.strings.length}):`)
          lines.push(...value.strings.slice(0, RENDER_ROWS).map(s => `  ${s}`))
          if (value.strings.length > RENDER_ROWS) lines.push(`  ... ${value.strings.length - RENDER_ROWS} more`)
        }
        return [{ type: 'text', text: lines.join('\n') }]
      },
    },
    async execute(args, exec) {
      const result = await reverse.call(
        'macho.analyze',
        normalizeArguments('macho.analyze', {
          path: args.path,
          ...args.stringsLimit === undefined ? {} : { stringsLimit: args.stringsLimit },
        }),
        { signal: exec.signal },
      )
      return {
        path: result.path,
        size: result.size,
        arch: result.arch,
        platform: result.platform,
        executable: result.executable,
        encrypted: result.encrypted,
        flags: result.flags,
        dependencies: result.dependencies.map(d => ({ name: d.name, weak: d.weak })),
        sections: result.sections.map(s => ({
          segment: s.segment,
          name: s.name,
          address: s.address,
          size: s.size,
        })),
        objcClasses: [...result.objcClasses],
        objcMethods: [...result.objcMethods],
        symbolCount: result.symbolCount,
        strings: [...result.strings],
      }
    },
    presentCall: args => ({
      card: 'generic',
      title: 'Analyse Mach-O',
      kind: 'search',
      rawInput: args,
    }),
  }))
}

/**
 * Join list items for a one-line summary, keeping the line short.
 * @param items - rendered items.
 * @returns the joined text.
 */
function list(items: readonly string[]): string {
  if (items.length === 0) return '(none)'
  const head = items.slice(0, RENDER_ROWS).join(', ')
  return items.length > RENDER_ROWS ? `${head}, ... ${items.length - RENDER_ROWS} more` : head
}