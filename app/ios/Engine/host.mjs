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
//     ios-preset.patch.yml  the shipped `standard` preset minus the process tools
//     runtime/harness/      `pnpm deploy` of @deepseek-ai/dsh: lib/bin.js + node_modules
//
// Everything the environment supplies comes from EngineRuntime.swift:
//   DPSK_ENGINE_ROOT  this directory
//   DPSK_PORT         loopback port to serve on (EngineRuntime.defaultPort)
//   DSH_HOME          harness state directory (Application Support/dsh)
//   DPSK_WORKSPACE    the writable directory the harness treats as its root
//   DPSK_LOG          the log file the app's settings screen names
//   HOME, TMPDIR      the app container's, since the bundle is read-only

import { appendFileSync, existsSync } from 'node:fs'
import { mkdir } from 'node:fs/promises'
import { dirname, join } from 'node:path'
import { fileURLToPath, pathToFileURL } from 'node:url'

const engineRoot = process.env.DPSK_ENGINE_ROOT ?? dirname(fileURLToPath(import.meta.url))
const binary = join(engineRoot, 'runtime', 'harness', 'lib', 'bin.js')
const patch = join(engineRoot, 'ios.patch.yml')
// The preset override restates a row the bundle inserts, so it has to come after
// the overlay; a missing file is skipped rather than fatal, because the overlay
// alone still boots (the model just keeps a `bash` tool that cannot run).
const presetPatch = join(engineRoot, 'ios-preset.patch.yml')
const port = Number(process.env.DPSK_PORT ?? 8799)

const home = process.env.DSH_HOME
// The app owns both paths, because only it can name a directory its sandbox
// allows: `HOME` is the container root, so deriving the workspace from it walks
// out of the sandbox and `mkdir` fails with EPERM. Running this file from a Mac
// instead (no app env) keeps everything under `DSH_HOME`.
const logPath = process.env.DPSK_LOG ?? join(home ?? engineRoot, 'Logs', 'engine.log')
const workspace = process.env.DPSK_WORKSPACE ?? join(home ?? engineRoot, 'workspace')

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

// Node exits 0 when the module finishes without keeping the loop alive, and the
// app only sees its port wait time out. Leave a trace of that exit either way.
process.on('exit', (code) => {
  log(`node exited with ${code}; the engine is no longer serving`)
})

// Mirror Node's own console output into the log: on iOS stdout goes nowhere.
for (const stream of ['stdout', 'stderr']) {
  const original = process[stream].write.bind(process[stream])
  process[stream].write = (chunk, ...rest) => {
    log(String(chunk).trimEnd())
    return original(chunk, ...rest)
  }
}

// The harness treats `process.cwd()` as the workspace root and writes there, so
// a workspace that cannot be created or entered is fatal — but it is reported as
// one failure rather than as a silent exit at import time.
try {
  await mkdir(workspace, { recursive: true })
  process.chdir(workspace)

  // The CLI parses `process.argv.slice(2)`; argv[0] and argv[1] only have to exist.
  process.argv = [
    process.execPath,
    binary,
    '--profile', 'web',
    '--patch', patch,
    ...(existsSync(presetPatch) ? ['--patch', presetPatch] : []),
    '--host', '127.0.0.1',
    '--port', String(port),
    '--no-open',
  ]

  log(`starting harness: ${binary} on 127.0.0.1:${port} (cwd ${workspace})`)

  const { runCli } = await import(pathToFileURL(binary).href)
  await runCli()
  log('harness returned; the engine is no longer serving')
} catch (error) {
  log(`harness failed to start: ${error?.stack ?? error}`)
  // Keep the event loop alive so the app can show the log path instead of the
  // whole UI vanishing when Node would otherwise exit.
  setInterval(() => {}, 1 << 30)
}
