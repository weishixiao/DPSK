/**
 * Memory over `ctx.reverse`: two read-only operations and the one write that
 * changes the target.
 *
 * The write is the sharpest edge in the harness, so it is the only one that goes
 * through `mutate()`, and its approval text names the process, the address, the
 * type and both values — nothing the user has to look up elsewhere.
 * @module @deepseek-ai/dsh-tool-reverse-memory
 */

import type { Context } from '@deepseek-ai/cordis'
import z from '@deepseek-ai/schemastery'
import { defineTool, ToolContextUnavailableError } from '@deepseek-ai/dsh-tools'
import type { ReverseBridge } from '@deepseek-ai/dsh-reverse-bridge'
import { normalizeArguments } from '@deepseek-ai/dsh-reverse-bridge'

export const name = 'tool-reverse-memory'
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

/** Value types the resident can read, scan and write; must match the protocol's table. */
const VALUE_TYPES = ['u8', 'i8', 'u16', 'i16', 'u32', 'i32', 'u64', 'i64', 'float', 'double'] as const

/** Deadline of the process label lookup in an approval summary. */
const LABEL_TIMEOUT_MS = 1_500

/**
 * Register the memory tools.
 * @param ctx - registrant context with the tool registry and the reverse bridge.
 * @param config - whether this package registers its tools at all.
 */
