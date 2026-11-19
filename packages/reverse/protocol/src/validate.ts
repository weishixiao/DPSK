/**
 * Argument validation for every reverse operation. The model supplies pids,
 * bundle identifiers, addresses and values as free text, so each one is checked
 * before it is framed: an implausible argument fails here, with a stable message,
 * instead of reaching a resident that would touch the wrong address.
 * @module @deepseek-ai/dsh-reverse-protocol/validate
 */

import { VALUE_TYPES } from './types.ts'
import type { ValueType } from './types.ts'

/** A rejected argument, carrying the field and why it was rejected. */
export class ReverseArgsError extends Error {
  /**
   * @param field - the argument name as the caller named it.
   * @param message - why it was rejected.
   */
  constructor(readonly field: string, message: string) {
    super(`${field}: ${message}`)
    this.name = 'ReverseArgsError'
  }
}

/** Highest pid the kernel can hand out on Darwin. */
const MAX_PID = 99_999

/** Upper bound on a single memory read, one mebibyte. */
export const MAX_READ_LENGTH = 1 << 20

/** Upper bound on a scan window, eight mebibytes. */
export const MAX_SCAN_WINDOW = 8 << 20

/** Upper bound on the enclosing process image, so a caller cannot ask for the heap. */
export const MAX_ADDRESS = 0x0000_ffff_ffff_ffffn

/**
 * Validate a kernel pid.
 * @param raw - caller value.
 * @returns the pid as a number.
 * @throws ReverseArgsError when it is not a positive integer in range.
 */
export function validatePid(raw: unknown): number {
  if (typeof raw !== 'number' || !Number.isInteger(raw)) {
    throw new ReverseArgsError('pid', 'must be an integer')
  }
  if (raw < 1 || raw > MAX_PID) throw new ReverseArgsError('pid', `must be between 1 and ${MAX_PID}`)
  return raw
}

/**
 * Validate a bundle identifier.
 * @param raw - caller value.
 * @returns the identifier unchanged.
 * @throws ReverseArgsError when it cannot be a bundle identifier.
 */
export function validateBundleId(raw: unknown): string {
  if (typeof raw !== 'string') throw new ReverseArgsError('bundleId', 'must be a string')
  const value = raw.trim()
  if (!/^[A-Za-z0-9][A-Za-z0-9._-]{1,254}$/.test(value)) {
    throw new ReverseArgsError('bundleId', 'must look like com.example.app')
  }
  return value
}

/**
 * Normalize and validate a 64-bit user-space address.
 *
 * Accepts `0x1f4` and `1f4`; the plain-hex form is read as hex, never decimal, so
 * `1000` means `0x1000`. Rejects zero, the kernel half of the address space, and
 * anything wider than 64 bits.
 * @param raw - caller value.
 * @param field - the argument name to report.
 * @returns lowercase `0x`-prefixed address.
 * @throws ReverseArgsError when it is not an address the target could map.
 */
export function validateAddress(raw: unknown, field = 'address'): string {
  if (typeof raw !== 'string') throw new ReverseArgsError(field, 'must be a hexadecimal address')
  const text = raw.trim().toLowerCase()
  if (!/^(0x)?[0-9a-f]{1,16}$/.test(text)) {
    throw new ReverseArgsError(field, 'must be 1 to 16 hexadecimal digits, optionally 0x-prefixed')
  }
  const digits = text.startsWith('0x') ? text.slice(2) : text
  const value = BigInt(`0x${digits}`)
  if (value === 0n) throw new ReverseArgsError(field, 'must not be the null address')
  if (value > MAX_ADDRESS) throw new ReverseArgsError(field, 'is in the kernel address space')
  return `0x${value.toString(16)}`
}

/**
 * Validate a read length.
 * @param raw - caller value.
 * @returns the length in bytes.
 * @throws ReverseArgsError when it is not a positive integer within the read cap.
 */
