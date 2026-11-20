/**
 * Read-only process discovery over `ctx.reverse`: what is running on the device
 * and which images a target has loaded.
 *
 * These tools are the first step of every session, so they are cheap, capped, and
 * never ask the user anything: nothing here changes a process.
 * @module @deepseek-ai/dsh-tool-reverse-process
 */

import type { Context } from '@deepseek-ai/cordis'
import z from '@deepseek-ai/schemastery'
import { defineTool } from '@deepseek-ai/dsh-tools'
import type { ReverseBridge } from '@deepseek-ai/dsh-reverse-bridge'
import { normalizeArguments } from '@deepseek-ai/dsh-reverse-bridge'

export const name = 'tool-reverse-process'
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

/** How many images a rendered list shows before it summarizes. */
const RENDER_IMAGES = 80

/**
 * Register the process tools.
 * @param ctx - registrant context with the tool registry and the reverse bridge.
 * @param config - whether this package registers its tools at all.
 */
export function apply(ctx: Context, config: Config): void {
  if ((config as Required<Config>).enabled === false) return
  const reverse: ReverseBridge = ctx.reverse

  ctx.tools.register(defineTool({
    name: 'reverse_status',
    description:
      'Report the reverse bridge: whether the SpringBoard resident is reachable, its protocol version, '
      + 'iOS version, architecture, and which operations it serves. Call it when another reverse tool '
      + 'failed with "not-connected" or "protocol-mismatch".',
    parameters: {},
    output: {
      schema: {
        type: 'object',
        additionalProperties: false,
        properties: {
          state: { type: 'string', required: true, enum: ['disabled', 'offline', 'connecting', 'ready'] },
          socketPath: { type: 'string', required: true },
          pending: { type: 'integer', required: true },
          resident: {
            type: 'object',
            additionalProperties: false,
            properties: {
              resident: { type: 'string', required: true },
              version: { type: 'integer', required: true },
              ios: { type: 'string', required: true },
              arch: { type: 'string', required: true },
              theos: { type: 'boolean', required: true },
              ops: { type: 'array', required: true, items: { type: 'string' } },
            },
          },
          lastError: { type: 'string' },
        },
      },
      render: (_args, value) => {
        const lines = [`Bridge: ${value.state} (${value.socketPath}), ${value.pending} pending`]
        if (value.resident !== undefined) {
          lines.push(
            `Resident: ${value.resident.resident} protocol ${value.resident.version}, `
            + `iOS ${value.resident.ios} ${value.resident.arch}${value.resident.theos ? ', Theos available' : ''}`,
            `Operations: ${value.resident.ops.join(', ')}`,
          )
        }
        if (value.lastError !== undefined) lines.push(`Last error: ${value.lastError}`)
        return [{ type: 'text', text: lines.join('\n') }]
      },
    },
    async execute(_args, exec) {
      const status = await reverse.status({ signal: exec.signal })
      return {
        state: status.state,
        socketPath: status.socketPath,
        pending: status.pending,
        ...status.resident === undefined ? {} : {
          resident: {
            resident: status.resident.resident,
            version: status.resident.version,
            ios: status.resident.ios,
            arch: status.resident.arch,
            theos: status.resident.theos,
            ops: [...status.resident.ops],
          },
        },
        ...status.lastError === undefined ? {} : { lastError: status.lastError },
      }
    },
    presentCall: () => ({ card: 'generic', title: 'Reverse bridge status', kind: 'other' }),
  }))

  ctx.tools.register(defineTool({
    name: 'reverse_process_list',
    description:
      'List processes running on the device, with pid, name, executable path, bundle identifier and '
      + 'effective uid, optionally filtered by a case-insensitive fragment of the name, executable path '
      + 'or bundle identifier. Use it to turn a third-party app into the pid the other reverse tools take.',
    parameters: {
      filter: {
        type: 'string',
        description:
          'Case-insensitive fragment of the process name or executable path, or a bundle identifier such as '
          + '"com.burbn.instagram" to locate an app by what it is rather than what its binary is called.',
      },
    },
    output: {
      schema: {
        type: 'object',
        additionalProperties: false,
        properties: {
          processes: {
            type: 'array',
            required: true,
            items: {
              type: 'object',
              additionalProperties: false,
              properties: {
                pid: { type: 'integer', required: true },
                name: { type: 'string', required: true },
                path: { type: 'string', required: true },
                uid: { type: 'integer', required: true },
                bundleId: { type: 'string' },
              },
            },
          },
        },
      },
      render: (args, value) => {
        if (value.processes.length === 0) {
          return [{
            type: 'text',
            text: args.filter === undefined
              ? 'No processes reported by the resident.'
              : `No process matched "${args.filter}".`,
          }]
        }
        const rows = value.processes.map(p =>
          `${String(p.pid).padStart(6)}  ${String(p.uid).padStart(3)}  ${p.bundleId ?? '-'}  ${p.path}`,
        )
        return [{
          type: 'text',
          text: `${value.processes.length} processes (pid, uid, bundle id, path):\n${rows.join('\n')}`,
        }]
      },
    },
    async execute(args, exec) {
      const filter = args.filter?.trim()
      const result = await reverse.call(
        'process.list',
        normalizeArguments('process.list', filter === undefined || filter.length === 0 ? {} : { filter }),
        { signal: exec.signal },
      )
      return {
        processes: result.processes.map(p => ({
          pid: p.pid,
          name: p.name,
          path: p.path,
          uid: p.uid,
          ...p.bundleId === undefined ? {} : { bundleId: p.bundleId },
        })),
      }
    },
    presentCall: args => ({
      card: 'generic',
      title: args.filter === undefined ? 'List processes' : `List processes matching ${args.filter}`,
      kind: 'search',
      rawInput: args,
    }),
  }))

  ctx.tools.register(defineTool({
    name: 'reverse_process_images',
    description:
      'List the Mach-O images a process has loaded, with each image path, runtime base address, size and '
      + 'architecture. Use it to find the dylib or framework a target owns before reading symbols, '
      + 'hooking, or scanning memory.',
    parameters: {
      pid: {
        type: 'integer',
        required: true,
        description: 'Process id from reverse_process_list.',
      },
    },
    output: {
      schema: {
        type: 'object',
        additionalProperties: false,
        properties: {
          pid: { type: 'integer', required: true },
          images: {
            type: 'array',
            required: true,
            items: {
              type: 'object',
              additionalProperties: false,
              properties: {
                path: { type: 'string', required: true },
                base: { type: 'string', required: true },
                size: { type: 'integer', required: true },
                arch: { type: 'string', required: true },
                uuid: { type: 'string' },
              },
            },
          },
        },
      },
      render: (_args, value) => {
        const head = `${value.images.length} images in pid ${String(value.pid)}:`
        const rows = value.images.slice(0, RENDER_IMAGES).map(img =>
          `${img.base}  ${String(img.size).padStart(9)}  ${img.arch.padEnd(6)}  ${img.path}`,
        )
        const tail = value.images.length > RENDER_IMAGES
          ? `\n... ${value.images.length - RENDER_IMAGES} more images omitted`
          : ''
        return [{ type: 'text', text: `${head}\n${rows.join('\n')}${tail}` }]
      },
    },
    async execute(args, exec) {
      const result = await reverse.call(
        'process.images',
        normalizeArguments('process.images', { pid: args.pid }),
        { signal: exec.signal },
      )
      return {
        pid: result.pid,
        images: result.images.map(img => ({
          path: img.path,
          base: img.base,
          size: img.size,
          arch: img.arch,
          ...img.uuid === undefined ? {} : { uuid: img.uuid },
        })),
      }
    },
    presentCall: args => ({
      card: 'generic',
      title: `Images of pid ${String(args.pid)}`,
      kind: 'search',
      rawInput: args,
    }),
  }))
}