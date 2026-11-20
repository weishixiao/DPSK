/**
 * Wire vocabulary of the reverse-engineering bridge: one operation table shared by
 * the harness side (client) and the SpringBoard resident (server), plus the
 * request/response envelope both ends frame over the local socket.
 *
 * The table is the single home of every operation name, its argument shape and its
 * result shape, so a new capability is added here once and both ends are forced by
 * the compiler to catch up.
 * @module @deepseek-ai/dsh-reverse-protocol/types
 */

/**
 * Protocol revision. The harness sends it in `system.hello`; a resident answering a
 * different major refuses to serve, because argument shapes are not negotiated.
 */
export const PROTOCOL_VERSION = 1

/** A 64-bit pointer, rendered as lowercase `0x`-prefixed hex. */
export type Address = string

/** The scalar width of a memory value, matching the C type the target stores. */
export const VALUE_TYPES = [
  'u8', 'i8', 'u16', 'i16', 'u32', 'i32', 'u64', 'i64', 'float', 'double',
] as const

/** One supported memory value width. */
export type ValueType = typeof VALUE_TYPES[number]

/** Every operation the resident serves. */
export type ReverseOp =
  | 'system.hello'
  | 'system.logs'
  | 'process.list'
  | 'process.images'
  | 'process.symbols'
  | 'macho.analyze'
  | 'memory.read'
  | 'memory.scan'
  | 'memory.write'
  | 'hook.install'
  | 'inject.dylib'

/**
 * Operations that change the target process or the device. The bridge always asks
 * the user before one reaches the resident; a tool may not opt out.
 */
export const DANGEROUS_OPS = ['memory.write', 'hook.install', 'inject.dylib'] as const

/** One operation that needs human approval. */
export type DangerousOp = typeof DANGEROUS_OPS[number]

/** A process the resident can see. */
export interface ReverseProcess {
  /** Kernel process id. */
  pid: number
  /** Executable base name, e.g. `SpringBoard`. */
  name: string
  /** Bundle identifier when the executable is a bundle app. */
  bundleId?: string
  /** Effective uid of the process. */
  uid: number
  /** Absolute executable path, empty when the resident could not read it. */
  path: string
}

/** One Mach-O image mapped into a process. */
export interface ReverseImage {
  /** Absolute path of the image file. */
  path: string
  /** Load address of the Mach-O header. */
  base: Address
  /** Total mapped size in bytes. */
  size: number
  /** LC_UUID of the image, when it has one. */
  uuid?: string
  /** CPU arch as reported by the header, e.g. `arm64e`. */
  arch: string
}

/** What a symbol records. */
export type SymbolKind = 'function' | 'data' | 'objc-class' | 'objc-method'

/** One symbol found in an image. */
export interface ReverseSymbol {
  /** Demangled name as the image stores it. */
  name: string
  /** Runtime address in the target, already rebased. */
  address: Address
  /** What the symbol is. */
  kind: SymbolKind
}

/** One loaded library of a Mach-O file. */
export interface MachODependency {
  /** Install name recorded in LC_LOAD_DYLIB and friends. */
  name: string
  /** True when the load command marks the dependency weak. */
  weak: boolean
}

/** One section of a Mach-O file. */
export interface MachOSection {
  /** Segment the section lives in, e.g. `__TEXT`. */
  segment: string
  /** Section name, e.g. `__text`. */
  name: string
  /** Virtual address. */
  address: Address
  /** Size in bytes. */
  size: number
}

/** The structural summary `macho.analyze` answers with. */
export interface MachOReport {
  /** Absolute path that was parsed. */
  path: string
  /** File size in bytes. */
  size: number
  /** CPU arch of the analysed slice. */
  arch: string
  /** Platform of the slice, e.g. `ios`. */
  platform: string
  /** True when the binary carries the dyld main flag (an executable). */
  executable: boolean
  /** True when the slice is encrypted (App Store binaries usually are). */
  encrypted: boolean
  /** Mach header flags as written in the header. */
  flags: number
  /** Every recorded dependency. */
  dependencies: MachODependency[]
  /** Every section, in header order. */
  sections: MachOSection[]
  /** Objective-C class names the binary declares. */
  objcClasses: string[]
  /** Objective-C method names the binary declares, `+[Class name]` style. */
  objcMethods: string[]
  /** Number of entries in the symbol table. */
  symbolCount: number
  /** Printable ASCII strings longer than eight bytes, capped by the caller. */
  strings: string[]
}

