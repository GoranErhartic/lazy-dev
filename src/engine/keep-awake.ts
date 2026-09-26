import { spawn } from "node:child_process";

/** Prevents idle sleep on macOS while this process is alive; a no-op elsewhere. */
export function keepAwake(): () => void {
  if (process.platform !== "darwin") return () => undefined;
  try {
    const child = spawn("caffeinate", ["-i", "-w", String(process.pid)], { stdio: "ignore" });
    child.on("error", () => undefined);
    child.unref();
    return () => {
      child.kill();
    };
  } catch {
    return () => undefined;
  }
}
