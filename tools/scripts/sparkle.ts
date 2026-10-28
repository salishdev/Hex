#!/usr/bin/env bun
import { execFileSync } from "node:child_process";
import { copyFileSync, existsSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";

export const sparkleAccount = "com.salishdev.Hex";
export const feedURL = "https://salishdev.github.io/Hex/appcast.xml";
const publicKey = "aBpEf9RmpBzGgBZTxyZDxmmBo1WrmBLskHfl6SibteQ=";

export function toolPath(root: string, name: string): string {
  const candidates = [process.env.SPARKLE_BIN_DIR, join(root, "build/SourcePackages/artifacts/sparkle/Sparkle/bin"), join(root, "build/DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin")];
  const directory = candidates.find(path => path && existsSync(join(path, name)));
  if (!directory) throw new Error(`Sparkle tool ${name} not found. Package the app first or set SPARKLE_BIN_DIR to the resolved package's bin directory.`);
  return join(directory, name);
}

export function notesHTML(notes: string): string {
  // Treat release notes as text, so authored HTML/scripts never become active content.
  const escape = (text: string) => text.replaceAll("&", "&amp;").replaceAll("<", "&lt;").replaceAll(">", "&gt;").replaceAll('"', "&quot;");
  return notes.split("\n").filter(line => !line.includes("<!-- hex-release-commit:")).map(line => {
    const heading = /^(#{1,6}) (.*)$/.exec(line);
    if (heading) return `<h${heading[1]!.length}>${escape(heading[2]!)}</h${heading[1]!.length}>`;
    if (line.startsWith("- ")) return `<p>• ${escape(line.slice(2))}</p>`;
    return line.trim() ? `<p>${escape(line)}</p>` : "";
  }).join("\n");
}

export function generateSparkle(root: string, output: string, notesPath: string): string {
  const source = JSON.parse(readFileSync(join(output, "release-source.json"), "utf8"));
  const { version, build } = source;
  if (!/^\d+\.\d+\.\d+$/.test(version) || !/^[1-9]\d*$/.test(build)) throw new Error("Invalid release-source.json version/build");
  const app = join(output, "export/Hex.app/Contents/Info.plist");
  const plist = (key: string) => execFileSync("/usr/libexec/PlistBuddy", ["-c", `Print :${key}`, app], { encoding: "utf8" }).trim();
  if (plist("CFBundleShortVersionString") !== version || plist("CFBundleVersion") !== build || plist("CFBundleIdentifier") !== "com.salishdev.Hex") {
    throw new Error("Exported app identity/version/build does not match release-source.json");
  }
  if (plist("SUFeedURL") !== feedURL || plist("SUPublicEDKey") !== publicKey) throw new Error("Exported app does not contain this fork's Sparkle feed and public key");
  const foundKey = execFileSync(toolPath(root, "generate_keys"), ["--account", sparkleAccount, "-p"], { encoding: "utf8" }).trim();
  if (foundKey !== publicKey) throw new Error("Keychain Sparkle public key does not match the app");
  execFileSync("shasum", ["-a", "256", "-c", "SHA256SUMS", "--status"], { cwd: output });
  const archiveDirectory = join(output, "sparkle");
  mkdirSync(archiveDirectory, { recursive: true });
  copyFileSync(join(output, `Hex-${version}.dmg`), join(archiveDirectory, `Hex-${version}.dmg`));
  writeFileSync(join(archiveDirectory, `Hex-${version}.html`), notesHTML(readFileSync(notesPath, "utf8")));
  // Start fresh so edits to notes on a resumed run are reflected in the new feed.
  const appcast = join(output, "appcast.xml");
  rmSync(appcast, { force: true });
  execFileSync(toolPath(root, "generate_appcast"), [
    "--account", sparkleAccount, "--maximum-deltas", "0", "--embed-release-notes",
    "--download-url-prefix", `https://github.com/salishdev/Hex/releases/download/v${version}/`,
    "--link", "https://github.com/salishdev/Hex/releases", "-o", appcast, archiveDirectory,
  ], { stdio: "inherit" });
  return appcast;
}

if (import.meta.main) {
  try {
    const args = process.argv.slice(2);
    if (args.length !== 2) throw new Error("Usage: bun run release:sparkle <artifact-directory> <release-notes-file>");
    const root = resolve(dirname(import.meta.path), "../..");
    console.log(generateSparkle(root, resolve(args[0]!), resolve(args[1]!)));
  } catch (error) { console.error(error instanceof Error ? error.message : error); process.exitCode = 1; }
}
