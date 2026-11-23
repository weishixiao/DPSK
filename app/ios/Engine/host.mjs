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

import { appendFileSync, existsSync, realpathSync } from 'node:fs'
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

/** Whether two paths name the same directory, symlinks and all. */
function sameDirectory(left, right) {
  try {
    return realpathSync(left) === realpathSync(right)
  } catch {
    // A path that does not exist cannot be the one the harness runs in.
    return false
  }
}

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
  // The app already made this the working directory: Node runs an embedded
  // Environment with worker semantics, where `process.chdir` is a stub that
  // throws, so the cwd has to be process state set before Node starts
  // (EngineRuntime.enterWorkspace). Checking it here turns a wrong cwd into one
  // sentence that names both paths, instead of a harness writing into the
  // read-only bundle or a stack trace from inside Node.
  // Compared through `realpath`: the container is reached as `/var/...`, while
  // `getcwd` reports the resolved `/private/var/...`, so a plain string compare
  // of two names for one directory would fail and take the boot with it.
  if (sameDirectory(process.cwd(), workspace)) {
    // Already where the harness expects to run.
  } else {
    try {
      process.chdir(workspace)
    } catch (error) {
      throw new Error(
        `cwd is ${process.cwd()}, not the workspace ${workspace}: ${error?.code ?? error}`,
      )
    }
  }

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
  // `runCli` on a served host does not return. When it does, the server it was
  // serving is gone -- a profile row that failed to mount still lets the HTTP
  // listener bind and print its address, and then the run ends. Returning here is
  // what made the device see a listening port for a quarter of a second and then
  // nothing: the app's poll interval is longer than the time the process had left.
  //
  // So: stay up and say so. The app is told the truth by the log, the port stops
  // answering on its own, and the process is not torn down while the user is
  // still looking at the boot screen.
  log('harness returned without serving; holding the process open so the log survives')
  setInterval(() => {}, 1 << 30)
} catch (error) {
  log(`harness failed to start: ${error?.stack ?? error}`)
  // Keep the event loop alive so the app can show the log path instead of the
  // whole UI vanishing when Node would otherwise exit.
  setInterval(() => {}, 1 << 30)
}
