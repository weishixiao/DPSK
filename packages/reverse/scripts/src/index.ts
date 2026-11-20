/**
 * Saved reverse-engineering scripts as model-facing tools: write one down, list
 * what is there, read it back, drop it.
 *
 * The store is a plain directory of files, not a database, because what it holds
 * is source a person will also want to open in an editor and hand to Theos.
 * @module @deepseek-ai/dsh-reverse-scripts
 */

import type { Context } from '@deepseek-ai/cordis'
import z from '@deepseek-ai/schemastery'
import { defineTool } from '@deepseek-ai/dsh-tools'
import type { ScriptKind } from './store.ts'
import {
  deleteScript,
  listScripts,
  readScript,
  saveScript,
  scriptPath,
  scriptsDirectory,
  validateScriptName,
} from './store.ts'

export const name = 'reverse-scripts'
export const inject = ['tools']

/** Configuration of the script store. */
export interface Config {
  /**
   * Register this package's tools at all. Defaults to true; a profile that would
   * rather the model not keep notes sets it false.
   */
  enabled?: boolean
  /** Register the save tool. Defaults to true. */
  save?: boolean
  /** Register the list tool. Defaults to true. */
  list?: boolean
  /** Register the read tool. Defaults to true. */
  read?: boolean
  /** Register the delete tool. Defaults to true. */
  delete?: boolean
  /**
   * Directory holding the scripts. Defaults to `<dsh home>/reverse/scripts`.
   * Set it to a path Theos or an editor can reach, such as a project's own
   * `scripts/` folder.
   */
  directory?: string
}

/** Schema for {@link Config}. */
export const Config: z<Config> = z.object({
  enabled: z.boolean().default(true),
  save: z.boolean().default(true),
  list: z.boolean().default(true),
  read: z.boolean().default(true),
  delete: z.boolean().default(true),
  directory: z.string().default(''),
})

/** Configuration after schemastery applied the defaults. */
type ResolvedConfig = Required<Config>

/** Kinds a script can have, as the tools accept them. */
const KINDS: ScriptKind[] = ['tweak', 'memory', 'note']

/**
 * Register the script tools.
 * @param ctx - registrant context with the tool registry.
 * @param config - which tools to register and where the store lives.
 */
