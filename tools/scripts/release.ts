#!/usr/bin/env bun
import { execFileSync } from "node:child_process";
import { existsSync, readFileSync, readdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { createInterface } from "node:readline/promises";

const help = `Usage: TEAM_ID=... BUILD_NUMBER=... NOTARY_PROFILE=... bun run release:run [options]

Guides changeset review, versioning, a release commit, packaging, testing, and
GitHub draft upload. Prompts before versioning, committing, and uploading.
Never publishes a release. Run from a clean checkout with signing credentials.

--from prepare|version|package|draft  Resume at a stage (default: prepare).
--since <ref>                       Preparation baseline override.
--initial                           Prepare from all history.
--bump patch|minor|major             Newly drafted changeset bump (default: patch).

The package stage requires a committed version/changelog. The draft stage requires
artifacts and release-source.json from a successful package stage of this command.
Failed packaging retains logs; inspect and remove its output directory before retrying.`;

type Stage = "prepare" | "version" | "package" | "draft";
export type Options = { from: Stage; preparation: string[] };
export function parseOptions(args: string[]): Options {
  const options: Options = { from: "prepare", preparation: [] };
  for (let i = 0; i < args.length; i++) {
    const arg = args[i];
    if (arg === "--from") {
      const stage = args[++i];
      if (!["prepare", "version", "package", "draft"].includes(stage ?? "")) throw new Error("Invalid --from stage");
      options.from = stage as Stage;
    } else if (arg === "--initial") options.preparation.push(arg);
    else if (arg === "--since" || arg === "--bump") {
      const value = args[++i];
      if (!value || value.startsWith("-")) throw new Error(`${arg} needs a value`);
      if (arg === "--bump" && !["patch", "minor", "major"].includes(value)) throw new Error("Invalid --bump");
      options.preparation.push(arg, value);
    } else throw new Error(`Unknown option: ${arg}`);
  }
  if (options.preparation.includes("--initial") && options.preparation.includes("--since")) throw new Error("Use either --since or --initial");
  if (options.from !== "prepare" && options.preparation.length) throw new Error("Preparation options require --from prepare");
  return options;
}

export function releaseNotes(changelog: string, version: string): string {
  const lines = changelog.split("\n");
  const start = lines.findIndex(line => line.trim() === `## ${version}`);
  if (start < 0) throw new Error(`No changelog section for ${version}`);
  const end = lines.findIndex((line, i) => i > start && /^## /.test(line));
  const notes = lines.slice(start + 1, end < 0 ? undefined : end).join("\n").trim();
  if (!notes) throw new Error(`Empty release notes for ${version}`);
  return `${notes}\n`;
}

export type ReleaseIO = {
  run: (args: string[], capture?: boolean, cwd?: string) => string;
  confirm: (message: string) => Promise<void>;
  log: (message: string) => void;
};

export async function runRelease(root: string, options: Options, env: Record<string, string | undefined>, io: ReleaseIO) {
  const { run, confirm, log } = io;
  const build = env.BUILD_NUMBER ?? "";
  if (!/^[A-Z0-9]{10}$/.test(env.TEAM_ID ?? "")) throw new Error("Set TEAM_ID to your Apple Developer team ID");
  if (!/^[1-9][0-9]{0,3}$/.test(build) || Number(build) <= 92) throw new Error("Set BUILD_NUMBER to an unused integer greater than 92");
  if (!env.NOTARY_PROFILE) throw new Error("Set NOTARY_PROFILE to your Keychain profile");
  const git = (...args: string[]) => run(["git", ...args], true).trim();
  const clean = () => { if (git("status", "--porcelain")) throw new Error("Commit or set aside working-tree changes before continuing"); };
  clean();
  const pending = () => readdirSync(join(root, ".changeset")).filter(name => name.endsWith(".md") && name !== "README.md");
  const getVersion = () => {
    const version = JSON.parse(readFileSync(join(root, "package.json"), "utf8")).version;
    if (typeof version !== "string" || !/^\d+\.\d+\.\d+$/.test(version)) throw new Error("Expected stable x.y.z version in package.json");
    return version;
  };
  const stages: Stage[] = ["prepare", "version", "package", "draft"];
  const startsBefore = (stage: Stage) => stages.indexOf(options.from) <= stages.indexOf(stage);
  if (startsBefore("version")) {
    // Check external prerequisites before modifying version metadata.
    run(["gh", "auth", "status"]);
    run(["bun", "run", "release", "--check"]);
    if (options.from === "prepare") {
      run(["git", "fetch", "origin", "--tags"]);
      run(["bun", "run", "release:prepare", "--write", ...options.preparation]);
    }
    await confirm("Review build/release-preparation.md and edit .changeset/*.md. Remove duplicate/internal notes; keep provenance comments. Continue to versioning?");
    if (!pending().length) throw new Error("No pending changesets. If the version is already prepared and committed, use --from package");
    // Only release metadata may be edited while the review prompt is open.
    const changed = git("diff", "--name-only", "HEAD").split("\n").filter(Boolean);
    const untracked = git("ls-files", "--others", "--exclude-standard").split("\n").filter(Boolean);
    if ([...changed, ...untracked].some(path => !/^\.changeset\/[^/]+\.md$/.test(path))) {
      throw new Error("Unexpected edits during changeset review; commit code separately before restarting");
    }
    run(["bun", "run", "changeset:status"]);
    await confirm("Is the Changesets version plan correct? Apply the version and changelog updates?");
    const previousVersion = getVersion();
    run(["bun", "run", "changeset:version"]);
    run(["bun", "run", "sync-changelog"]);
    const version = getVersion();
    if (version === previousVersion) throw new Error("Changesets did not change the version; inspect the release plan");
    run(["git", "diff", "--stat"]);
    await confirm(`Review package.json, CHANGELOG.md, and Hex/Resources/changelog.md. Commit release ${version}?`);
    run(["git", "add", "--", ".changeset", "package.json", "CHANGELOG.md", "Hex/Resources/changelog.md"]);
    run(["git", "commit", "-m", `Prepare Hex ${version} release`]);
  }
  clean();
  const version = getVersion();
  const head = git("rev-parse", "HEAD");
  const output = join(root, "build", "releases", `${version}-${build}`);
  const manifestPath = join(output, "release-source.json");
  if (startsBefore("package")) {
    // Validate release notes before starting an expensive build.
    releaseNotes(readFileSync(join(root, "CHANGELOG.md"), "utf8"), version);
    run(["bun", "run", "test:release"]);
    run(["bun", "run", "test:core"]);
    run(["bun", "run", "release"]);
    writeFileSync(manifestPath, `${JSON.stringify({ version, build, commit: head }, null, 2)}\n`, { flag: "wx" });
  }
  const source = JSON.parse(readFileSync(manifestPath, "utf8"));
  if (source.version !== version || source.build !== build || source.commit !== head) {
    throw new Error("Packaged artifacts do not match this version, build number, and commit");
  }
  for (const name of [`Hex-${version}.zip`, `Hex-${version}.dmg`, "SHA256SUMS"]) {
    if (!existsSync(join(output, name))) throw new Error(`Missing artifact: ${name}`);
  }
  // Validate the final ZIP and DMG against the packager's checksums.
  run(["shasum", "-a", "256", "-c", "SHA256SUMS", "--status"], false, output);
  const notesPath = join(output, "release-notes.md");
  if (!existsSync(notesPath)) writeFileSync(notesPath, releaseNotes(readFileSync(join(root, "CHANGELOG.md"), "utf8"), version));
  log(`Artifacts: ${output}\nRelease notes: ${notesPath}`);
  await confirm("Confirm CI passed, then test the packaged app from /Applications: permissions, model download, transcription, hotkeys, paste, and relaunch. Edit release-notes.md as needed. Did testing pass, and are the notes ready?");
  clean();
  if (git("rev-parse", "HEAD") !== head) throw new Error("HEAD changed after packaging. Rebuild from the intended release commit");
  if (!readFileSync(notesPath, "utf8").trim()) throw new Error("Release notes must not be empty");
  run(["bun", "run", "release:sparkle", output, notesPath]);
  const appcastPath = join(output, "appcast.xml");
  if (!existsSync(appcastPath)) throw new Error("Sparkle appcast was not generated");
  await confirm(`Push this commit to origin and upload Hex ${version} to a DRAFT release on salishdev/Hex?`);
  run(["git", "push", "origin", "HEAD"]);
  run(["gh", "release", "create", `v${version}`,
    join(output, `Hex-${version}.zip`), join(output, `Hex-${version}.dmg`), join(output, "SHA256SUMS"), appcastPath,
    "--repo", "salishdev/Hex", "--target", head, "--draft", "--title", `Hex ${version}`, "--notes-file", notesPath]);
  log(`Draft uploaded. Review it at https://github.com/salishdev/Hex/releases and publish when ready. Publishing triggers deployment of the signed update appcast to GitHub Pages.`);
}

if (import.meta.main) {
  if (process.argv.includes("--help")) console.log(help);
  else {
    let prompts: ReturnType<typeof createInterface> | undefined;
    try {
      const options = parseOptions(process.argv.slice(2));
      if (!process.stdin.isTTY) throw new Error("Run release:run in an interactive terminal; use --help for options");
      const root = execFileSync("git", ["rev-parse", "--show-toplevel"], { encoding: "utf8" }).trim();
      prompts = createInterface({ input: process.stdin, output: process.stdout });
      await runRelease(root, options, process.env, {
        run: (args, capture = false, cwd = root) => {
          return execFileSync(args[0]!, args.slice(1), { cwd, encoding: "utf8", stdio: capture ? ["ignore", "pipe", "inherit"] : "inherit" }) ?? "";
        },
        confirm: async message => {
          if ((await prompts!.question(`${message} [y/N] `)).trim().toLowerCase() !== "y") {
            throw new Error("Stopped. Changes and artifacts are retained; inspect them before resuming with --from");
          }
        },
        log: console.log,
      });
    } catch (error) { console.error(error instanceof Error ? error.message : error); process.exitCode = 1; }
    finally { prompts?.close(); }
  }
}
