// Fresh clone: the real persona files are gitignored, so seed them from the
// starter examples. Never overwrites a file that exists.
import { copyFileSync, existsSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const lib = join(dirname(fileURLToPath(import.meta.url)), "..", "src", "lib");
for (const name of ["personalities", "jessicaDeck"]) {
    const real = join(lib, `${name}.ts`);
    if (existsSync(real)) continue;
    copyFileSync(join(lib, `${name}.example.ts`), real);
    console.log(`aarc: created src/lib/${name}.ts from the starter example (make it yours with the aarc-bootstrap skill)`);
}
