import { copyFileSync } from "node:fs";

copyFileSync("CHANGELOG.md", "Hex/Resources/changelog.md");
console.log("Synced the in-app changelog.");