export function validateLength(raw: unknown): number {
  if (typeof raw !== 'number' || !Number.isInteger(raw)) {
    throw new ReverseArgsError('length', 'must be an integer')
  }
  if (raw < 1 || raw > MAX_READ_LENGTH) {
    throw new ReverseArgsError('length', `must be between 1 and ${MAX_READ_LENGTH}`)
  }
  return raw
}

/**
 * Validate a result limit.
 * @param raw - caller value.
 * @param fallback - value used when the caller omitted it.
 * @param max - inclusive cap.
 * @param field - the argument name to report.
 * @returns the clamped limit.
 * @throws ReverseArgsError when it is not a positive integer.
 */
export function validateLimit(raw: unknown, fallback: number, max: number, field = 'limit'): number {
  if (raw === undefined) return fallback
  if (typeof raw !== 'number' || !Number.isInteger(raw) || raw < 1) {
    throw new ReverseArgsError(field, 'must be a positive integer')
  }
  return Math.min(raw, max)
}

/** Inclusive bounds of each fixed-width integer type. */
const INTEGER_RANGES: Record<Exclude<ValueType, 'float' | 'double'>, [bigint, bigint]> = {
  u8: [0n, 0xffn],
  i8: [-0x80n, 0x7fn],
  u16: [0n, 0xffffn],
  i16: [-0x8000n, 0x7fffn],
  u32: [0n, 0xffff_ffffn],
  i32: [-0x8000_0000n, 0x7fff_ffffn],
  u64: [0n, 0xffff_ffff_ffff_ffffn],
  i64: [-0x8000_0000_0000_0000n, 0x7fff_ffff_ffff_ffffn],
}

/**
 * Validate a value type name.
 * @param raw - caller value.
 * @returns the type.
 * @throws ReverseArgsError when it is not a supported width.
 */
export function validateValueType(raw: unknown): ValueType {
  if (typeof raw !== 'string' || !(VALUE_TYPES as readonly string[]).includes(raw)) {
    throw new ReverseArgsError('type', `must be one of ${VALUE_TYPES.join(', ')}`)
  }
  return raw as ValueType
}

/**
 * Validate a value against its width.
 *
 * Integers are parsed as decimal (or `0x`-prefixed hex) and range-checked, so a
 * `u8` write of `300` is refused rather than silently truncated; floats must be
 * finite. The returned text is the canonical decimal the resident parses.
 * @param type - already-validated width.
 * @param raw - caller value.
 * @returns the value rendered as text.
 * @throws ReverseArgsError when it does not fit the width.
 */
export function validateValue(type: ValueType, raw: unknown): string {
  if (type === 'float' || type === 'double') {
    const value = typeof raw === 'number' ? raw : typeof raw === 'string' ? Number(raw.trim()) : Number.NaN
    if (!Number.isFinite(value)) throw new ReverseArgsError('value', `must be a finite ${type}`)
    return String(value)
  }
  const text = typeof raw === 'number' ? String(raw) : typeof raw === 'string' ? raw.trim() : ''
  if (!/^-?(0x[0-9a-fA-F]{1,16}|\d{1,20})$/.test(text)) {
    throw new ReverseArgsError('value', 'must be a decimal or 0x-prefixed integer')
  }
  const value = text.startsWith('-')
    ? -BigInt(text.slice(1))
    : BigInt(text)
  const [min, max] = INTEGER_RANGES[type]
  if (value < min || value > max) {
    throw new ReverseArgsError('value', `does not fit ${type} (${min} to ${max})`)
  }
  return value.toString()
}

/**
 * Validate an absolute in-device path.
 * @param raw - caller value.
 * @param field - the argument name to report.
 * @returns the path unchanged.
 * @throws ReverseArgsError when it is relative, contains a traversal segment, or is too long.
 */
