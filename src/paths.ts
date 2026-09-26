import { dirname } from "node:path";
import { fileURLToPath } from "node:url";

/** Root of the installed toolkit (holds prompt.md, rules/, skills/, examples/). */
export const installDir = dirname(dirname(fileURLToPath(import.meta.url)));
