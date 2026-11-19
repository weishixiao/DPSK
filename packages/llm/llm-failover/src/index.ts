/**
 * Provider failover on the agent loop's request recovery point: when the active
 * provider answers with a quota, credential, or auth failure, the agent's next
 * attempt runs on the configured fallback provider instead of failing the turn.
 *
 * This is a policy listener, not a provider: it never opens a connection and never
 * sees a request body. It only re-selects the model the loop will prepare next,
 * which is why it cannot change what the model saw in the failed attempt.
 * @module @deepseek-ai/dsh-llm-failover
 */

import type { Context } from '@deepseek-ai/cordis'
import z from '@deepseek-ai/schemastery'
import type { Agent } from '@deepseek-ai/dsh-agent'

export const name = 'llm-failover'

/** One provider the loop may fall back to. */
export interface FallbackTarget {
  /** Registered provider id, e.g. `glm` or `deepseek-official`. */
  provider: string
  /** Model id on that provider, e.g. `glm-4.6`. */
  model: string
}

/** Failover policy. */
export interface Config {
  /**
   * Providers to try, in order, after the active one failed. The active provider
   * itself is skipped, so a chain of two covers a two-provider deployment.
   */
  fallback: FallbackTarget[]
  /**
   * Failure codes that trigger a fallback rather than the provider's own retry.
   * The defaults are the ones a retry cannot fix: the account has no balance, the
   * key is wrong, or the account must sign in again.
   */
  codes: string[]
  /** How many fallbacks one turn may take before the failure is reported. */
  maxHops: number
}

/** Codes a retry cannot fix; the fallback is the only way forward. */
export const DEFAULT_FALLOVER_CODES = [
  'QUOTA',
  'ACCOUNT_QUOTA',
  'INVALID_CREDENTIAL',
  'MISSING_CREDENTIAL',
  'ACCOUNT_TOKEN_INVALID',
  'ACCOUNT_SIGN_IN_REQUIRED',
  'AUTH',
] as const

/** Schema for {@link Config}. */
export const Config: z<Config> = z.object({
  fallback: z.array(z.object({
    provider: z.string().required(),
    model: z.string().required(),
  })).default([]),
  codes: z.array(z.string()).default([...DEFAULT_FALLOVER_CODES]),
  maxHops: z.number().default(2),
})

/** Per-agent fallback bookkeeping for the turn in progress. */
interface HopState {
  turn: number
  hops: number
}

/**
 * Install the fallback listener.
 * @param ctx - plugin context owning the listener.
 * @param config - the fallback chain and the codes that trigger it.
 */
export function apply(ctx: Context, config: Config = { fallback: [], codes: [...DEFAULT_FALLOVER_CODES], maxHops: 2 }): void {
  const codes = new Set(config.codes)
  const state = new WeakMap<Agent, HopState>()

  ctx.on('agent/request-error', async ({ agent, turn, provider, failure, signal }, next) => {
    if (!codes.has(failure.code)) return next()
    if (signal.aborted) return next()
    const target = config.fallback.find(entry => entry.provider !== provider)
    if (target === undefined) {
      ctx.logger.warn(`llm-failover: "${provider}" failed with ${failure.code} and no fallback is configured`)
      return next()
    }
    const previous = state.get(agent)
    const hops = previous?.turn === turn ? previous.hops : 0
    if (hops >= config.maxHops) {
      ctx.logger.warn(`llm-failover: turn ${turn} exhausted ${config.maxHops} fallbacks; reporting ${failure.code}`)
      return next()
    }
    try {
      agent.model.select({ provider: target.provider, model: target.model })
    } catch (error: unknown) {
      // An unregistered fallback is a configuration mistake: report it and let the
      // provider's own recovery decide, rather than failing the turn here.
      ctx.logger.warn(
        `llm-failover: cannot select ${target.provider}/${target.model}: ${error instanceof Error ? error.message : String(error)}`,
      )
      return next()
    }
    state.set(agent, { turn, hops: hops + 1 })
    ctx.logger.info(`[failover] ${provider} -> ${target.provider}/${target.model} after ${failure.code}`)
    return { kind: 'retry' }
  })
}