/**
 * The `ctx.reverse` seam and its local-socket provider, mounted together.
 *
 * The default export is the provider class, so a composition listing this package
 * gets a working bridge; the seam and the argument canonicalizer are named exports
 * for consumers and tests.
 * @module @deepseek-ai/dsh-reverse-bridge
 */

export { ReverseBridge, ReverseBridgeError } from './seam.ts'
export type {
  ReverseCallOptions,
  ReverseMutationOptions,
  ReverseState,
  ReverseStatus,
} from './seam.ts'
export { Config, LocalSocketReverseBridge } from './local-socket.ts'
export type { Config as ReverseBridgeConfig } from './local-socket.ts'
export {
  DEFAULT_LOG_LIMIT,
  DEFAULT_STRING_LIMIT,
  DEFAULT_SYMBOL_LIMIT,
  MAX_LOG_LIMIT,
  normalizeArguments,
} from './normalize.ts'
export { LocalSocketReverseBridge as default } from './local-socket.ts'
