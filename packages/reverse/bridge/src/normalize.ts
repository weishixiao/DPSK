/**
 * Canonicalization of model-supplied arguments into the protocol's shapes.
 *
 * The model writes a pid as `"1234"` and an address without `0x`; this module
 * accepts those forms — and only those — and returns exactly what the frame
 * carries. Everything else is rejected here, before an approval prompt and before
 * the resident, so an implausible argument never becomes a question a person has
 * to answer.
 *
 * Canonicalizing in the bridge (not only in the tools) is deliberate: any consumer
 * of `ctx.reverse` gets the same checks.
 * @module @deepseek-ai/dsh-reverse-bridge/normalize
 */

import {
  ReverseArgsError,
  validateAddress,
  validateBundleId,
  validateDevicePath,
  validateImageSelector,
  validateLength,
  validateLimit,
  validateOptionalText,
  validatePid,
  validateScanWindow,
  validateSource,
  validateValue,
  validateValueType,
} from '@deepseek-ai/dsh-reverse-protocol'
import type { ReverseArg, ReverseOp } from '@deepseek-ai/dsh-reverse-protocol'

/** Default cap on symbols returned by one lookup. */
export const DEFAULT_SYMBOL_LIMIT = 200

/** Default cap on strings returned by one Mach-O analysis. */
export const DEFAULT_STRING_LIMIT = 200

/** Lowest and highest value of each integer width, as the resident parses them. */
const SCAN_LIMIT = 500

/**
 * Accept a decimal pid written as text.
 * @param raw - caller value.
 * @returns the value to hand to {@link validatePid}.
 */
function coercePid(raw: unknown): unknown {
  if (typeof raw !== 'string') return raw
  const text = raw.trim()
  return /^\d{1,6}$/.test(text) ? Number(text) : raw
}

/**
 * Read one field off an untyped argument object.
 * @param raw - the caller's object.
 * @param key - field name.
 * @returns the field, or `undefined`.
 */
function field(raw: Record<string, unknown>, key: string): unknown {
  return raw[key]
}

/**
 * Narrow an untyped argument object, refusing arrays and primitives.
 * @param raw - caller-supplied arguments.
 * @returns the same object, typed as a record.
 */
function objectOf(raw: unknown): Record<string, unknown> {
  if (typeof raw !== 'object' || raw === null || Array.isArray(raw)) return {}
  return raw as Record<string, unknown>
}

/** Reverse-DNS prefixes that mark a process filter as a bundle identifier rather than a name fragment. */
const BUNDLE_ID_PREFIXES = ['com.', 'org.', 'net.', 'cn.', 'io.', 'me.', 'dev.', 'co.'] as const

/**
 * Accept a process filter that is either a name fragment or a bundle identifier.
 *
 * The resident matches both, so a fragment is passed through untouched. A filter
 * that announces itself as reverse-DNS is validated instead: a malformed bundle id
 * would otherwise match no process at all and read as "the app is not running".
 * @param raw - caller value.
 * @returns the filter to send, or `undefined` when there is none.
 */
function validateProcessFilter(raw: unknown): string | undefined {
  const text = validateOptionalText(raw, 'filter', 256)
  if (text === undefined) return undefined
  const trimmed = text.trim()
  const lowered = trimmed.toLowerCase()
  const declaredBundleId = BUNDLE_ID_PREFIXES.some(prefix => lowered.startsWith(prefix))
  if (!declaredBundleId) return trimmed
  return validateBundleId(trimmed)
}

/**
 * Canonicalize one operation's arguments.
 * @param op - the operation the arguments belong to.
 * @param raw - untyped arguments, typically straight from a tool call.
 * @returns the canonical arguments, ready to frame.
 * @throws ReverseArgsError naming the first unusable field.
 */
export function normalizeArguments<K extends ReverseOp>(op: K, raw: unknown): ReverseArg<K> {
  const args = objectOf(raw)
  switch (op) {
    case 'system.hello':
      return {} as ReverseArg<K>
    case 'process.list': {
      const filter = validateProcessFilter(field(args, 'filter'))
      return { ...filter === undefined ? {} : { filter } } as ReverseArg<K>
    }
    case 'process.images':
      return { pid: validatePid(coercePid(field(args, 'pid'))) } as ReverseArg<K>
    case 'process.symbols': {
      const pid = validatePid(coercePid(field(args, 'pid')))
      const image = field(args, 'image') === undefined ? undefined : validateImageSelector(field(args, 'image'))
      const filter = validateOptionalText(field(args, 'filter'), 'filter', 256)
      const limit = validateLimit(field(args, 'limit'), DEFAULT_SYMBOL_LIMIT, 2000)
      return {
        pid,
        ...image === undefined ? {} : { image },
        ...filter === undefined ? {} : { filter },
        limit,
      } as ReverseArg<K>
    }
    case 'macho.analyze': {
      const path = validateDevicePath(field(args, 'path'))
      const stringsLimit = validateLimit(field(args, 'stringsLimit'), DEFAULT_STRING_LIMIT, 2000, 'stringsLimit')
      return { path, stringsLimit } as ReverseArg<K>
    }
    case 'memory.read': {
      const pid = validatePid(coercePid(field(args, 'pid')))
      const address = validateAddress(field(args, 'address'))
      const length = validateLength(field(args, 'length'))
      return { pid, address, length } as ReverseArg<K>
    }
    case 'memory.scan': {
      const pid = validatePid(coercePid(field(args, 'pid')))
      const type = validateValueType(field(args, 'type'))
      const value = validateValue(type, field(args, 'value'))
      const limit = validateLimit(field(args, 'limit'), SCAN_LIMIT, 5000)
      const rangeRaw = field(args, 'range')
      if (rangeRaw === undefined) return { pid, type, value, limit } as ReverseArg<K>
      const range = objectOf(rangeRaw)
      const from = validateAddress(field(range, 'from'), 'range.from')
      const to = validateAddress(field(range, 'to'), 'range.to')
      validateScanWindow(from, to)
      return { pid, type, value, limit, range: { from, to } } as ReverseArg<K>
    }
    case 'memory.write': {
      const pid = validatePid(coercePid(field(args, 'pid')))
      const address = validateAddress(field(args, 'address'))
      const type = validateValueType(field(args, 'type'))
      const value = validateValue(type, field(args, 'value'))
      return { pid, address, type, value } as ReverseArg<K>
    }
    case 'hook.install': {
      const pid = validatePid(coercePid(field(args, 'pid')))
      const image = validateImageSelector(field(args, 'image'))
      const symbol = validateImageSelector(field(args, 'symbol'))
      const mode = field(args, 'mode')
      if (mode !== 'replace' && mode !== 'log-only') {
        throw new ReverseArgsError('mode', 'must be "replace" or "log-only"')
      }
      const source = validateSource(field(args, 'source'))
      return { pid, image, symbol, mode, source } as ReverseArg<K>
    }
    case 'inject.dylib': {
      const pid = validatePid(coercePid(field(args, 'pid')))
      const dylibPath = validateDevicePath(field(args, 'dylibPath'), 'dylibPath')
      return { pid, dylibPath } as ReverseArg<K>
    }
    default: {
      const exhaustive: never = op
      throw new TypeError(`unknown reverse operation: ${String(exhaustive)}`)
    }
  }
}
