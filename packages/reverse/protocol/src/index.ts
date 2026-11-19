/**
 * Wire protocol and argument validation for the reverse-engineering bridge.
 *
 * One package owns the vocabulary — operation names, argument and result shapes,
 * the frame envelope — and the checks every argument passes before it is framed.
 * The harness bridge is a consumer; the SpringBoard resident mirrors this table in
 * Objective-C, and the "IPC protocol" section of `docs/reverse/readme.md` is the
 * prose copy both are held to.
 * @module @deepseek-ai/dsh-reverse-protocol
 */

export {
  DANGEROUS_OPS,
  isDangerousOp,
  PROTOCOL_VERSION,
  VALUE_TYPES,
} from './types.ts'
export type {
  Address,
  DangerousOp,
  MachODependency,
  MachOReport,
  MachOSection,
  ReverseArg,
  ReverseArgs,
  ReverseErrorCode,
  ReverseImage,
  ReverseOp,
  ReverseProcess,
  ReverseRequestFrame,
  ReverseResponseFrame,
  ReverseResult,
  ReverseResults,
  ReverseSymbol,
  ReverseWireError,
  SymbolKind,
  ValueType,
} from './types.ts'
export {
  MAX_ADDRESS,
  MAX_READ_LENGTH,
  MAX_SCAN_WINDOW,
  requireAddressInImages,
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
} from './validate.ts'
export {
  encodeFrame,
  FrameError,
  LineFramer,
  MAX_FRAME_BYTES,
  parseResponse,
} from './frame.ts'
