interface CommandOptions {
  cwd?: string;
  encoding: "utf8";
  timeout: number;
}

export type UpdatePreflightCommandRunner = (
  file: string,
  args: string[],
  options: CommandOptions,
) => Promise<{ stdout: string; stderr: string }>;

export async function assertGitCheckoutClean(
  packageDir: string,
  runCommand: UpdatePreflightCommandRunner,
): Promise<void> {
  const { stdout } = await runCommand(
    "git",
    ["status", "--porcelain=v1", "--untracked-files=no"],
    { cwd: packageDir, encoding: "utf8", timeout: 10_000 },
  );
  const lines = stdout
    .split("\n")
    .map((line) => line.trimEnd())
    .filter(Boolean);
  const changedPaths = lines
    .slice(0, 5)
    .map((line) => line.length > 3 ? line.slice(3) : line);
  if (changedPaths.length === 0) {
    return;
  }
  const suffix = lines.length > changedPaths.length ? ", …" : "";
  throw new Error(
    `Git update blocked by tracked local changes: ${changedPaths.join(", ")}${suffix}. Restore or commit them before retrying; Sidemesh did not stop the daemon or discard any files.`,
  );
}
