#!/usr/bin/env bun
import { execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import { mkdirSync, readFileSync, readdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";

const help = `Usage: bun run release:prepare [--since <ref> | --initial] [--write] [--bump patch|minor|major]

Default: review non-merge commits since the nearest reachable stable vX.Y.Z tag.
--since     Use an explicit ancestor tag or commit instead.
--initial   Review all history (for a repository without a release tag).
--write     Draft a changeset for commits without an associated pending changeset.
--bump      Bump for the generated draft (default: patch).

Writes build/release-preparation.md. Never versions, commits, tags, or publishes.`;

export function prepareRelease(cwd: string, args: string[]): string {
  let since: string | undefined;
  let initial = false;
  let write = false;
  let bump = "patch";
  for (let i = 0; i < args.length; i++) {
    switch (args[i]) {
      case "--since": since = args[++i]; if (!since || since.startsWith("-")) throw new Error("--since requires a ref"); break;
      case "--initial": initial = true; break;
      case "--write": write = true; break;
      case "--bump": bump = args[++i] ?? ""; break;
      default: throw new Error(`Unknown argument: ${args[i]}\n${help}`);
    }
  }
  if (!["patch", "minor", "major"].includes(bump)) throw new Error("--bump must be patch, minor, or major");
  if (since && initial) throw new Error("Use either --since or --initial");
  const git = (...params: string[]) => execFileSync("git", ["-C", cwd, ...params], { encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] }).trim();
  const root = git("rev-parse", "--show-toplevel");
  const head = git("rev-parse", "HEAD");
  if (git("rev-parse", "--is-shallow-repository") === "true") {
    throw new Error("Full history is required. Fetch history and release tags first (git fetch --unshallow --tags).");
  }
  if (!since && !initial) {
    const tags = git("tag", "--merged", "HEAD").split("\n").filter(tag => /^v\d+\.\d+\.\d+$/.test(tag));
    if (!tags.length) throw new Error("No reachable stable release tag. Fetch tags, use --since <ref>, or explicitly use --initial.");
    since = git("describe", "--tags", "--abbrev=0", ...tags.flatMap(tag => ["--match", tag]), "HEAD");
  }
  const base = since ? git("rev-parse", "--verify", "--end-of-options", `${since}^{commit}`) : undefined;
  if (base) {
    try { git("merge-base", "--is-ancestor", base, head); }
    catch { throw new Error("--since must resolve to an ancestor of HEAD"); }
  }
  const range = base ? `${base}..${head}` : head;
  const packageName = JSON.parse(readFileSync(join(root, "package.json"), "utf8")).name as string;
  const directory = join(root, ".changeset");
  const pending = readdirSync(directory).filter(name => name.endsWith(".md") && name !== "README.md")
    .map(name => ({ name, text: readFileSync(join(directory, name), "utf8") }));
  // Generated drafts cover only their recorded commits, not new code committed alongside them.
  const pendingNames = new Set(pending.filter(file => !file.text.includes("<!-- hex-release-commit:")).map(file => `.changeset/${file.name}`));
  const recorded = new Set(pending.flatMap(file => [...file.text.matchAll(/<!-- hex-release-commit: ([a-f0-9]{40,64}) -->/g)].map(match => match[1])));
  const log = git("log", "--reverse", "--no-merges", "--format=%H%x09%s", range);
  const commits = log ? log.split("\n").map(line => {
    const [hash, ...subject] = line.split("\t");
    const associated = git("diff-tree", "--root", "--no-commit-id", "--name-only", "-r", hash!, "--", ".changeset")
      .split("\n").filter(name => pendingNames.has(name));
    return { hash: hash!, subject: subject.join("\t"), associated, recorded: recorded.has(hash!) };
  }) : [];
  const missing = commits.filter(commit => !commit.recorded && !commit.associated.length);
  let created: string | undefined;
  if (write && missing.length) {
    const id = createHash("sha256").update(missing.map(commit => commit.hash).join("\n")).digest("hex").slice(0, 16);
    created = `.changeset/release-draft-${id}.md`;
    const summary = missing.map(commit => `- ${commit.subject}\n  <!-- hex-release-commit: ${commit.hash} -->`).join("\n");
    writeFileSync(join(root, created), `---\n${JSON.stringify(packageName)}: ${bump}\n---\n\n${summary}\n`, { flag: "wx" });
  }
  const escape = (text: string) => text.replaceAll("|", "\\|").replaceAll("<", "&lt;").replaceAll(">", "&gt;");
  const report = [
    "# Release preparation", "",
    `Base: ${since ?? "all history"}${base ? ` (${base})` : ""}`, `Head: ${head}`, "",
    ...(git("status", "--porcelain") ? ["Working tree has uncommitted changes. Only committed history is listed; pending changesets are read from the working tree.", ""] : []),
    "Local tags are used; fetch release tags before preparing a release. Prerelease tags and merge commits are excluded.", "",
    "## Pending changesets", "",
    ...pending.flatMap(file => [`### ${file.name}`, "", file.text.trim(), ""]),
    ...(pending.length ? [] : ["None.", ""]),
    "## Commit review", "",
    "Association only means a commit touched a currently pending changeset; it does not prove that the summary covers every change. Commits with separately authored changesets may appear unassociated. Review every commit, including internal maintenance, before finalizing notes.", "",
    "| Commit | Subject | Changeset association |", "| --- | --- | --- |",
    ...commits.map(commit => `| ${commit.hash.slice(0, 10)} | ${escape(commit.subject)} | ${commit.recorded ? "Previously drafted" : commit.associated.length ? commit.associated.map(escape).join(", ") : "Needs review"} |`), "",
    `Commits: ${commits.length}; without association: ${missing.length}.`, "",
    ...(created ? [`Draft created: ${created} (${bump}).`, ""] : []),
    "## Next steps", "",
    ...(missing.length && !write ? ["Run `bun run release:prepare --write` with the same range options to draft the unassociated commits. Use `--bump minor` or `--bump major` when appropriate.", ""] : []),
    "Edit generated bullets into user-facing summaries, remove maintenance-only notes, deduplicate against existing changesets, and check issue/PR references and bump types. Keep provenance comments to avoid drafting the same commits again. Commit association is a review aid, not a semantic coverage check.", "",
    "The release maintainer then runs `bun run changeset:status`, reviews the plan, runs `bun run changeset:version` and `bun run sync-changelog`, reviews and commits the version/changelog changes, and packages the release. This command never processes changesets or publishes anything.", "",
  ].join("\n");
  const output = join(root, "build", "release-preparation.md");
  mkdirSync(join(root, "build"), { recursive: true });
  writeFileSync(output, report);
  return `Review: ${output}\n${commits.length} commits; ${pending.length} existing changesets; ${missing.length} commits without association.${created ? `\nCreated ${created}; review and edit before versioning.` : ""}`;
}

if (import.meta.main) {
  if (process.argv.includes("--help")) console.log(help);
  else {
    try { console.log(prepareRelease(process.cwd(), process.argv.slice(2))); }
    catch (error) { console.error(error instanceof Error ? error.message : error); process.exitCode = 1; }
  }
}
