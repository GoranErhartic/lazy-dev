import { Spinner } from "@inkjs/ui";
import { Box, Text, useApp, useInput } from "ink";
import { useCallback, useEffect, useRef, useState } from "react";
import { readGlobalConfig, resolveApiKey, type GlobalConfig, type ModelConfig } from "../config/global.js";
import { readRepoConfig, resolveModels } from "../config/repo.js";
import { tryProjectRoot } from "../engine/git.js";
import { Header, Notice } from "./components.js";
import { Home, type HomeAction } from "./Home.js";
import { InitWizard } from "./InitWizard.js";
import { PrdChat } from "./PrdChat.js";
import { RepoBootstrap } from "./RepoBootstrap.js";
import { RunDashboard } from "./RunDashboard.js";
import { theme } from "./theme.js";

export type AppCommand = { type: "main" } | { type: "init" } | { type: "run"; feature: string; maxIterations?: number };

/** What the CLI should do after the Ink app exits. */
export type AppExit = { type: "quit" } | { type: "edit"; feature: string; root: string };

type Flash = { tone: "info" | "success" | "warn" | "error"; text: string };

type Screen =
  | { name: "loading" }
  | { name: "init"; firstRun: boolean }
  | { name: "bootstrap"; root: string }
  | { name: "home"; flash?: Flash }
  | { name: "prd" }
  | { name: "run"; feature: string }
  | { name: "fatal"; message: string; hint?: string };

interface Session {
  root: string;
  apiKey: string;
  models: ModelConfig;
  tracked: boolean;
  global?: GlobalConfig;
}

export interface AppProps {
  command: AppCommand;
  installDir: string;
  cwd?: string;
  initialFlash?: Flash;
  onExit: (exit: AppExit) => void;
}

export function App({ command, installDir, cwd, initialFlash, onExit }: AppProps) {
  const { exit } = useApp();
  const [screen, setScreen] = useState<Screen>({ name: "loading" });
  const [session, setSession] = useState<Session | undefined>();
  const controller = useRef(new AbortController());
  const [, forceRender] = useState(0);

  const leave = useCallback(
    (result: AppExit) => {
      onExit(result);
      exit();
    },
    [exit, onExit],
  );

  const freshSignal = (): AbortSignal => {
    controller.current = new AbortController();
    return controller.current.signal;
  };

  /** Works out the next screen from what is configured so far. */
  const advance = useCallback(
    async (flash?: Flash): Promise<void> => {
      if (command.type === "init") return setScreen({ name: "init", firstRun: false });
      const [key, global] = await Promise.all([resolveApiKey(), readGlobalConfig()]);
      if (!key || !global) return setScreen({ name: "init", firstRun: true });
      const root = tryProjectRoot(cwd);
      if (!root) {
        return setScreen({
          name: "fatal",
          message: "Not inside a git repository.",
          hint: "cd into the repo you want to work on and run lazydev again.",
        });
      }
      const repo = await readRepoConfig(root);
      if (!repo) {
        if (command.type === "run") return setScreen({ name: "fatal", message: "This repo is not set up yet.", hint: "Run lazydev (without arguments) here first." });
        return setScreen({ name: "bootstrap", root });
      }
      const models = await resolveModels(root);
      if (!models) return setScreen({ name: "init", firstRun: true });
      setSession({ root, apiKey: key.key, models, tracked: repo.tracked, global });
      if (command.type === "run") {
        freshSignal();
        return setScreen({ name: "run", feature: command.feature });
      }
      setScreen({ name: "home", flash: flash ?? initialFlash });
    },
    [command, cwd, initialFlash],
  );

  useEffect(() => {
    void advance().catch((error: unknown) => setScreen({ name: "fatal", message: error instanceof Error ? error.message : "Startup failed." }));
  }, [advance]);

  useInput((input, key) => {
    if (!(key.ctrl && input === "c")) return;
    const busy = screen.name === "run" || screen.name === "prd";
    if (busy && !controller.current.signal.aborted) {
      controller.current.abort();
      forceRender((value) => value + 1);
    } else {
      leave({ type: "quit" });
    }
  });

  useInput(
    (_input, key) => {
      if (key.return || key.escape) leave({ type: "quit" });
    },
    { isActive: screen.name === "fatal" },
  );

  const onHome = (action: HomeAction): void => {
    if (action.type === "quit") leave({ type: "quit" });
    else if (action.type === "edit") leave({ type: "edit", feature: action.feature, root: session!.root });
    else if (action.type === "new-prd") {
      freshSignal();
      setScreen({ name: "prd" });
    } else {
      freshSignal();
      setScreen({ name: "run", feature: action.feature });
    }
  };

  switch (screen.name) {
    case "loading":
      return (
        <Box paddingX={1}>
          <Spinner label="Starting lazydev" />
        </Box>
      );
    case "init":
      return (
        <InitWizard
          installDir={installDir}
          firstRun={screen.firstRun}
          onDone={() => (command.type === "init" ? leave({ type: "quit" }) : void advance())}
        />
      );
    case "bootstrap":
      return <RepoBootstrap root={screen.root} onDone={(text) => void advance({ tone: "success", text })} />;
    case "home":
      return <Home root={session!.root} flash={screen.flash} onAction={onHome} />;
    case "prd":
      return (
        <PrdChat
          root={session!.root}
          apiKey={session!.apiKey}
          installDir={installDir}
          model={session!.models.impl}
          tracked={session!.tracked}
          signal={controller.current.signal}
          onDone={(result) => {
            if (result.type === "run") {
              freshSignal();
              setScreen({ name: "run", feature: result.feature });
            } else setScreen({ name: "home", flash: result.flash });
          }}
        />
      );
    case "run":
      return (
        <RunDashboard
          key={screen.feature}
          root={session!.root}
          feature={screen.feature}
          apiKey={session!.apiKey}
          installDir={installDir}
          models={session!.models}
          maxIterations={(command.type === "run" ? command.maxIterations : undefined) ?? session!.global?.maxIterations}
          timeoutMs={session!.global?.timeoutMinutes ? session!.global.timeoutMinutes * 60_000 : undefined}
          signal={controller.current.signal}
          onCancelRequest={() => {
            controller.current.abort();
            forceRender((value) => value + 1);
          }}
          onExit={() => (command.type === "run" ? leave({ type: "quit" }) : setScreen({ name: "home" }))}
        />
      );
    case "fatal":
      return (
        <Box flexDirection="column">
          <Header />
          <Notice tone="error">{screen.message}</Notice>
          {screen.hint ? (
            <Box paddingX={1}>
              <Text color={theme.muted}>{screen.hint}</Text>
            </Box>
          ) : null}
        </Box>
      );
  }
}
