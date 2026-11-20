/**
 * Argument validation, before any frame is sent.
 *
 * Every value here is what the model wrote as free text, so the tests are written
 * from the model's side: the shapes it plausibly produces, and the ones that must
 * never become a request the resident acts on. A hole in this file is not cosmetic —
 * it is a request aimed at the wrong address in someone else's process.
 */

import { describe, expect, it } from 'vitest'
import {
  MAX_ADDRESS,
  MAX_READ_LENGTH,
  MAX_SCAN_WINDOW,
  ReverseArgsError,
  requireAddressInImages,
  validateAddress,
  validateBundleId,
  validateDevicePath,
  validateLength,
  validateLimit,
  validateOptionalText,
  validatePid,
  validateScanWindow,
  validateSource,
  validateValue,
  validateValueType,
} from '@deepseek-ai/dsh-reverse-protocol'

/** The field a rejection names, or a marker when nothing was thrown. */
function rejected(fn: () => unknown): string {
  try {
    fn()
  } catch (error) {
    if (error instanceof ReverseArgsError) return error.field
    throw error
  }
  return '(accepted)'
}

describe('pid', () => {
  it('accepts the range the kernel hands out', () => {
    expect(validatePid(1)).toBe(1)
    expect(validatePid(99_999)).toBe(99_999)
  })

  it('rejects zero, negatives, fractions and text', () => {
    expect(rejected(() => validatePid(0))).toBe('pid')
    expect(rejected(() => validatePid(-1))).toBe('pid')
    expect(rejected(() => validatePid(12.5))).toBe('pid')
    expect(rejected(() => validatePid('1234'))).toBe('pid')
  })

  it('rejects a pid past what the kernel can allocate', () => {
    expect(rejected(() => validatePid(100_000))).toBe('pid')
  })
})

describe('bundle identifier', () => {
  it('accepts a reverse-DNS id and trims it', () => {
    expect(validateBundleId('com.example.app')).toBe('com.example.app')
    expect(validateBundleId('  com.a-b.c_d  ')).toBe('com.a-b.c_d')
  })

  it('rejects a path and the empty string', () => {
    expect(rejected(() => validateBundleId('/var/containers/Bundle/App'))).toBe('bundleId')
    expect(rejected(() => validateBundleId(''))).toBe('bundleId')
  })

  it('accepts a dotless name, which is looser than its docstring claims', () => {
    // The regex is `[A-Za-z0-9][A-Za-z0-9._-]{1,254}`, so "Instagram" passes while the
    // docstring says "must look like com.example.app". Harmless where it is used —
    // only a filter that already announced a reverse-DNS prefix comes here — but the
    // two should agree one day. Pinned so a tightening is a deliberate change.
    expect(validateBundleId('Instagram')).toBe('Instagram')
  })
})

describe('address', () => {
  it('normalizes the forms a model writes', () => {
    expect(validateAddress('0x1F4')).toBe('0x1f4')
    expect(validateAddress('1f4')).toBe('0x1f4')
    expect(validateAddress(' 0X100004000 ')).toBe('0x100004000')
  })

  it('reads a bare number as hex, never decimal', () => {
    // `1000` must mean 0x1000: reading it as decimal would silently aim elsewhere.
    expect(validateAddress('1000')).toBe('0x1000')
  })

  it('rejects the null address and the kernel half of the space', () => {
    expect(rejected(() => validateAddress('0x0'))).toBe('address')
    expect(rejected(() => validateAddress('0'))).toBe('address')
    expect(rejected(() => validateAddress('0xffffffffffffffff'))).toBe('address')
  })

  it('accepts the top of the user half', () => {
    expect(MAX_ADDRESS).toBe(0x0000_ffff_ffff_ffffn)
    expect(validateAddress('0xffffffffffff')).toBe('0xffffffffffff')
  })

  it('rejects anything that is not hexadecimal', () => {
    expect(rejected(() => validateAddress('0xzz'))).toBe('address')
    expect(rejected(() => validateAddress('12 34'))).toBe('address')
    expect(rejected(() => validateAddress(4096))).toBe('address')
  })

  it('names the field the caller asked about', () => {
    expect(rejected(() => validateAddress('nope', 'from'))).toBe('from')
  })
})

describe('read length and scan window', () => {
  it('caps one read at a mebibyte and refuses zero', () => {
    expect(validateLength(1)).toBe(1)
    expect(validateLength(MAX_READ_LENGTH)).toBe(MAX_READ_LENGTH)
    expect(rejected(() => validateLength(MAX_READ_LENGTH + 1))).toBe('length')
    expect(rejected(() => validateLength(0))).toBe('length')
  })

  it('accepts an ascending window inside the cap', () => {
    expect(() => validateScanWindow('0x1000', '0x2000')).not.toThrow()
    expect(MAX_SCAN_WINDOW).toBe(8 << 20)
  })

  it('rejects an empty, inverted or oversized window', () => {
    expect(rejected(() => validateScanWindow('0x1000', '0x1000'))).toBe('range')
    expect(rejected(() => validateScanWindow('0x2000', '0x1000'))).toBe('range')
    expect(rejected(() => validateScanWindow('0x1000', '0x900000'))).toBe('range')
  })
})