export function validateDevicePath(raw: unknown, field = 'path'): string {
  if (typeof raw !== 'string') throw new ReverseArgsError(field, 'must be a string')
  const value = raw.trim()
  if (!value.startsWith('/')) throw new ReverseArgsError(field, 'must be an absolute device path')
  if (value.length > 1024) throw new ReverseArgsError(field, 'must be at most 1024 characters')
  if (value.split('/').includes('..')) throw new ReverseArgsError(field, 'must not contain a .. segment')
  return value
}

/**
 * Validate an image selector: an absolute path or a bare file name.
 * @param raw - caller value.
 * @returns the selector unchanged.
 * @throws ReverseArgsError when it is empty or a traversal.
 */
export function validateImageSelector(raw: unknown): string {
  if (typeof raw !== 'string') throw new ReverseArgsError('image', 'must be a string')
  const value = raw.trim()
  if (value.length === 0) throw new ReverseArgsError('image', 'must not be empty')
  if (value.length > 1024) throw new ReverseArgsError('image', 'must be at most 1024 characters')
  if (value.split('/').includes('..')) throw new ReverseArgsError('image', 'must not contain a .. segment')
  return value
}

/**
 * Validate generated hook source before it is allowed to travel.
 *
 * Only a size and shape check: the resident is the only place that can judge
 * whether the source compiles, and the user approves it before it is sent.
 * @param raw - caller value.
 * @returns the source unchanged.
 * @throws ReverseArgsError when it is empty or absurdly large.
 */
export function validateSource(raw: unknown): string {
  if (typeof raw !== 'string') throw new ReverseArgsError('source', 'must be a string')
  const value = raw.trim()
  if (value.length === 0) throw new ReverseArgsError('source', 'must not be empty')
  if (value.length > 256 * 1024) throw new ReverseArgsError('source', 'must be at most 256 KiB')
  return value
}

/**
 * Require a text field to be present and short enough for a frame.
 * @param raw - caller value.
 * @param field - the argument name to report.
 * @param max - inclusive character cap.
 * @returns the trimmed text, or `undefined` when absent.
 * @throws ReverseArgsError when it is present but not a string, or too long.
 */
export function validateOptionalText(raw: unknown, field: string, max: number): string | undefined {
  if (raw === undefined) return undefined
  if (typeof raw !== 'string') throw new ReverseArgsError(field, 'must be a string')
  const value = raw.trim()
  if (value.length === 0) return undefined
  if (value.length > max) throw new ReverseArgsError(field, `must be at most ${max} characters`)
  return value
}

/**
 * Require an address to fall inside one of the process images.
 *
 * A well-formed address outside every mapped image is the shape of a typo that
 * would read or overwrite unmapped memory, so the caller passes the images it
 * already enumerated and gets the containing image back.
 * @param address - an address already through {@link validateAddress}.
 * @param images - images of the target process.
 * @returns the image containing the address.
 * @throws ReverseArgsError when no image contains it.
 */
export function requireAddressInImages(
  address: string,
  images: readonly { path: string; base: string; size: number }[],
): { path: string; base: string; size: number } {
  const value = BigInt(address)
  for (const image of images) {
    const base = BigInt(image.base)
    if (value >= base && value < base + BigInt(image.size)) return image
  }
  throw new ReverseArgsError(
    'address',
    'is outside every image mapped into the target; enumerate the images first',
  )
}

/**
 * Check a scan window against the caps.
 * @param from - start of the window.
 * @param to - end of the window.
 * @throws ReverseArgsError when the window is empty or larger than the cap.
 */
export function validateScanWindow(from: string, to: string): void {
  const start = BigInt(from)
  const end = BigInt(to)
  if (end <= start) throw new ReverseArgsError('range', 'to must be greater than from')
  if (end - start > BigInt(MAX_SCAN_WINDOW)) {
    throw new ReverseArgsError('range', `window must be at most ${MAX_SCAN_WINDOW} bytes`)
  }
}