/**
 * One request the resident answered, as its log panel shows it.
 *
 * The resident keeps these in a bounded ring: the panel exists to explain what a
 * session did to the device, not to persist a history.
 */
export interface ReverseLogEntry {
  /** When the request was answered, ISO-8601 with milliseconds, UTC. */
  at: string
  /** The operation name as the request framed it. */
  op: string
  /** True when the resident answered with a result rather than an error. */
  ok: boolean
  /** Wall-clock time the resident spent on the request. */
  elapsedMs: number
  /** On failure `code: message`; absent on success. */
  detail?: string
}

/** Argument shape of each operation. */
export interface ReverseArgs {
  'system.hello': Record<string, never>
  'system.logs': { limit: number }
  'process.list': { filter?: string }
  'process.images': { pid: number }
  'process.symbols': { pid: number; image?: string; filter?: string; limit: number }
  'macho.analyze': { path: string; stringsLimit: number }
  'memory.read': { pid: number; address: Address; length: number }
  'memory.scan': {
    pid: number
    type: ValueType
    value: string
    limit: number
    /** Search window; the resident defaults it to the main image's writable segments. */
    range?: { from: Address; to: Address }
  }
  'memory.write': { pid: number; address: Address; type: ValueType; value: string }
  'hook.install': {
    pid: number
    image: string
    symbol: string
    mode: 'replace' | 'log-only'
    /** Generated substrate source, recorded by the resident for auditing. */
    source: string
  }
  'inject.dylib': { pid: number; dylibPath: string }
}

/** Result shape of each operation. */
export interface ReverseResults {
  'system.hello': {
    /** Protocol revision the resident speaks. */
    version: number
    /** Resident build identifier. */
    resident: string
    /** iOS product version of the device. */
    ios: string
    /** CPU arch, e.g. `arm64e`. */
    arch: string
    /** True when the resident can drive a Theos build on the device. */
    theos: boolean
    /** Operations this resident actually serves. */
    ops: ReverseOp[]
  }
  'system.logs': {
    /** Answered requests, oldest first, at most as many as the caller asked for. */
    entries: ReverseLogEntry[]
    /** Requests the resident answered but had to drop from its bounded ring. */
    dropped: number
  }
  'process.list': { processes: ReverseProcess[] }
  'process.images': { pid: number; images: ReverseImage[] }
  'process.symbols': { symbols: ReverseSymbol[]; truncated: boolean }
  'macho.analyze': MachOReport
  'memory.read': {
    address: Address
    length: number
    /** Hex bytes, space separated, two per byte. */
    hex: string
    /** Printable rendering of the same bytes, `.` for unprintable. */
    ascii: string
  }
  'memory.scan': {
    matches: { address: Address; value: string }[]
    /** Bytes actually compared. */
    scannedBytes: number
    /** True when the match cap stopped the scan early. */
    truncated: boolean
  }
  'memory.write': { address: Address; previous: string; written: string }
  'hook.install': { handle: string; mode: string; original: Address | null }
  'inject.dylib': { injected: boolean; image: string | null }
}

/** Argument type of one operation. */
export type ReverseArg<K extends ReverseOp> = ReverseArgs[K]

/** Result type of one operation. */
export type ReverseResult<K extends ReverseOp> = ReverseResults[K]

/** Stable failure classes; a transport failure and a refused operation never share one. */
export type ReverseErrorCode =
  | 'bad-request'
  | 'invalid-args'
  | 'not-connected'
  | 'timeout'
  | 'cancelled'
  | 'denied'
  | 'not-found'
  | 'target-gone'
  | 'unsupported'
  | 'protocol-mismatch'
  | 'remote-error'

/** The error half of a response frame. */
export interface ReverseWireError {
  code: ReverseErrorCode
  message: string
}

/** One request frame, one JSON object per line. */
export interface ReverseRequestFrame<K extends ReverseOp = ReverseOp> {
  id: string
  op: K
  args: ReverseArgs[K]
}

/** One response frame, one JSON object per line. */
export type ReverseResponseFrame =
  | { id: string; ok: true; result: unknown; elapsedMs: number }
  | { id: string; ok: false; error: ReverseWireError; elapsedMs: number }

/** True for an operation that needs approval before it is sent. */
export function isDangerousOp(op: ReverseOp): op is DangerousOp {
  return (DANGEROUS_OPS as readonly ReverseOp[]).includes(op)
}