export function apply(ctx: Context, config: Config): void {
  if ((config as Required<Config>).enabled === false) return
  const reverse: ReverseBridge = ctx.reverse

  ctx.tools.register(defineTool({
    name: 'reverse_memory_read',
    description:
      'Read bytes from a running process at an address obtained from reverse_symbols, reverse_memory_scan '
      + 'or a loaded image base. Returns hex and printable ASCII, so a value or a table entry can be '
      + 'inspected before anything is written. Read-only.',
    parameters: {
      pid: { type: 'integer', required: true, description: 'Process id.' },
      address: { type: 'string', required: true, description: 'Runtime address, e.g. 0x102a4c000 or 102a4c000.' },
      length: { type: 'integer', required: true, description: 'Bytes to read, 1 to 65536.' },
    },
    output: {
      schema: {
        type: 'object',
        additionalProperties: false,
        properties: {
          address: { type: 'string', required: true },
          length: { type: 'integer', required: true },
          hex: { type: 'string', required: true },
          ascii: { type: 'string', required: true },
        },
      },
      render: (_args, value) => [{
        type: 'text',
        text: `${value.address}, ${value.length} bytes\n${formatDump(value.hex, value.ascii)}`,
      }],
    },
    async execute(args, exec) {
      const result = await reverse.call(
        'memory.read',
        normalizeArguments('memory.read', { pid: args.pid, address: args.address, length: args.length }),
        { signal: exec.signal },
      )
      return { address: result.address, length: result.length, hex: result.hex, ascii: result.ascii }
    },
    presentCall: args => ({
      card: 'generic',
      title: `Read ${String(args.length)} bytes at ${args.address}`,
      kind: 'read',
      rawInput: args,
    }),
  }))

  ctx.tools.register(defineTool({
    name: 'reverse_memory_scan',
    description:
      'Search a running process\'s memory for a value of the given type, returning matching addresses. '
      + 'Narrow the window with range when the target is large: an unscoped scan of a big app reads '
      + 'hundreds of megabytes. Typical use is a gold, VIP flag, or level counter read from the UI. '
      + 'Read-only.',
    parameters: {
      pid: { type: 'integer', required: true, description: 'Process id.' },
      type: { type: 'string', required: true, enum: [...VALUE_TYPES], description: 'Width and signedness of the value.' },
      value: { type: 'string', required: true, description: 'Value to find, in the type\'s natural notation: "1200", "-1", "0xff", "3.5"; a boolean field is scanned as u8 0 or 1.' },
      limit: { type: 'integer', description: 'Maximum matches to return (default 500, at most 5000).' },
      range: {
        type: 'object',
        additionalProperties: false,
        description: 'Optional address window; defaults to the main image\'s writable segments.',
        properties: {
          from: { type: 'string', required: true, description: 'Inclusive start address.' },
          to: { type: 'string', required: true, description: 'Exclusive end address, above from.' },
        },
      },
    },
    output: {
      schema: {
        type: 'object',
        additionalProperties: false,
        properties: {
          matches: {
            type: 'array',
            required: true,
            items: {
              type: 'object',
              additionalProperties: false,
              properties: {
                address: { type: 'string', required: true },
                value: { type: 'string', required: true },
              },
            },
          },
          scannedBytes: { type: 'integer', required: true },
          truncated: { type: 'boolean', required: true },
        },
      },
      render: (_args, value) => {
        const head = value.matches.length === 0
          ? 'No match.'
          : `${value.matches.length} matches:\n${value.matches.map(m => `${m.address}  ${m.value}`).join('\n')}`
        const tail = value.truncated ? '\n... stopped at the match cap' : ''
        return [{ type: 'text', text: `${head}\n(scanned ${value.scannedBytes} bytes)${tail}` }]
      },
    },
    async execute(args, exec) {
      const result = await reverse.call(
        'memory.scan',
        normalizeArguments('memory.scan', {
          pid: args.pid,
          type: args.type,
          value: args.value,
          ...args.limit === undefined ? {} : { limit: args.limit },
          ...args.range === undefined ? {} : { range: args.range },
        }),
        { signal: exec.signal },
      )
      return {
        matches: result.matches.map(m => ({ address: m.address, value: m.value })),
        scannedBytes: result.scannedBytes,
        truncated: result.truncated,
      }
    },
    presentCall: args => ({
      card: 'generic',
      title: `Scan pid ${String(args.pid)} for ${args.value}`,
      kind: 'search',
      rawInput: args,
    }),
  }))

  ctx.tools.register(defineTool({
    name: 'reverse_memory_write',
    description:
      'Write one value at an address in a running process. This changes the target, so it always stops '
      + 'for the user\'s decision, and nothing is sent unless they confirm. Confirm first that the address '
      + 'holds what you think: read it with reverse_memory_read in the same step. If the process restarts '
      + 'or the memory is remapped the value is lost — a hook is the durable way to change behaviour.',
    parameters: {
      pid: { type: 'integer', required: true, description: 'Process id.' },
      address: { type: 'string', required: true, description: 'Runtime address to overwrite, from reverse_symbols or reverse_memory_scan.' },
      type: { type: 'string', required: true, enum: [...VALUE_TYPES], description: 'Width and signedness written at the address.' },
      value: { type: 'string', required: true, description: 'New value, in the type\'s natural notation: "99999", "1", "0x10"; a boolean field takes 0 or 1 as u8.' },
    },
    output: {
      schema: {
        type: 'object',
        additionalProperties: false,
        properties: {
          address: { type: 'string', required: true },
          previous: { type: 'string', required: true },
          written: { type: 'string', required: true },
        },
      },
      render: (_args, value) => [{
        type: 'text',
        text: `Wrote ${value.written} at ${value.address} (was ${value.previous}).`,
      }],
    },
    async execute(args, exec) {
      if (exec.agent === undefined) {
        throw new ToolContextUnavailableError('reverse_memory_write needs an agent turn to ask for approval')
      }
      const typed = normalizeArguments('memory.write', {
        pid: args.pid,
        address: args.address,
        type: args.type,
        value: args.value,
      })
      const label = await targetLabel(reverse, typed.pid, exec.signal)
      const result = await reverse.mutate('memory.write', typed, {
        agent: exec.agent,
        toolName: 'reverse_memory_write',
        callId: exec.rootCallId,
        signal: exec.signal,
        summary: [
          `Memory write in ${label}`,
          `address ${typed.address}, type ${typed.type}`,
          `new value ${typed.value}`,
        ].join('\n'),
      })
      return {
        address: result.address,
        previous: result.previous,
        written: result.written,
      }
    },
    presentCall: args => ({
      card: 'generic',
      title: `Write ${args.value} at ${args.address}`,
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
    // user from deciding about the write itself.
    void error
    return `pid ${String(pid)}`
  }
}

/**
 * Render a hex/ascii pair as an offset table.
 * @param hex - space-separated hex bytes.
 * @param ascii - printable rendering of the same bytes.
 * @returns at most eight rows of sixteen bytes.
 */
function formatDump(hex: string, ascii: string): string {
  const bytes = hex.length === 0 ? [] : hex.split(' ')
  const rows: string[] = []
  for (let offset = 0; offset < bytes.length && rows.length < 8; offset += 16) {
    const slice = bytes.slice(offset, offset + 16)
    const text = ascii.slice(offset, offset + 16)
    rows.push(`${offset.toString(16).padStart(6, '0')}  ${slice.join(' ').padEnd(47)}  ${text}`)
  }
  if (bytes.length > 8 * 16) rows.push(`... ${bytes.length - 8 * 16} more bytes`)
  return rows.join('\n')
}