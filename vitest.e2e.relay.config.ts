/**
 * Real-API e2e suite restricted to the files a mirror can serve.
 *
 * `vitest.e2e.config.ts` runs every real-model suite against `DEEPSEEK_BASE_URL`
 * (default `https://api.deepseek.com/anthropic`). Not every file actually honors
 * that variable: several boot a provider with `PUBLIC_BASE_URL` as their default,
 * and a few exercise official-only surfaces (the Files API upload/index path, the
 * hosted web-search endpoint). Pointed at a relay those files fail with 401 even
 * though the relay is healthy, which turns a green/red signal into noise.
 *
 * This profile keeps the rest — the suites that resolve their endpoint from the
 * environment and only need an Anthropic-compatible Messages endpoint — so a
 * mirror-backed run still means something. The exclusions below are the files
 * observed failing against a mirror at 442cf71f (run 44918186077); shrink the
 * list by making a suite read `DEEPSEEK_BASE_URL` instead of the public constant,
 * never by deleting a suite that would pass on the official endpoint.
 *
 * Select it with `pnpm run test:e2e:relay` (the ios/e2e workflow does so when the
 * repository variable `DSH_E2E_SUITE` is `relay`).
 */
import { defineConfig, mergeConfig } from 'vitest/config'
import base from './vitest.e2e.config.ts'

/** Suites that pin the official endpoint or exercise official-only surfaces. */
export const OFFICIAL_ENDPOINT_ONLY = [
  // Files API (upload / index / replace) and `boot()` defaults to PUBLIC_BASE_URL.
  'packages/llm/llm-deepseek/tests/adapter.e2e.ts',
  'packages/llm/llm-deepseek/tests/runtime.e2e.ts',
  // OpenAI-completions adapter with its own official-only assumptions.
  'packages/llm/llm-pi-ai/tests/adapter.e2e.ts',
  // Spawned `dsh` processes and subagents that rebuild their own provider config.
  'apps/cli/tests/profiles/acp/tests/acp.e2e.ts',
  'apps/cli/tests/profiles/acp/tests/escalation.e2e.ts',
  'apps/cli/tests/profiles/acp/tests/hooks.e2e.ts',
  'apps/cli/tests/profiles/headless/tests/coding-task.e2e.ts',
  'apps/cli/tests/profiles/headless/tests/compaction.e2e.ts',
  'apps/cli/tests/profiles/headless/tests/full-loop.e2e.ts',
  'apps/cli/tests/profiles/headless/tests/real-model.e2e.ts',
  'apps/cli/tests/profiles/headless/tests/resume.e2e.ts',
  'apps/cli/tests/profiles/headless/tests/todo-write.e2e.ts',
  'apps/cli/tests/profiles/sdk/dynamic-tool-cache.e2e.ts',
  'apps/cli/tests/profiles/sdk/office-cli.e2e.ts',
  'packages/context/agent-instructions/tests/agent-instructions.e2e.ts',
  'packages/core/agent-loop/tests/request-cache.e2e.ts',
  'packages/fs/tool-fs/tests/fs-tools.e2e.ts',
  'packages/session/session-title-first-prompt-llm/tests/provider.e2e.ts',
  'packages/subagent/subagent-acp/tests/subagent-acp.e2e.ts',
  'packages/subagent/subagent-claude-code/tests/real-deepseek.e2e.ts',
  'packages/subagent/subagent-codex/tests/real-deepseek.e2e.ts',
  'packages/subagent/subagent-spawn-in-process/tests/spawn-in-process.e2e.ts',
  'packages/workflow/workflow-ptc/tests/workflow-ptc.e2e.ts',
] as const

export default mergeConfig(
  base,
  defineConfig({
    test: {
      exclude: [...(base.test?.exclude ?? []), ...OFFICIAL_ENDPOINT_ONLY],
    },
  }),
)
