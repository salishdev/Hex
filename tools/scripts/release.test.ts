import { afterEach, expect, test } from "bun:test";
import { execFileSync } from "node:child_process";
import { mkdtempSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { parseOptions, releaseNotes, runRelease, type ReleaseIO } from "./release";

const roots: string[] = [];
afterEach(() => roots.splice(0).forEach(root => rmSync(root, { recursive: true, force: true })));
const env = { TEAM_ID: "WW59U84Z7X", BUILD_NUMBER: "93", NOTARY_PROFILE: "test-profile" };

function fixture() {
  const root = mkdtempSync(join(tmpdir(), "hex-guided-release-"));
  roots.push(root);
  const git = (...args: string[]) => execFileSync("git", args, { cwd: root, encoding: "utf8" }).trim();
  git("init", "-q");
  git("config", "user.name", "Release Test");
  git("config", "user.email", "release@example.invalid");
  git("config", "commit.gpgsign", "false");
  mkdirSync(join(root, ".changeset"));
  mkdirSync(join(root, "Hex/Resources"), { recursive: true });
  writeFileSync(join(root, ".gitignore"), "build/\n");
  writeFileSync(join(root, "package.json"), '{"name":"hex-app","version":"0.9.0"}\n');
  const changelog = "# Changelog\n\n## 0.9.0\n\n### Minor Changes\n\n- New feature (#12)\n\n## 0.8.5\n\n- Old feature\n";
  writeFileSync(join(root, "CHANGELOG.md"), changelog);
  writeFileSync(join(root, "Hex/Resources/changelog.md"), changelog);
  git("add", ".");
  git("commit", "-qm", "Prepared release");
  const calls: string[][] = [];
  const prompts: string[] = [];
  const output = join(root, "build/releases/0.9.0-93");
  const artifacts = () => {
    mkdirSync(output, { recursive: true });
    writeFileSync(join(output, "Hex-0.9.0.zip"), "zip");
    writeFileSync(join(output, "Hex-0.9.0.dmg"), "dmg");
    writeFileSync(join(output, "SHA256SUMS"), execFileSync("shasum", ["-a", "256", "Hex-0.9.0.zip", "Hex-0.9.0.dmg"], { cwd: output, encoding: "utf8" }));
  };
  const io: ReleaseIO = {
    run: args => {
      calls.push(args);
      if (args[0] === "git" && !["push", "fetch"].includes(args[1]!)) return git(...args.slice(1));
      if (args[0] === "shasum") return execFileSync("shasum", args.slice(1), { cwd: output, encoding: "utf8" });
      if (args.join(" ") === "bun run release") artifacts();
      if (args.slice(0, 3).join(" ") === "bun run release:sparkle") writeFileSync(join(output, "appcast.xml"), "test feed");
      return "";
    },
    confirm: async message => { prompts.push(message); },
    log: () => {},
  };
  return { root, git, calls, prompts, output, artifacts, io };
}

test("packages a prepared commit and uploads only a draft with that commit and release-specific notes", async () => {
  const repo = fixture();
  await runRelease(repo.root, parseOptions(["--from", "package"]), env, repo.io);
  const upload = repo.calls.find(args => args[0] === "gh" && args[1] === "release")!;
  expect(upload).toContain("--draft");
  expect(upload).toContain(repo.git("rev-parse", "HEAD"));
  expect(upload).toContain("v0.9.0");
  expect(upload).toContain(join(repo.output, "appcast.xml"));
  expect(repo.prompts).toHaveLength(2);
  expect(repo.calls.some(args => args.join(" ") === "git push origin HEAD")).toBe(true);
  expect(readFileSync(join(repo.output, "release-notes.md"), "utf8")).toContain("New feature (#12)");
  expect(readFileSync(join(repo.output, "release-notes.md"), "utf8")).not.toContain("Old feature");
});

test("stopping at testing leaves artifacts and never pushes or uploads", async () => {
  const repo = fixture();
  repo.io.confirm = async () => { throw new Error("Stopped"); };
  await expect(runRelease(repo.root, parseOptions(["--from", "package"]), env, repo.io)).rejects.toThrow("Stopped");
  expect(repo.calls.some(args => args.includes("push") || args[0] === "gh")).toBe(false);
  expect(readFileSync(join(repo.output, "release-source.json"), "utf8")).toContain(repo.git("rev-parse", "HEAD"));
});

test("full guide confirms the version plan and creates a release commit before packaging", async () => {
  const repo = fixture();
  writeFileSync(join(repo.root, "package.json"), '{"name":"hex-app","version":"0.8.5"}\n');
  const fragment = join(repo.root, ".changeset/feature.md");
  writeFileSync(fragment, '---\n"hex-app": minor\n---\n\nNew feature (#12)\n');
  repo.git("add", ".");
  repo.git("commit", "-qm", "Feature with changeset");
  const originalRun = repo.io.run;
  repo.io.run = (args, capture, cwd) => {
    if (args.join(" ") === "bun run changeset:version") {
      // Simulate Changesets without processing any real repository fragments.
      writeFileSync(join(repo.root, "package.json"), '{"name":"hex-app","version":"0.9.0"}\n');
      rmSync(fragment);
    }
    return originalRun(args, capture, cwd);
  };
  await runRelease(repo.root, parseOptions([]), env, repo.io);
  expect(repo.git("log", "-1", "--format=%s")).toBe("Prepare Hex 0.9.0 release");
  expect(repo.git("status", "--porcelain")).toBe("");
  expect(repo.calls.some(args => args.join(" ") === "bun run release:prepare --write")).toBe(true);
  expect(repo.calls.some(args => args.join(" ") === "bun run test:core")).toBe(true);
  expect(repo.prompts).toHaveLength(5);
  expect(repo.prompts[1]).toContain("version plan");
  const source = JSON.parse(readFileSync(join(repo.output, "release-source.json"), "utf8"));
  expect(source.commit).toBe(repo.git("rev-parse", "HEAD"));
});

test("draft resume rejects mismatched commit and checksum corruption", async () => {
  const repo = fixture();
  repo.artifacts();
  const manifest = join(repo.output, "release-source.json");
  writeFileSync(manifest, JSON.stringify({ version: "0.9.0", build: "93", commit: "wrong" }));
  await expect(runRelease(repo.root, parseOptions(["--from", "draft"]), env, repo.io)).rejects.toThrow("do not match");
  writeFileSync(manifest, JSON.stringify({ version: "0.9.0", build: "93", commit: repo.git("rev-parse", "HEAD") }));
  writeFileSync(join(repo.output, "Hex-0.9.0.zip"), "corrupted");
  await expect(runRelease(repo.root, parseOptions(["--from", "draft"]), env, repo.io)).rejects.toThrow();
  expect(repo.prompts).toHaveLength(0);
  expect(repo.calls.some(args => args.includes("push"))).toBe(false);
});

test("dirty tree and missing signing inputs fail before any release action", async () => {
  const repo = fixture();
  await expect(runRelease(repo.root, parseOptions([]), {}, repo.io)).rejects.toThrow("TEAM_ID");
  expect(repo.calls).toHaveLength(0);
  writeFileSync(join(repo.root, "unrelated.txt"), "work");
  await expect(runRelease(repo.root, parseOptions([]), env, repo.io)).rejects.toThrow("working-tree");
  expect(repo.calls.every(args => args[0] === "git")).toBe(true);
});

test("options reject typos and conflicting ranges; notes require a version section", () => {
  expect(parseOptions(["--since", "v0.8.5", "--bump", "minor"]).preparation).toEqual(["--since", "v0.8.5", "--bump", "minor"]);
  expect(() => parseOptions(["--from", "unknown"])).toThrow("stage");
  expect(() => parseOptions(["--initial", "--since", "HEAD"])).toThrow("either");
  expect(() => parseOptions(["--from", "package", "--bump", "minor"])).toThrow("Preparation options");
  expect(() => releaseNotes("## 0.8.5\nOld", "0.9.0")).toThrow("No changelog");
});
