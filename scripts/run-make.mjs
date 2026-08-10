#!/usr/bin/env node
/**
 * npm-script shim for the Makefile-backed test targets (issue #45).
 *
 * `npm test` used to run `make test` directly, which on a stock Windows box
 * dies with a bare `'make' is not recognized`. That tells a contributor nothing
 * about whether their change is sound, and it is a tripwire that blocks them
 * before a single test has run.
 *
 * So: resolve `make`, run the target when it is present, and when it is absent
 * print a loud notice naming the target, the reason and the two ways to run it,
 * then exit 0.
 *
 * Two properties matter more than the convenience:
 *
 *  - The guard triggers on `make` being *unavailable*, never on
 *    `process.platform === "win32"`. A Windows box that has make runs the real
 *    suite; a Linux CI box missing make gets this message instead of a raw
 *    ENOENT. CI is unaffected — make is present there, so every target runs
 *    exactly as before.
 *  - When make *is* present, the child's exit code is forwarded verbatim. A
 *    guard that swallowed genuine test failures would be far worse than the
 *    bug it replaces.
 */

import { spawnSync } from "node:child_process";
import { existsSync } from "node:fs";
import { delimiter as pathDelimiter, resolve } from "node:path";

const target = process.argv[2];
const extraArgs = process.argv.slice(3);

if (!target) {
  console.error("usage: node scripts/run-make.mjs <make-target> [make-args...]");
  process.exit(2);
}

/** Candidate file names for `make`, in PATH-scan order, per platform. */
const MAKE_EXECUTABLE_NAMES =
  process.platform === "win32" ? ["make.exe", "make"] : ["make"];

/**
 * Scan PATH for `make` rather than spawning it and interpreting ENOENT, so
 * "make is missing" is distinguishable from "make ran and failed".
 */
function findMakeOnPath() {
  const rawPath = process.env.PATH ?? "";
  if (!rawPath) return null;

  for (const entry of rawPath.split(pathDelimiter)) {
    // Windows PATH entries are sometimes quoted; an empty entry means "cwd",
    // which we do not want to search for a build tool.
    const dir = entry.trim().replace(/^"|"$/g, "");
    if (!dir) continue;
    for (const name of MAKE_EXECUTABLE_NAMES) {
      const candidate = resolve(dir, name);
      if (existsSync(candidate)) return candidate;
    }
  }
  return null;
}

/** Loud, non-fatal skip notice. Silently succeeding without testing is worse. */
function printSkipNotice() {
  const lines = [
    `SKIPPED: make ${target}`,
    "",
    "Reason: `make` was not found on PATH, so this target could not run.",
    "        Nothing was tested. This is a skip, not a pass.",
    "",
    "Kannaktopus' test suite is bash end to end (the Makefile targets shell out",
    "to `bash tests/...` runners), so run it one of these two ways:",
    "",
    "  1. Git Bash + make",
    "       Install Git for Windows, then GNU make (e.g. `choco install make`),",
    `       and run:  make ${target}`,
    "",
    "  2. WSL",
    "       wsl -e bash -lc 'sudo apt-get install -y make && " +
      `make ${target}'`,
    "",
    "With Git Bash on PATH you can also run the underlying scripts directly,",
    "e.g. `bash tests/run-all.sh unit`.",
  ];

  const width = Math.max(...lines.map((l) => l.length)) + 2;
  const border = "═".repeat(width);
  console.error(`\n╔${border}╗`);
  for (const line of lines) {
    console.error(`║ ${line.padEnd(width - 1)}║`);
  }
  console.error(`╚${border}╝\n`);
}

const make = findMakeOnPath();

if (!make) {
  printSkipNotice();
  process.exit(0);
}

const result = spawnSync(make, [target, ...extraArgs], { stdio: "inherit" });

if (result.error) {
  console.error(`Failed to run \`make ${target}\`: ${result.error.message}`);
  process.exit(1);
}

// Forward the real outcome. A signalled death is a failure, not a pass.
if (result.signal) {
  console.error(`\`make ${target}\` terminated by signal ${result.signal}`);
  process.exit(1);
}

process.exit(result.status ?? 1);
