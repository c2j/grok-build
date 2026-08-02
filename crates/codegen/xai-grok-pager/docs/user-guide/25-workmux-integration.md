# workmux Integration

[workmux](https://github.com/raine/workmux) is a terminal multiplexer
orchestrator that pairs git worktrees with tmux windows (also supports
Zellij, Kitty, WezTerm) so you can run many AI agents in parallel without
branch-stashing or context-switching. With workmux, grok becomes one agent
among many — alongside claude, codex, gemini, opencode, and others — all
visible in a single dashboard.

This guide covers how to make grok a first-class workmux citizen: launching
grok inside worktree windows, reporting its status to the workmux dashboard
and sidebar, and using workmux commands to monitor and steer running grok
sessions.

---

## Why integrate?

Without workmux, grok already has its own internal
[Agent Dashboard](23-dashboard.md) — but that view is scoped to a single
pager process. workmux complements it by giving you a **cross-agent,
cross-process** view:

- **Status tracking** — grok's lifecycle (`working` / `waiting` / `done`)
  is reflected in the tmux window name and the workmux sidebar, alongside
  any other agents you have running.
- **Fan-out / fan-in** — use the `/worktree` and `/coordinator` skills to
  dispatch parallel tasks to multiple grok worktree agents and merge them
  back when each finishes.
- **Cross-agent commands** — `workmux send`, `workmux capture`,
  `workmux wait`, and `workmux run` work uniformly across grok and other
  supported agents.
- **Dashboard & sidebar** — `workmux dashboard` opens a TUI listing every
  active agent with git/PR status; the sidebar pins a compact agent roster
  inside any tmux window.

If you never use tmux or worktrees, you do not need this integration — grok
works unchanged.

---

## Installation

### 1. Install workmux

Install workmux separately (it is not bundled with grok):

```sh
# macOS / Linux
brew install raine/workmux/workmux
# or:
curl -fsSL https://raw.githubusercontent.com/raine/workmux/main/scripts/install.sh | bash
```

Verify:

```sh
workmux --version
```

### 2. Install the grok status hook

Copy the bundled example hook into `~/.grok/hooks/`:

```sh
mkdir -p ~/.grok/hooks/bin

# Adjust the source path if your grok checkout lives elsewhere.
SRC=crates/codegen/xai-grok-hooks/examples/hooks
cp "$SRC/workmux-status.json" ~/.grok/hooks/
cp "$SRC/bin/workmux-status.sh" ~/.grok/hooks/bin/
chmod +x ~/.grok/hooks/bin/workmux-status.sh
```

If you installed grok via the official binary (not built from source), copy
the hook contents manually from the
[examples directory](https://github.com/raine/workmux) — or wait for
`workmux setup` to learn the grok path (planned upstream).

### 3. Verify

```sh
workmux status
```

Should run cleanly (probably reporting "no agents"). Then check the hook
loads inside grok by opening the Hooks tab (`Ctrl+L` on non–VS Code family
terminals, or `/hooks` anywhere) — you should see five `workmux-status.sh`
entries under the Global source group.

---

## Usage

### Spawn a grok worktree agent

From inside a tmux session:

```sh
workmux add feat-login -a grok -P prompt.md
```

This creates a git worktree, opens a tmux window with grok running in it,
and injects the prompt. The window name shows grok's status icon live.

If `workmux setup` has not yet learned the `grok` agent name upstream, use
the explicit path form:

```sh
workmux add feat-login -a "$(command -v grok)" -P prompt.md
```

…or set `agent: grok` in `.workmux.yaml` once workmux recognizes it.

### Monitor

```sh
workmux status                 # one-shot table of all agents
workmux dashboard              # TUI: list, peek, dispatch, send
workmux wait feat-login        # block until the agent is done
workmux capture feat-login -n 50   # read the last 50 lines of output
```

### Steer

```sh
workmux send feat-login "also add a test for the empty-input case"
workmux send feat-login "/merge"   # tell the agent to merge its own branch
workmux run feat-login -- cargo test
```

### Finish

```sh
workmux merge feat-login        # merge, close window, remove worktree, delete branch
# or, after pushing and opening a PR:
workmux remove feat-login       # clean up without merging
```

For the full lifecycle (commit → rebase → merge), use the `/merge` skill
inside grok, or the `/coordinator` skill to orchestrate multiple agents.

---

## Status mapping

grok publishes its lifecycle state to workmux via a single hook script. The
mapping is fixed by the `workmux-status.json` hook file:

| grok hook event | workmux status | When it fires |
|---|---|---|
| `UserPromptSubmit` | `working` | You submit a new prompt — agent is now busy |
| `PostToolUse` | `working` | A tool call just completed — still mid-turn |
| `Notification` | `waiting` | Agent sent a notification (e.g. needs your attention) |
| `Stop` | `done` | Agent finished its turn (`reason: end_turn`) |
| `SessionEnd` | `done` | Session closed — guarantees terminal cleanup |

Notes:

- The `Stop` hook also fires once at session end with a non-`end_turn`
  reason (observe-only); the script always publishes `done`, so this is
  harmless.
- Permission prompts are handled outside the hook system, so `waiting`
  relies on the `Notification` event. If your workflow relies on
  distinguishing "needs input" precisely, see
  [Troubleshooting](#troubleshooting).

---

## Opting out

Three escape hatches, pick whichever fits:

- **Per nested agent**: set `WORKMUX_DISABLE_SET_WINDOW_STATUS=1` in the
  environment before launching grok. This is the recommended way to avoid
  clobbering a parent agent's status when one grok launches another
  (e.g. via the agent SDK).
- **Per project**: do not copy the hook into `<project>/.grok/hooks/`. The
  global hook in `~/.grok/hooks/` still applies elsewhere.
- **Globally**: remove `~/.grok/hooks/workmux-status.json`. The hook stops
  running on the next session.

The hook script itself also short-circuits when `workmux` is not on `PATH`
or when no tmux session is attached (`$TMUX` empty), so leaving the hook
installed is harmless on machines without workmux or tmux.

---

## Troubleshooting

### grok does not appear in `workmux status`

1. **Is the hook loaded?** Run `/hooks` (or `Ctrl+L` → Hooks tab) inside
   grok and confirm five `workmux-status.sh` entries are present and
   enabled under the Global source group.
2. **Is workmux on PATH inside the grok process?** Some shells strip PATH
   in non-interactive contexts. Run `command -v workmux` from a grok
   terminal session to confirm.
3. **Is `$TMUX` set?** The hook is a no-op outside tmux. workmux itself
   requires a multiplexer, so if you are not in tmux/Zellij/Kitty/WezTerm,
  workmux cannot track the agent anyway.
4. **Run the hook manually with tracing**:
   ```sh
   sh -x ~/.grok/hooks/bin/workmux-status.sh working
   ```
   Look for the `workmux set-window-status working` call and any non-zero
   exit (it should be swallowed by `|| true`).

### Status stays "working" forever

The `Stop` hook fires when the agent finishes its turn. If the status does
not flip to `done`, the hook may have failed before reaching the
`workmux set-window-status done` call. Check `/hooks` for hook-error
annotations in the scrollback, and verify `workmux set-window-status done`
works when invoked manually from the same tmux session.

### Two grok sessions clobber each other's status

The hook passes `GROK_SESSION_ID` as `WORKMUX_STATUS_INSTANCE` to keep
concurrent grok sessions distinct. If you still see collisions, ensure
both sessions were launched by a grok build that sets `GROK_SESSION_ID`
in the hook environment (all modern builds do — see
[Hooks](10-hooks.md#environment-variables)).

### workmux says "unknown agent"

This means the upstream workmux release you are using predates grok
support. Either upgrade workmux, or work around it with the explicit-path
form (`-a "$(command -v grok)"`) until the upstream PR lands.
