---
description: "Provider failover at the agent loop's request recovery point: when the active provider reports a quota, credential or auth failure, the same turn continues on the configured fallback."
kind: "package-reference"
---

# @deepseek-ai/dsh-llm-failover

English | [中文](README.zh.md)

## Summary

`dsh-llm-failover` keeps a turn alive when the provider it started on cannot answer for a reason a retry cannot fix: the account is out of balance, the key is rejected, the account has to sign in again. It listens on `agent/request-error`, and when the failure code is one of those, it selects the next configured provider on the agent and hands the loop `{ kind: 'retry' }`, so the retry runs on the fallback instead of failing the turn.

It is a policy listener, not a provider: it opens no connection, never sees a request body, and cannot change what the model already saw in the failed attempt — the next step is a fresh request on the other provider.

## Table of Contents

- [Use this package](#use-this-package)
- [Understand the implementation](#understand-the-implementation)
- [Known Limitations and Deferred Work](#known-limitations-and-deferred-work)
- [Dev Note](#dev-note)

-----

<a id="use-this-package"></a>
## Use this package

```yaml
- id: llm-failover
  name: '@deepseek-ai/dsh-llm-failover'
  config:
    fallback:
      - provider: glm
        model: glm-4.6
    maxHops: 2
```

`codes` defaults to the failures a retry cannot fix — `QUOTA`, `ACCOUNT_QUOTA`, `INVALID_CREDENTIAL`, `MISSING_CREDENTIAL`, `ACCOUNT_TOKEN_INVALID`, `ACCOUNT_SIGN_IN_REQUIRED`, `AUTH`. Narrow it to fall back less often, or widen it to cover a provider's own rejection codes. Every fallback provider named must already be registered with `ctx.llm`, or the switch fails and the provider's own recovery decides.

<a id="understand-the-implementation"></a>
## Understand the implementation

The listener runs at the durable agent-step boundary the loop raises for a failed request. It skips the provider that just failed, so a single-entry chain still covers a two-provider deployment, and it counts hops per turn: past `maxHops` the failure is reported as it would be without the plugin, rather than looping between two broken providers. The count resets when the turn changes, so an early-quota turn does not starve later ones. The model selection takes effect at the next `prepareRequest`, which is why the retry leaves the failed provider behind.

<a id="known-limitations-and-deferred-work"></a>
## Known Limitations and Deferred Work

- The fallback is chosen by code, not by health: a provider that answers 500s never triggers a switch, because a retry may fix that one.
- The plugin does not switch back. Once a turn is on the fallback it stays there until the turn ends; a new turn starts on the configured default.
- The failed attempt stays in the transcript as its own error, so the model sees that the first request did not go through.

<a id="dev-note"></a>
## Dev Note

`agent.model.select()` is the whole mechanism; the plugin owns nothing else. If a provider id is unregistered the call throws, so list only providers a composition actually mounts, or the failure is reported and the turn ends as it would have.