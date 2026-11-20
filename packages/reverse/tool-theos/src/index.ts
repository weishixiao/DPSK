/**
 * Theos scheduling, not a cross-compiler: the harness runs the `make` this device
 * already has, inside a project the user owns, only after the user has seen the
 * exact command. The project a hook is written into is scaffolded here as plain
 * Objective-C — no Logos — so what compiles on the device is what the resident
 * would install.
 * @module @deepseek-ai/dsh-tool-reverse-theos
 */

import { mkdir, readdir, stat, writeFile } from 'node:fs/promises'
import { basename, isAbsolute, join } from 'node:path'
import type { Context } from '@deepseek-ai/cordis'
import type { Agent } from '@deepseek-ai/dsh-agent'
import type { ToolCallId } from '@deepseek-ai/dsh-llm'
import z from '@deepseek-ai/schemastery'
import { defineTool, ToolContextUnavailableError } from '@deepseek-ai/dsh-tools'
import { HarnessError } from '@deepseek-ai/dsh-error'
// Type-only: resolve the `ctx.shell` and `ctx.approval` service declarations
// without depending on their implementations. A composition without either one
// refuses the build instead of running it unapproved.
import type { ShellRunResult } from '@deepseek-ai/dsh-shell'
import type {} from '@deepseek-ai/dsh-user-approval'

export const name = 'tool-reverse-theos'
export const inject = ['tools']

/** Configuration of this package. */
export interface Config {
  /** Register this package's tools at all. Defaults to true. */
  enabled?: boolean
  /** Register the build tool. Defaults to true. */
  build?: boolean
  /** Register the scaffold tool. Defaults to true. */
  scaffold?: boolean
  /**
   * The `make` binary the build runs. Defaults to `make` on `PATH`; a device that
   * keeps Theos's own tools elsewhere names that path here.
   */
  makePath?: string
  /**
   * Theos root handed to the build as `THEOS`. Defaults to the rootless
   * convention `/var/jb/opt/theos`, which roothide resolves through its own root.
   */
  theosRoot?: string
  /** Deadline of one build. Defaults to ten minutes. */
  timeoutMs?: number
}

/** Schema for {@link Config}. */
export const Config: z<Config> = z.object({
  enabled: z.boolean().default(true),
  build: z.boolean().default(true),
  scaffold: z.boolean().default(true),
  makePath: z.string().default('make'),
  theosRoot: z.string().default('/var/jb/opt/theos'),
  timeoutMs: z.number().default(600_000),
})

/** Compile jobs when the model names none. */
const DEFAULT_JOBS = 2

/** Compile jobs a single build may ask for. */
const MAX_JOBS = 8

/** Characters a Theos project name may use. */
const PROJECT_NAME = /^[A-Za-z0-9_]+$/