export function apply(ctx: Context, config: Config): void {
  const resolved = config as ResolvedConfig
  if (resolved.enabled === false) return
  const directory = scriptsDirectory(resolved.directory)

  if (resolved.save) {
    ctx.tools.register(defineTool({
      name: 'reverse_script_save',
      description:
        'Save a generated hook source or memory script so a later turn can find it again. Saving replaces '
        + 'the previous version of the same name, which is how an edited script is written back. Use a '
        + 'name that says what it does, e.g. "vip-check-bypass" or "coins-scan".',
      parameters: {
        name: {
          type: 'string',
          required: true,
          description: 'File name without extension: letters, digits, dot, dash, underscore, at most 64.',
        },
        kind: {
          type: 'string',
          required: true,
          enum: KINDS,
          description: 'tweak for Substrate/Logos source (.xm), memory for a script of memory operations (.json), note for anything else (.md).',
        },
        source: {
          type: 'string',
          required: true,
          description: 'The complete file content.',
        },
      },
      output: {
        schema: {
          type: 'object',
          additionalProperties: false,
          properties: {
            path: { type: 'string', required: true },
            size: { type: 'integer', required: true },
            updatedAt: { type: 'string', required: true },
            replaced: { type: 'boolean', required: true },
          },
        },
        render: (args, value) => [{
          type: 'text',
          text: `${value.replaced ? 'Replaced' : 'Saved'} ${args.kind} script ${args.name} `
            + `(${String(value.size)} bytes) at ${value.path}`,
        }],
      },
      async execute(args) {
        const scriptName = validateScriptName(args.name)
        const existing = await readScript(directory, args.kind, scriptName)
        const entry = await saveScript(directory, args.kind, scriptName, args.source)
        return {
          path: scriptPath(directory, args.kind, scriptName),
          size: entry.size,
          updatedAt: entry.updatedAt,
          replaced: existing !== undefined,
        }
      },
      presentCall: args => ({
        card: 'generic',
        title: `Save script ${args.name}`,
        kind: 'other',
        rawInput: args,
      }),
    }))
  }

  if (resolved.list) {
    ctx.tools.register(defineTool({
      name: 'reverse_script_list',
      description:
        'List the scripts saved so far, newest first: hooks, memory scripts and notes. Read one with '
        + 'reverse_script_read before reusing or editing it.',
      parameters: {
        kind: {
          type: 'string',
          enum: KINDS,
          description: 'Only this kind.',
        },
      },
      output: {
        schema: {
          type: 'object',
          additionalProperties: false,
          properties: {
            directory: { type: 'string', required: true },
            scripts: {
              type: 'array',
              required: true,
              items: {
                type: 'object',
                additionalProperties: false,
                properties: {
                  name: { type: 'string', required: true },
                  kind: { type: 'string', required: true, enum: KINDS },
                  size: { type: 'integer', required: true },
                  updatedAt: { type: 'string', required: true },
                },
              },
            },
          },
        },
        render: (_args, value) => {
          if (value.scripts.length === 0) {
            return [{ type: 'text', text: `No scripts saved yet in ${value.directory}.` }]
          }
          const rows = value.scripts.map(s => `${s.updatedAt.slice(0, 19)}  ${s.kind.padEnd(6)}  ${String(s.size).padStart(7)}  ${s.name}`)
          return [{ type: 'text', text: `${value.scripts.length} scripts in ${value.directory}:\n${rows.join('\n')}` }]
        },
      },
      async execute(args) {
        const scripts = await listScripts(directory, args.kind)
        return { directory, scripts }
      },
      presentCall: args => ({
        card: 'generic',
        title: args.kind === undefined ? 'List saved scripts' : `List saved ${args.kind} scripts`,
        kind: 'search',
        rawInput: args,
      }),
    }))
  }

  if (resolved.read) {
    ctx.tools.register(defineTool({
      name: 'reverse_script_read',
      description:
        'Read one saved script back. Use it to continue work from an earlier session, or to edit a hook '
        + 'instead of generating it again.',
      parameters: {
        name: { type: 'string', required: true, description: 'Script name without extension.' },
        kind: { type: 'string', required: true, enum: KINDS, description: 'The kind it was saved as.' },
      },
      output: {
        schema: {
          type: 'object',
          additionalProperties: false,
          properties: {
            name: { type: 'string', required: true },
            kind: { type: 'string', required: true, enum: KINDS },
            content: { type: 'string', required: true },
            truncated: { type: 'boolean', required: true },
            updatedAt: { type: 'string', required: true },
          },
        },
        render: (args, value) => [{
          type: 'text',
          text: `${args.name} (${args.kind}), last written ${value.updatedAt}:\n${value.content}`
            + `${value.truncated ? '\n... truncated; read it with a smaller file or open it on disk' : ''}`,
        }],
      },
      async execute(args) {
        const scriptName = validateScriptName(args.name)
        const record = await readScript(directory, args.kind, scriptName)
        if (record === undefined) {
          throw new Error(`no ${args.kind} script named "${scriptName}" in ${directory}`)
        }
        return {
          name: record.name,
          kind: record.kind,
          content: record.content,
          truncated: record.truncated,
          updatedAt: record.updatedAt,
        }
      },
      presentCall: args => ({
        card: 'generic',
        title: `Read script ${args.name}`,
        kind: 'read',
        rawInput: args,
      }),
    }))
  }

  if (resolved.delete) {
    ctx.tools.register(defineTool({
      name: 'reverse_script_delete',
      description: 'Delete one saved script. This removes the file from disk and cannot be undone.',
      parameters: {
        name: { type: 'string', required: true, description: 'Script name without extension.' },
        kind: { type: 'string', required: true, enum: KINDS, description: 'The kind it was saved as.' },
      },
      output: {
        schema: {
          type: 'object',
          additionalProperties: false,
          properties: { removed: { type: 'boolean', required: true } },
        },
        render: (args, value) => [{
          type: 'text',
          text: value.removed ? `Deleted ${args.kind} script ${args.name}.` : `No ${args.kind} script named ${args.name}.`,
        }],
      },
      async execute(args) {
        const scriptName = validateScriptName(args.name)
        return { removed: await deleteScript(directory, args.kind, scriptName) }
      },
      presentCall: args => ({
        card: 'generic',
        title: `Delete script ${args.name}`,
        kind: 'other',
        rawInput: args,
      }),
    }))
  }
}
