import fs from "node:fs";
import path from "node:path";

const root = path.resolve(import.meta.dirname, "..");
const slug = process.argv[2];

if (!slug) {
  console.error("Usage: npm run demo -- <demo-name>");
  process.exit(2);
}

const source = path.join(root, "demos", slug);
for (const file of ["lottie.json", "controls.json"]) {
  const from = path.join(source, file);
  if (!fs.existsSync(from)) {
    console.error(`Missing demo file: ${from}`);
    process.exit(1);
  }
  fs.copyFileSync(from, path.join(root, "public", file));
}

console.log(`Selected ${slug}`);
