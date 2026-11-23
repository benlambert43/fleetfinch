import {
  type BuildToolsStatus,
  type PasswordAccount,
  type SystemPackage,
  systemPackages,
} from "@/buildTools.ts";
import { isExecutable } from "@/main/buildTools/paths.ts";
import {
  type Log,
  PasswordNeeded,
  type ProcessResult,
  type Report,
  type StepOptions,
  runProcess,
  StepError,
} from "@/main/buildTools/process.ts";

const dpkgQueryFile = "/usr/bin/dpkg-query";
const aptGetFile = "/usr/bin/apt-get";
const dpkgFile = "/usr/bin/dpkg";
const pkexecFile = "/usr/bin/pkexec";
const sudoFile = "/usr/bin/sudo";
const suFile = "/bin/su";
const scriptFile = "/usr/bin/script";
const idFile = "/usr/bin/id";
const shellFile = "/bin/sh";
const adminGroups = new Set(["sudo", "admin", "wheel"]);
const dismissedCode = 126;
const refusedCode = 127;
const wrongPassword =
  /incorrect password|no password was provided|Sorry, try again|Authentication failure/i;

function plainEnvironment(): NodeJS.ProcessEnv {
  return { ...process.env, LC_ALL: "C", LANGUAGE: "C", SHELL: shellFile };
}

function installCommand(packages: SystemPackage[], repair: boolean): string {
  return [
    "export DEBIAN_FRONTEND=noninteractive",
    ...(repair
      ? [
          `${dpkgFile} --configure -a`,
          `${aptGetFile} -o DPkg::Lock::Timeout=300 install --fix-broken --yes`,
        ]
      : []),
    `${aptGetFile} -o DPkg::Lock::Timeout=300 update`,
    `${aptGetFile} -o DPkg::Lock::Timeout=300 install --yes --no-install-recommends -- ${packages.join(" ")}`,
  ].join("; ");
}

export async function readSystemPackages(): Promise<
  BuildToolsStatus["system"]
> {
  const { output } = await runProcess(
    dpkgQueryFile,
    [
      "--show",
      "--showformat=${Package}\\t${db:Status-Status}\\n",
      ...systemPackages,
    ],
    { env: plainEnvironment(), timeoutMs: 10_000 },
  ).catch(() => ({ code: null, output: "" }));
  const installed = new Set(
    output
      .split("\n")
      .map((line) => line.split("\t"))
      .filter(([, state]) => state === "installed")
      .map(([name]) => name),
  );
  return systemPackages.map((name) => ({
    name,
    installed: installed.has(name),
  }));
}

async function passwordAccount(): Promise<PasswordAccount> {
  if (!(await isExecutable(sudoFile))) {
    return "root";
  }
  const { output } = await runProcess(idFile, ["-Gn"], {
    env: plainEnvironment(),
    timeoutMs: 10_000,
  }).catch(() => ({ code: null, output: "" }));
  return output.split(/\s+/).some((group) => adminGroups.has(group))
    ? "yours"
    : "root";
}

function asRoot(command: string, log: Log): Promise<ProcessResult> {
  return runProcess(shellFile, ["-c", command], {
    env: plainEnvironment(),
    log,
  });
}

function withPkexec(command: string, log: Log): Promise<ProcessResult> {
  return runProcess(pkexecFile, [shellFile, "-c", command], {
    env: plainEnvironment(),
    log,
  });
}

function withSudo(
  command: string,
  password: string,
  log: Log,
): Promise<ProcessResult> {
  return runProcess(
    sudoFile,
    ["-S", "-k", "-p", "", "--", shellFile, "-c", command],
    { env: plainEnvironment(), input: `${password}\n`, log },
  );
}

function withSu(
  command: string,
  password: string,
  log: Log,
): Promise<ProcessResult> {
  return runProcess(
    scriptFile,
    [
      "--quiet",
      "--return",
      "--command",
      `${suFile} root --command '${command}'`,
      "/dev/null",
    ],
    {
      env: plainEnvironment(),
      answer: { prompt: /Password:\s*$/, text: `${password}\n` },
      log,
    },
  );
}

async function runInstall(
  missing: SystemPackage[],
  { password, clean }: StepOptions,
  report: Report,
): Promise<ProcessResult> {
  const listed = missing.join(", ");
  const command = installCommand(missing, clean);
  if (process.getuid?.() === 0) {
    report.progress(`Installing ${listed}`);
    return asRoot(command, report.log);
  }
  if (password === undefined) {
    if (!(await isExecutable(pkexecFile))) {
      throw new PasswordNeeded(await passwordAccount(), missing);
    }
    report.progress(`Asking for permission to install ${listed}`);
    const result = await withPkexec(command, report.log);
    if (result.code === dismissedCode) {
      throw new StepError(
        `Installing ${listed} was cancelled in the system's password dialog. Press the button to try again.`,
        result.output,
      );
    }
    if (result.code === refusedCode) {
      throw new PasswordNeeded(
        await passwordAccount(),
        missing,
        "The system's password dialog could not give permission, so enter the password here instead.",
      );
    }
    return result;
  }
  const account = await passwordAccount();
  report.progress(`Installing ${listed}`);
  const result =
    account === "yours"
      ? await withSudo(command, password, report.log)
      : await withSu(command, password, report.log);
  if (result.code !== 0 && wrongPassword.test(result.output)) {
    throw new PasswordNeeded(
      account,
      missing,
      "That password was not accepted. Try again.",
    );
  }
  return result;
}

export async function installSystemPackages(
  report: Report,
  options: StepOptions,
): Promise<void> {
  const missing = (await readSystemPackages())
    .filter((item) => !item.installed)
    .map((item) => item.name);
  if (missing.length === 0) {
    report.progress("All of them are installed", 1);
    return;
  }
  const listed = missing.join(", ");
  if (!(await isExecutable(aptGetFile))) {
    throw new StepError(
      `This computer has no apt-get to install ${listed} with. FleetFinch Developer needs a Debian-based system, such as Debian or Ubuntu.`,
    );
  }
  if (options.clean) {
    report.progress("Repairing apt and dpkg before installing again");
  }
  const { code, output } = await runInstall(missing, options, report);
  if (code !== 0) {
    throw new StepError(`apt-get could not install ${listed}.`, output);
  }
  const still = (await readSystemPackages()).filter((item) => !item.installed);
  if (still.length > 0) {
    throw new StepError(
      `apt-get finished, but ${still.map((item) => item.name).join(", ")} is still not installed.`,
      output,
    );
  }
}
