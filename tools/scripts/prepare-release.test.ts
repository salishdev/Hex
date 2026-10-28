import { afterEach, expect, test } from "bun:test";
import { execFileSync } from "node:child_process";
import { mkdtempSync, mkdirSync, readFileSync, readdirSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { prepareRelease } from "./prepare-release";

const repositories: string[] = [];
afterEach(() => repositories.splice(0).forEach(path => rmSync(path, { recursive: true, force: true })));

function fixture(tag = true) {
  const root = mkdtempSync(join(tmpdir(), "hex-release-test-"));
  repositories.push(root);
  const git = (...args: string[]) => execFileSync("git", ["-C", root, ...args], { encoding: "utf8" }).trim();
  git("init", "-q");
  git("config", "user.name", "Release Test");
  git("config", "user.email", "release@example.invalid");
  git("config", "commit.gpgsign", "false");
  git("config", "tag.gpgsign", "false");
  mkdirSync(join(root, ".changeset"));
  const write = (path: string, contents: string) => writeFileSync(join(root, path), contents);
  const commit = (subject: string) => { git("add", "."); git("commit", "-qm", subject); return git("rev-parse", "HEAD"); };
  write("package.json", '{"name":"hex-app","version":"1.0.0","private":true}');
  write(".gitignore", "build/\n");
  write(".changeset/README.md", "Instructions");
  commit("Initial");
  if (tag) git("tag", "v1.0.0");
  return { root, git, write, commit };
}

test("defaults to stable tag; reports all commits and drafts only unassociated changes", () => {
  const repo = fixture();
  repo.write("feature.swift", "feature");
  repo.write(".changeset/feature.md", '---\n"hex-app": minor\n---\n\nAdd a feature (#12)\n');
  repo.commit("Add a feature (#12)");
  repo.git("tag", "v1.1.0-beta.1");
  repo.write("fix.swift", "fix");
  const hash = repo.commit("Fix paste timing (#13)");
  const originalPackage = readFileSync(join(repo.root, "package.json"), "utf8");
  const originalHead = repo.git("rev-parse", "HEAD");
  prepareRelease(repo.root, []);
  expect(readdirSync(join(repo.root, ".changeset"))).toHaveLength(2);
  let report = readFileSync(join(repo.root, "build/release-preparation.md"), "utf8");
  expect(report).toContain("Base: v1.0.0");
  expect(report).toContain("Add a feature (#12)");
  expect(report).toContain("without association: 1");
  prepareRelease(repo.root, ["--write", "--bump", "minor"]);
  const draftName = readdirSync(join(repo.root, ".changeset")).find(name => name.startsWith("release-draft-"))!;
  const draft = readFileSync(join(repo.root, ".changeset", draftName), "utf8");
  expect(draft).toContain('"hex-app": minor');
  expect(draft).toContain("Fix paste timing (#13)");
  expect(draft).toContain(hash);
  expect(draft).not.toContain("Add a feature");
  prepareRelease(repo.root, ["--write"]);
  expect(readdirSync(join(repo.root, ".changeset"))).toHaveLength(3);
  report = readFileSync(join(repo.root, "build/release-preparation.md"), "utf8");
  expect(report).toContain("Previously drafted");
  expect(report).toContain("without association: 0");
  expect(readFileSync(join(repo.root, "package.json"), "utf8")).toBe(originalPackage);
  expect(repo.git("rev-parse", "HEAD")).toBe(originalHead);
});

test("requires explicit initial mode without a release tag; accepts explicit ancestor", () => {
  const repo = fixture(false);
  expect(() => prepareRelease(repo.root, [])).toThrow("No reachable stable release tag");
  prepareRelease(repo.root, ["--initial"]);
  expect(readFileSync(join(repo.root, "build/release-preparation.md"), "utf8")).toContain("Base: all history");
  prepareRelease(repo.root, ["--since", "HEAD"]);
  expect(readFileSync(join(repo.root, "build/release-preparation.md"), "utf8")).toContain("Commits: 0");
  expect(() => prepareRelease(repo.root, ["--initial", "--since", "HEAD"])).toThrow("either");
  expect(() => prepareRelease(repo.root, ["--bump", "invalid"])).toThrow("--bump");
  expect(() => prepareRelease(repo.root, ["--since", "--write"])).toThrow("requires a ref");
});

test("a deleted changeset does not hide a commit; later commits extend the draft", () => {
  const repo = fixture();
  repo.write(".changeset/old.md", '---\n"hex-app": patch\n---\n\nOld summary\n');
  repo.commit("Original implementation");
  rmSync(join(repo.root, ".changeset/old.md"));
  repo.commit("Replace implementation");
  prepareRelease(repo.root, ["--write"]);
  expect(readFileSync(join(repo.root, "build/release-preparation.md"), "utf8")).toContain("without association: 2");
  repo.write("new.swift", "new");
  repo.commit("New change");
  prepareRelease(repo.root, ["--write"]);
  const drafts = readdirSync(join(repo.root, ".changeset")).filter(name => name.startsWith("release-draft-"));
  expect(drafts).toHaveLength(2);
  const newer = drafts.map(name => readFileSync(join(repo.root, ".changeset", name), "utf8")).find(text => text.includes("New change"))!;
  expect(newer).not.toContain("Original implementation");
});

test("rejects shallow history and non-ancestor baselines", () => {
  const repo = fixture();
  repo.git("checkout", "-qb", "other");
  repo.write("other.swift", "other");
  const other = repo.commit("Other branch");
  repo.git("checkout", "-q", "-");
  expect(() => prepareRelease(repo.root, ["--since", other])).toThrow("ancestor of HEAD");
  const shallow = mkdtempSync(join(tmpdir(), "hex-release-shallow-"));
  repositories.push(shallow);
  execFileSync("git", ["clone", "-q", "--depth=1", `file://${repo.root}`, shallow]);
  expect(() => prepareRelease(shallow, [])).toThrow("Full history is required");
});
