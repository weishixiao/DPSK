/**
 * Where generated reverse-engineering source lives.
 *
 * A hook that took a turn to write is worth more than the turn: the next session
 * should be able to list what was produced, read it back, and edit it instead of
 * asking the model to reconstruct it from memory. This module is the whole store —
 * one flat directory, one file per script, an atomic replace — and the tools in
 * this package are a thin model-facing layer over it.
 * @module @deepseek-ai/dsh-reverse-scripts/store
 */

import { mkdir, readdir, readFile, rename, stat, unlink, writeFile } from 'node:fs/promises'
import { join } from 'node:path'
import { dshHomePath } from '@deepseek-ai/dsh-home-paths'
import { HarnessError } from '@deepseek-ai/dsh-error'

/** What a saved file is for, which also fixes its extension. */
export type ScriptKind = 'tweak' | 'memory' | 'note'

/** Extension of each kind. */
const EXTENSIONS: Record<ScriptKind, string> = {
  tweak: 'xm',
  memory: 'json',
  note: 'md',
}

/** The extension a kind is stored under. */
export const SCRIPT_EXTENSIONS = EXTENSIONS

/** Largest source this store accepts; a hook is not a repository. */
export const MAX_SCRIPT_BYTES = 512 * 1024

/** Longest content `read` returns, so a large file cannot flood a turn. */
export const MAX_READ_CHARS = 64 * 1024

/** A name the store accepts: one path component, no traversal. */
const NAME_PATTERN = /^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$/

/**
 * Reject a name the store cannot use as one file name.
 * @param name - the caller's name.
 * @returns the name, unchanged.
 * @throws HarnessError `REVERSE_SCRIPT_NAME` when it is not one path component.
 */
export function validateScriptName(name: string): string {
  if (!NAME_PATTERN.test(name) || name.includes('..')) {
    throw new HarnessError(
      `"${name}" is not a script name: use 1-64 letters, digits, dot, dash or underscore, and no path separator`,
      'REVERSE_SCRIPT_NAME',
    )
  }
  return name
}

/** One script as the list reports it. */
export interface ScriptEntry {
  /** Name without extension. */
  name: string
  /** The kind its extension implies. */
  kind: ScriptKind
  /** Bytes on disk. */
  size: number
  /** Last modification, ISO 8601. */
  updatedAt: string
}

/** One script with its content. */
export interface ScriptRecord extends ScriptEntry {
  /** File content; truncated when it exceeds {@link MAX_READ_CHARS}. */
  content: string
  /** Whether {@link content} was cut. */
  truncated: boolean
}

/**
 * The directory every script lives in.
 * @param override - a configured directory, or the default under the DSH home.
 * @returns an absolute directory path.
 */
export function scriptsDirectory(override?: string): string {
  return override === undefined || override.length === 0
    ? dshHomePath('reverse', 'scripts')
    : override
}

/**
 * Path of one script.
 * @param directory - the store directory.
 * @param kind - the script's kind, which picks the extension.
 * @param name - a validated name.
 * @returns the absolute file path.
 */
export function scriptPath(directory: string, kind: ScriptKind, name: string): string {
  return join(directory, `${name}.${EXTENSIONS[kind]}`)
}

/** Kind implied by a file name, or undefined for a file the store did not write. */
function kindOf(file: string): ScriptKind | undefined {
  const extension = file.slice(file.lastIndexOf('.') + 1)
  const found = (Object.keys(EXTENSIONS) as ScriptKind[]).find(kind => EXTENSIONS[kind] === extension)
  return found
}

/**
 * Write one script, replacing any previous version atomically.
 *
 * The content goes to a sibling temporary file first, so a reader never sees a
 * half-written hook and a failure leaves the previous version in place.
 * @param directory - the store directory, created when absent.
 * @param kind - the script's kind, which picks the extension.
 * @param name - a validated name.
 * @param source - the full file content.
 * @returns the entry the store now holds.
 * @throws HarnessError `REVERSE_SCRIPT_TOO_LARGE` when the source exceeds the cap.
 */
export async function saveScript(
  directory: string,
  kind: ScriptKind,
  name: string,
  source: string,
): Promise<ScriptEntry> {
  const bytes = Buffer.byteLength(source, 'utf8')
  if (bytes > MAX_SCRIPT_BYTES) {
    throw new HarnessError(
      `the script is ${String(bytes)} bytes; the store holds at most ${String(MAX_SCRIPT_BYTES)}`,
      'REVERSE_SCRIPT_TOO_LARGE',
    )
  }
  await mkdir(directory, { recursive: true, mode: 0o700 })
  const target = scriptPath(directory, kind, name)
  const staging = `${target}.${String(process.pid)}.tmp`
  await writeFile(staging, source, { encoding: 'utf8', mode: 0o600 })
  try {
    await rename(staging, target)
  } catch (error) {
    await unlink(staging).catch(() => {})
    throw error
  }
  const info = await stat(target)
  return { name, kind, size: info.size, updatedAt: info.mtime.toISOString() }
}

/**
 * Every script the store holds, newest first.
 * @param directory - the store directory; a missing one is an empty list.
 * @param kind - only this kind, when given.
 * @returns the entries, sorted by modification time descending.
 */
export async function listScripts(directory: string, kind?: ScriptKind): Promise<ScriptEntry[]> {
  let files: string[]
  try {
    files = await readdir(directory)
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code === 'ENOENT') return []
    throw error
  }
  const entries: ScriptEntry[] = []
  for (const file of files) {
    if (file.endsWith('.tmp')) continue
    const detected = kindOf(file)
    if (detected === undefined) continue
    if (kind !== undefined && detected !== kind) continue
    const info = await stat(join(directory, file)).catch(() => undefined)
    if (info === undefined || !info.isFile()) continue
    entries.push({
      name: file.slice(0, file.lastIndexOf('.')),
      kind: detected,
      size: info.size,
      updatedAt: info.mtime.toISOString(),
    })
  }
  entries.sort((left, right) => right.updatedAt.localeCompare(left.updatedAt))
  return entries
}

/**
 * Read one script back.
 * @param directory - the store directory.
 * @param kind - the script's kind.
 * @param name - its name.
 * @returns the record, or undefined when the file is absent.
 */
export async function readScript(
  directory: string,
  kind: ScriptKind,
  name: string,
): Promise<ScriptRecord | undefined> {
  const target = scriptPath(directory, kind, name)
  let text: string
  try {
    text = await readFile(target, 'utf8')
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code === 'ENOENT') return undefined
    throw error
  }
  const info = await stat(target)
  const truncated = text.length > MAX_READ_CHARS
  return {
    name,
    kind,
    size: info.size,
    updatedAt: info.mtime.toISOString(),
    content: truncated ? text.slice(0, MAX_READ_CHARS) : text,
    truncated,
  }
}

/**
 * Remove one script.
 * @param directory - the store directory.
 * @param kind - the script's kind.
 * @param name - its name.
 * @returns whether a file was removed.
 */
export async function deleteScript(directory: string, kind: ScriptKind, name: string): Promise<boolean> {
  try {
    await unlink(scriptPath(directory, kind, name))
    return true
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code === 'ENOENT') return false
    throw error
  }
}