describe('value and width', () => {
  it('accepts every width the resident encodes', () => {
    for (const type of ['u8', 'i8', 'u16', 'i16', 'u32', 'i32', 'u64', 'i64', 'float', 'double'] as const) {
      expect(validateValueType(type)).toBe(type)
    }
  })

  it('rejects an unknown width', () => {
    expect(rejected(() => validateValueType('u128'))).toBe('type')
  })

  it('returns the canonical decimal for integers', () => {
    expect(validateValue('u8', '255')).toBe('255')
    expect(validateValue('u8', '0xff')).toBe('255')
    expect(validateValue('i8', '-1')).toBe('-1')
  })

  it('refuses a value that does not fit its width rather than truncating it', () => {
    expect(rejected(() => validateValue('u8', '256'))).toBe('value')
    expect(rejected(() => validateValue('i8', '-129'))).toBe('value')
    expect(rejected(() => validateValue('u32', '4294967296'))).toBe('value')
    expect(rejected(() => validateValue('u8', '3.5'))).toBe('value')
  })

  it('refuses a non-finite float', () => {
    expect(rejected(() => validateValue('float', 'NaN'))).toBe('value')
    expect(validateValue('float', '1.5')).toBe('1.5')
  })
})

describe('device path', () => {
  it('accepts an absolute path, including the .theos build output', () => {
    const built = '/var/mobile/Tweaks/VIPHook/.theos/obj/VIPHook.dylib'
    expect(validateDevicePath(built)).toBe(built)
    expect(validateDevicePath('/var/jb/usr/lib/TweakInject/Foo.dylib'))
      .toBe('/var/jb/usr/lib/TweakInject/Foo.dylib')
  })

  it('rejects a relative path and a traversal segment', () => {
    expect(rejected(() => validateDevicePath('Tweaks/VIPHook.dylib'))).toBe('path')
    expect(rejected(() => validateDevicePath('/var/mobile/../../etc/passwd'))).toBe('path')
  })

  it('rejects a path too long to frame', () => {
    expect(rejected(() => validateDevicePath(`/${'a'.repeat(1024)}`))).toBe('path')
  })
})

describe('limit and source', () => {
  it('falls back when absent and clamps over the cap', () => {
    expect(validateLimit(undefined, 50, 200)).toBe(50)
    expect(validateLimit(500, 50, 200)).toBe(200)
    expect(validateLimit(1, 50, 200)).toBe(1)
  })

  it('rejects a non-positive limit', () => {
    expect(rejected(() => validateLimit(0, 50, 200))).toBe('limit')
    expect(rejected(() => validateLimit(1.5, 50, 200))).toBe('limit')
  })

  it('accepts a hook body and rejects an empty or oversized one', () => {
    expect(validateSource('static void f(void) {}')).toBe('static void f(void) {}')
    expect(rejected(() => validateSource('   '))).toBe('source')
    expect(rejected(() => validateSource('x'.repeat(256 * 1024 + 1)))).toBe('source')
  })

  it('treats blank optional text as absent', () => {
    expect(validateOptionalText(undefined, 'image', 64)).toBeUndefined()
    expect(validateOptionalText('  ', 'image', 64)).toBeUndefined()
    expect(validateOptionalText(' Foo.dylib ', 'image', 64)).toBe('Foo.dylib')
    expect(rejected(() => validateOptionalText('x'.repeat(65), 'image', 64))).toBe('image')
  })
})

describe('address inside the images the target actually maps', () => {
  const images = [
    { path: '/usr/lib/libobjc.A.dylib', base: '0x180000000', size: 0x20000 },
    { path: '/var/containers/Bundle/App/App', base: '0x100000000', size: 0x10000 },
  ]

  it('returns the containing image', () => {
    expect(requireAddressInImages('0x100000010', images).path).toBe('/var/containers/Bundle/App/App')
    expect(requireAddressInImages('0x18001ffff', images).path).toBe('/usr/lib/libobjc.A.dylib')
  })

  it('refuses an address in no image, which is what a typo looks like', () => {
    expect(rejected(() => requireAddressInImages('0x140000000', images))).toBe('address')
    // One past the end is outside: the last byte is base + size - 1.
    expect(rejected(() => requireAddressInImages('0x100010000', images))).toBe('address')
  })
})