/** Shape of a reverse-DNS package or bundle identifier. */
const IDENTIFIER = /^[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+$/

/** Directories one .dylib search may open before giving up. */
const MAX_DYLIB_SCAN = 64

/** The make targets this tool runs; `install` is deliberately absent. */
type BuildTarget = 'package' | 'do' | 'clean'

/** Which packaging scheme a scaffolded project declares. */
type PackageScheme = 'rootless' | 'rootful' | 'roothide'

/**
 * Register the Theos tools.
 * @param ctx - registrant context with the tool registry.
 * @param config - make path, Theos root, deadline and which tools to register.
 */
export function apply(ctx: Context, config: Config): void {
  const settings = config as Required<Config>
  if (settings.enabled === false) return

  if (settings.build) {
    ctx.tools.register(defineTool({
      name: 'reverse_theos_build',
      description:
        'Build a Theos project that is already on this device: runs make in the directory you name and '
        + 'reports the exit status, the tail of both streams, the .deb it wrote and the .dylib it '
        + 'compiled. That dylib path is what reverse_hook_install takes as dylibPath, and what '
        + 'reverse_inject_dylib loads: the resident has no compiler, so the built library is how a hook '
        + 'reaches a running process. This runs the project\'s Makefile, which is code, so the build '
        + 'always stops for the user\'s decision and the prompt shows the exact command. It installs '
        + 'nothing.',
      parameters: {
        path: {
          type: 'string',
          required: true,
          description: 'Absolute path of the Theos project directory, the one holding its Makefile.',
        },
        target: {
          type: 'string',
          enum: ['package', 'do', 'clean'],
          description: 'make target: package builds the .deb, do compiles without packaging, clean removes build output. Defaults to package.',
        },
        jobs: {
          type: 'integer',
          description: `Parallel compile jobs passed as -j. Defaults to ${String(DEFAULT_JOBS)}, at most ${String(MAX_JOBS)}.`,
        },
      },
      output: {
        schema: {
          type: 'object',
          additionalProperties: false,
          properties: {
            exitCode: { type: 'integer', required: true },
            timedOut: { type: 'boolean', required: true },
            stdout: { type: 'string', required: true },
            stderr: { type: 'string', required: true },
            package: { type: 'string' },
            dylib: { type: 'string' },
          },
        },
        render: (_args, value) => ({
          type: 'text',
          text: value.timedOut
            ? 'The build was stopped at its deadline; the streams below are what it printed until then.'
            : `make exited ${String(value.exitCode)}.`
              + (value.package === undefined
                ? ' No .deb was written under packages/.'
                : ` Package: ${value.package}.`)
              + (value.dylib === undefined
                ? ' No .dylib was compiled under .theos/obj, so there is nothing to inject.'
                : ` Dylib: ${value.dylib} — pass this as dylibPath to reverse_hook_install or reverse_inject_dylib.`),
        }),
      },
      async execute(args, exec) {
        const shell = ctx.get('shell')
        if (shell === undefined) {
          throw new ToolContextUnavailableError('reverse_theos_build needs a shell executor: this composition has no ctx.shell')
        }
        if (exec.agent === undefined) {
          throw new ToolContextUnavailableError('reverse_theos_build needs an agent turn to ask for approval')
        }
        const project = await projectDirectory(args.path)
        const target: BuildTarget = args.target ?? 'package'
        const jobs = Math.min(Math.max(args.jobs ?? DEFAULT_JOBS, 1), MAX_JOBS)
        const command = `${settings.makePath} -C ${quote(project)} -j${String(jobs)} ${target}`
        await approve(ctx, exec.agent, exec.rootCallId, exec.signal, [
          `Theos build in ${project}`,
          `command: ${command}`,
          `THEOS=${settings.theosRoot}`,
          'A Makefile is code: this runs it. Nothing is installed by the build itself.',
        ].join('\n'))
        const spec = shell.resolve({
          command,
          workdir: project,
          timeoutMs: settings.timeoutMs,
          env: { THEOS: settings.theosRoot },
          signal: exec.signal,
        })
        let result: ShellRunResult
        try {
          result = await (await shell.execute(spec)).result()
        } catch (error) {
          throw new HarnessError(
            `cannot run "${settings.makePath}": ${messageOf(error)}. Theos and make have to be installed on `
            + 'this device, and Config.makePath has to name the make binary; nothing was built.',
            'theos-unavailable',
            { cause: error },
          )
        }
        const built = target === 'clean' ? undefined : await newestPackage(project)
        // The .dylib, not the .deb, is what the resident loads: report it so the
        // model can hand the path straight to reverse_hook_install.
        const library = target === 'clean' ? undefined : await newestDylib(project)
        return {
          exitCode: result.exitCode ?? -1,
          timedOut: result.timedOut,
          stdout: result.stdout.text,
          stderr: result.stderr.text,
          ...built === undefined ? {} : { package: built },
          ...library === undefined ? {} : { dylib: library },
        }
      },
      presentCall: args => ({
        card: 'generic',
        title: `Theos ${args.target ?? 'package'}`,
        kind: 'other',
        rawInput: { path: args.path, target: args.target, jobs: args.jobs },
      }),
    }))
  }

  if (settings.scaffold) {
    ctx.tools.register(defineTool({
      name: 'reverse_theos_scaffold',
      description:
        'Create a buildable Theos tweak project at an absolute path: Makefile, control, an Objective-C '
        + 'hook source that uses MSHookMessageEx (no Logos) and a filter plist for one bundle. Use it '
        + 'when the user asks for a tweak from scratch; then reverse_theos_build compiles it. It refuses '
        + 'a directory that already holds files unless force is true, and it installs nothing.',
      parameters: {
        path: {
          type: 'string',
          required: true,
          description: 'Absolute directory to create the project in, e.g. /var/mobile/Tweaks/VIPHook.',
        },
        packageId: {
          type: 'string',
          required: true,
          description: 'Debian package identifier, reverse-DNS, e.g. com.example.viphook.',
        },
        bundleId: {
          type: 'string',
          required: true,
          description: 'Bundle id the tweak filters to, e.g. com.example.app. The hook loads only inside it.',
        },
        project: {
          type: 'string',
          description: 'Theos project name used by the Makefile and the dylib name. Defaults to the directory name.',
        },
        scheme: {
          type: 'string',
          enum: ['rootless', 'rootful', 'roothide'],
          description: 'Packaging scheme written into the Makefile. Defaults to rootless.',
        },
        force: {
          type: 'boolean',
          description: 'Write into a directory that already holds files, replacing the scaffold files. Defaults to false.',
        },
      },
      output: {
        schema: {
          type: 'object',
          additionalProperties: false,
          properties: {
            path: { type: 'string', required: true },
            files: { type: 'array', required: true, items: { type: 'string' } },
          },
        },
        render: (_args, value) => ({
          type: 'text',
          text: `Scaffolded ${value.path}: ${value.files.join(', ')}.`,
        }),
      },
      async execute(args) {
        return scaffoldProject({
          path: args.path,
          packageId: args.packageId,
          bundleId: args.bundleId,
          ...args.project === undefined ? {} : { project: args.project },
          ...args.scheme === undefined ? {} : { scheme: args.scheme },
          ...args.force === undefined ? {} : { force: args.force },
        })
      },
      presentCall: args => ({
        card: 'generic',
        title: 'Scaffold tweak',
        kind: 'other',
        rawInput: { path: args.path, bundleId: args.bundleId },
      }),
    }))
  }
}

/**
 * Resolve a directory that is actually a Theos project.
 * @param path - the path the model supplied.
 * @returns the same path, once it is a directory holding a Makefile.
 * @throws HarnessError `theos-project` when it is relative, missing or has no Makefile.
 */
async function projectDirectory(path: string): Promise<string> {
  if (!isAbsolute(path)) {
    throw new HarnessError(`"${path}" is not absolute; name the project directory by its full path`, 'theos-project')
  }
  const info = await stat(path).catch(() => undefined)
  if (info === undefined || !info.isDirectory()) {
    throw new HarnessError(`"${path}" is not a directory on this device; nothing was built`, 'theos-project')
  }
  const makefile = await stat(join(path, 'Makefile')).catch(() => undefined)
  if (makefile === undefined) {
    throw new HarnessError(`"${path}" holds no Makefile, so it is not a Theos project; nothing was built`, 'theos-project')
  }
  return path
}

/**
 * Quote one word for the shell command the approval prompt shows.
 * @param value - a path or other single word.
 * @returns the word in single quotes, with embedded quotes escaped.
 */
function quote(value: string): string {
  return `'${value.replaceAll("'", "'\\''")}'`
}

/**
 * Find the package the build most recently wrote.
 * @param project - the Theos project directory.
 * @returns the newest `.deb` under `packages/`, or undefined when the build wrote none.
 */
async function newestPackage(project: string): Promise<string | undefined> {
  const directory = join(project, 'packages')
  const entries = await readdir(directory, { withFileTypes: true }).catch(() => [])
  let newest: { path: string; mtimeMs: number } | undefined
  for (const entry of entries) {
    if (!entry.isFile() || !entry.name.endsWith('.deb')) continue
    const path = join(directory, entry.name)
    const info = await stat(path).catch(() => undefined)
    if (info === undefined) continue
    if (newest === undefined || info.mtimeMs > newest.mtimeMs) newest = { path, mtimeMs: info.mtimeMs }
  }
  return newest?.path
}

/**
 * Find the library the build most recently compiled.
 *
 * Theos writes it under `.theos/obj` (`obj/<Project>.dylib`, or `obj/debug/…` for a
 * debug build), never next to the sources. It is shallow in practice, but the layout
 * is Theos's to change, so this walks the directory instead of guessing one path.
 * @param project - the Theos project directory.
 * @returns the newest `.dylib` under `.theos/obj`, or undefined when the build made none.
 */
async function newestDylib(project: string): Promise<string | undefined> {
  const root = join(project, '.theos', 'obj')
  let newest: { path: string; mtimeMs: number } | undefined
  // Bounded walk: a build tree is small, and a symlink loop must not hang the turn.
  const pending = [root]
  let visited = 0
  while (pending.length > 0 && visited < MAX_DYLIB_SCAN) {
    const directory = pending.pop()
    if (directory === undefined) break
    visited += 1
    const entries = await readdir(directory, { withFileTypes: true }).catch(() => [])
    for (const entry of entries) {
      const path = join(directory, entry.name)
      if (entry.isDirectory()) {
        pending.push(path)
        continue
      }
      if (!entry.isFile() || !entry.name.endsWith('.dylib')) continue
      const info = await stat(path).catch(() => undefined)
      if (info === undefined) continue
      if (newest === undefined || info.mtimeMs > newest.mtimeMs) newest = { path, mtimeMs: info.mtimeMs }
    }
  }
  return newest?.path
}

/**
 * Ask the user whether this exact build may run.
 * @param ctx - registrant context, for the approval service.
 * @param agent - the agent turn the question belongs to.
 * @param callId - the tool call being decided, when the registry supplied one.
 * @param signal - the tool call's signal, which withdraws the question.
 * @param reason - what will run, in the user's terms.
 * @throws HarnessError `theos-denied` when the service is missing or the answer is not `allowed-once`.
 */
async function approve(
  ctx: Context,
  agent: Agent,
  callId: ToolCallId | undefined,
  signal: AbortSignal,
  reason: string,
): Promise<void> {
  const approval = ctx.get('approval')
  if (approval === undefined) {
    throw new HarnessError('a build needs a human decision, and this composition has no approval service; nothing ran', 'theos-denied')
  }
  let decision: Awaited<ReturnType<typeof approval.request>>
  try {
    decision = await approval.request({
      agent,
      toolName: 'reverse_theos_build',
      reason,
      ...callId === undefined ? {} : { callId },
      signal,
    })
  } catch (error) {
    throw new HarnessError(`the build was not confirmed: ${messageOf(error)}; nothing ran`, 'theos-denied', { cause: error })
  }
  if (decision !== 'allowed-once') {
    throw new HarnessError(`the build was not confirmed (${String(decision)}); nothing ran`, 'theos-denied')
  }
}

/** What one scaffold writes, as the model supplied it. */
interface ScaffoldRequest {
  path: string
  packageId: string
  bundleId: string
  project?: string
  scheme?: PackageScheme
  force?: boolean
}

/**
 * Create a buildable Theos project.
 * @param request - directory, identifiers, project name, scheme and the overwrite switch.
 * @returns the directory and the file names written.
 * @throws HarnessError `theos-project` for a relative path, a bad identifier, a bad name or a directory in the way.
 */
async function scaffoldProject(request: ScaffoldRequest): Promise<{ path: string; files: string[] }> {
  const directory = request.path
  if (!isAbsolute(directory)) {
    throw new HarnessError(`"${directory}" is not absolute; name the directory to create by its full path`, 'theos-project')
  }
  assertIdentifier(request.packageId, 'packageId')
  assertIdentifier(request.bundleId, 'bundleId')
  const project = request.project ?? basename(directory)
  if (!PROJECT_NAME.test(project)) {
    throw new HarnessError(`"${project}" is not a Theos project name: use letters, digits and underscores only`, 'theos-project')
  }
  const existing = await readdir(directory).catch(() => undefined)
  if (existing !== undefined && existing.length > 0 && request.force !== true) {
    throw new HarnessError(
      `${directory} already holds ${String(existing.length)} entries and nothing was written; pass force=true to replace the scaffold files, or name an empty directory`,
      'theos-project',
    )
  }
  await mkdir(directory, { recursive: true })
  const files: [string, string][] = [
    ['Makefile', makefileText(project, request.scheme ?? 'rootless')],
    ['control', controlText(request.packageId, project)],
    ['Tweak.m', HOOK_SOURCE],
    [`${project}.plist`, filterText(request.bundleId)],
  ]
  for (const entry of files) {
    await writeFile(join(directory, entry[0]), entry[1], 'utf8')
  }
  return { path: directory, files: files.map(entry => entry[0]) }
}

/**
 * Check one reverse-DNS identifier.
 * @param value - the identifier the model supplied.
 * @param field - which field, for the message.
 * @throws HarnessError `theos-project` when it is not reverse-DNS.
 */
function assertIdentifier(value: string, field: string): void {
  if (!IDENTIFIER.test(value)) {
    throw new HarnessError(`"${value}" is not a reverse-DNS identifier for ${field}, such as com.example.tweak`, 'theos-project')
  }
}

/**
 * Reduce a caught value to a sentence.
 * @param error - whatever was thrown.
 * @returns its message, or its string form.
 */
function messageOf(error: unknown): string {
  return error instanceof Error ? error.message : String(error)
}

/**
 * The Makefile of a scaffolded project.
 * @param project - Theos project name, which also names the dylib.
 * @param scheme - packaging scheme to declare.
 * @returns the Makefile text.
 */
function makefileText(project: string, scheme: PackageScheme): string {
  const schemeLine = scheme === 'rootful'
    ? '# Rootful: no packaging scheme line, which is Theos\'s default.'
    : `THEOS_PACKAGE_SCHEME = ${scheme}`
  return `TARGET := iphone:clang:latest:16.0
ARCHS = arm64 arm64e
INSTALL_TARGET_PROCESSES = SpringBoard
${schemeLine}

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = ${project}

${project}_FILES = Tweak.m
${project}_CFLAGS = -fobjc-arc
${project}_FRAMEWORKS = Foundation
${project}_LIBRARIES = substrate

include $(THEOS_MAKE_PATH)/tweak.mk
`
}

/**
 * The control file of a scaffolded project.
 * @param packageId - Debian package identifier.
 * @param project - Theos project name.
 * @returns the control text.
 */
function controlText(packageId: string, project: string): string {
  return `Package: ${packageId}
Name: ${project}
Version: 0.0.1
Architecture: iphoneos-arm
Description: Scaffolded by the DPSK reverse workbench; replace this line.
Maintainer: replace-me
Author: replace-me
Section: Tweaks
Depends: mobilesubstrate
`
}

/**
 * The filter plist of a scaffolded project.
 * @param bundleId - the one bundle the tweak loads into.
 * @returns the plist text.
 */
function filterText(bundleId: string): string {
  return `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Filter</key>
	<dict>
		<key>Bundles</key>
		<array>
			<string>${bundleId}</string>
		</array>
	</dict>
</dict>
</plist>
`
}

/** The hook source a scaffold starts from: plain Objective-C, no Logos. */
const HOOK_SOURCE = `// Plain Objective-C: no Logos, so the source the model reads is the source that
// compiles. Replace TargetClass, targetMethod and the signature with the method
// reverse_symbols resolved; a method that returns a value or takes arguments
// needs its replacement to match exactly.
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <substrate.h>

static IMP original_method;

static void hooked_method(id self, SEL _cmd) {
  NSLog(@"[DPSK] %@ %s reached", NSStringFromClass(object_getClass(self)), sel_getName(_cmd));
  ((void (*)(id, SEL))original_method)(self, _cmd);
}

__attribute__((constructor)) static void dpsk_hook_initialize(void) {
  Class target = objc_getClass("TargetClass");
  if (target == NULL) {
    NSLog(@"[DPSK] TargetClass is not in this process; nothing hooked");
    return;
  }
  SEL selector = sel_registerName("targetMethod");
  MSHookMessageEx(target, selector, (IMP)hooked_method, &original_method);
  NSLog(@"[DPSK] hooked -[TargetClass targetMethod]");
}
`
