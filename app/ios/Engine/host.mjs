#!/usr/bin/env node
// The engine's Node entry point: the one script `node::Start` runs inside
// DPSK.app.
//
// It boots the harness through its supported application-launch path — the dsh
// CLI's `runCli()` with the `web` profile — and binds the Web UI to loopback, so
// the app's WKWebView talks to a local server and the harness never needs a
// separate process, a shell, or a remote host.
//
// Layout this file expects (written by `tooling/ios/prepare-engine.sh`):
//
//   Engine/
//     host.mjs              this file
//     ios.patch.yml         the loader overlay that drops what iOS cannot run
//     runtime/harness/      `pnpm deploy` of @deepseek-ai/dsh: lib/bin.js + node_modules
//
// Everything the environment supplies comes from EngineRuntime.swift:
//   DPSK_ENGINE_ROOT  this directory
//   DPSK_PORT         loopback port to serve on (EngineRuntime.defaultPort)
//   DSH_HOME          harness state directory (Application Support/dsh)
//   HOME, TMPDIR      the app container's, since the bundle is read-only

import { appendFileSync } from 'node:fs'
import { mkdir } from 'node:fs/promises'
import { dirname, join } from 'node:path'
import { fileURLToPath, pathToFileURL } from 'node:url'

const engineRoot = process.env.DPSK_ENGINE_ROOT ?? dirname(fileURLToPath(import.meta.url))
const binary = join(engineRoot, 'runtime', 'harness', 'lib', 'bin.js')
const patch = join(engineRoot, 'ios.patch.yml')
const port = Number(process.env.DPSK_PORT ?? 8799)

const home = process.env.DSH_HOME
const logPath = join(home ?? engineRoot, '..', 'Logs', 'engine.log')

/** Append one line to the engine log, and keep going if the log is unwritable. */
function log(line) {
  try {
    appendFileSync(logPath, `[engine] ${new Date().toISOString()} ${line}\n`)
  } catch {
    // The log is a diagnostic, never a precondition for serving.
  }
}

// The engine shares the app's process, so an escaping error must not take the
// UI with it. Report, then keep running: the server may still be healthy.
process.on('uncaughtException', (error) => {
  log(`uncaughtException: ${error?.stack ?? error}`)
})
process.on('unhandledRejection', (reason) => {
  log(`unhandledRejection: ${reason?.stack ?? reason}`)
})

// Mirror Node's own console output into the log: on iOS stdout goes nowhere.
for (const stream of ['stdout', 'stderr']) {
  const original = process[stream].write.bind(process[stream])
  process[stream].write = (chunk, ...rest) => {
    log(String(chunk).trimEnd())
    return original(chunk, ...rest)
  }
}

// The harness treats `process.cwd()` as the workspace root and writes there; the
// bundle is read-only, so it runs from Documents/workspace, created on boot.
const workspace = process.env.DPSK_WORKSPACE ?? join(dirname(process.env.HOME ?? engineRoot), 'workspace')
await mkdir(workspace, { recursive: true })
process.chdir(workspace)

// The CLI parses `process.argv.slice(2)`; argv[0] and argv[1] only have to exist.
process.argv = [
  process.execPath,
  binary,
  '--profile', 'web',
  '--patch', patch,
  '--host', '127.0.0.1',
  '--port', String(port),
  '--no-open',
]

log(`starting harness: ${binary} on 127.0.0.1:${port} (cwd ${workspace})`)

try {
  const { runCli } = await import(pathToFileURL(binary).href)
  await runCli()
  log('harness returned; the engine is no longer serving')
} catch (error) {
  log(`harness failed to start: ${error?.stack ?? error}`)
  // Keep the event loop alive so the app can show the log path instead of the
  // whole UI vanishing when Node would otherwise exit.
  setInterval(() => {}, 1 << 30)
}
