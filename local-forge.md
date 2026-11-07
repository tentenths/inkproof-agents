# Local forge redesign: trial results

The redesign under consideration moves the agents' work off GitHub. In outline:

- **Forge.** Forgejo runs locally in compose; GitHub serves only as a push mirror, for backup and distribution.
- **Runs.** Each run is a fresh, headless Claude conversation, started by a dispatcher that receives Forgejo's webhooks.
- **Your view.** You watch and steer agents from VS Code and the Claude extension, without tmux.

Two throwaway trials on 2026-11-07 tested whether this can work. The trial files have been deleted; this note keeps their results.

## Trial 1: headless runs and the VS Code extension

One container held a throwaway Git repository and managed settings that denied `git tag` and `curl`. A small runner started `claude -p --output-format stream-json` with a name and session ID, and turned the stream into a Markdown log as it ran.

### Results (2026-11-07, Claude Code 2.1.319)

| Check | Result |
|---|---|
| 1. One login | Pass. The terminal used the extension's login. |
| 2. Live log | Pass. `.runs/current.md` updated in its tab during the run, and was readable. |
| 3. Session list | Pass with a workaround. The extension lists sessions by the entrypoint their transcript records; headless runs record `sdk-cli` and are hidden. Rewriting it to `claude-vscode` after the run made the run appear, and resuming it answered from the run's history. Setting `CLAUDE_CODE_ENTRYPOINT` doesn't help, because `-p` overrides it. `claude --resume <id>` in a terminal does resume it, but doesn't show the earlier history. |
| 4. Policy | Pass. The managed deny rule refused `git tag x` in the resumed session, and the managed hooks fired in headless runs, terminal sessions and the extension. The hooks' `CLAUDE_CODE_ENTRYPOINT` tells the three apart: `sdk-cli`, `cli` and `claude-vscode`. |
| 5. Taking over | Pass, with the same workaround. A run interrupted with Ctrl-C resumed in the extension with its history intact, and carried on from where it stopped. |
| 6. Spotting a person | Processes are no use. Each extension conversation keeps a Claude process until the window closes, so a process doesn't mean anyone is there. Use the hooks instead: a prompt with entrypoint `claude-vscode` or `cli` comes from a person. |
| 7. Remote Control | Skipped; not needed if VS Code works. |

What this means for the redesign:

- The runner rewrites the entrypoint in a run's transcript when the run ends, so the run shows up in the extension. This depends on a transcript detail that a Claude Code update could change. The runner should check that the rewrite matched, and say so if it didn't: a run that doesn't show up has lost nothing, it just has to be resumed by ID.
- The runner yields to a person based on the hooks, not on processes. It does so while a person's session is mid-turn, or has sent a prompt in the last few minutes.

## Trial 2: Forgejo

Forgejo 17 ran with an Actions runner (using a separate Docker engine for jobs), a webhook logger and a tools container that acted as the human (`paul`, admin) and two agents (`core`, `coordinator`). It had two repositories:

- `core`, a tiny Lean package with `API.lock`, `CODEOWNERS` and a `lake build` workflow;
- `consumer`, which required `core` by a `github.com` URL.

`core`'s `main` was protected as follows:

- pushes from `paul` only;
- one approval from `coordinator` or `paul`;
- the `checks*` statuses required;
- merging blocked while an official review request is pending;
- dismissal of stale approvals;
- `v*` tags pushed by `paul` only.

### Results (2026-11-07, Forgejo 17.0.1, runner 13.2.1, tea 0.16.0)

| Check | Result |
|---|---|
| 1. Approvals | Pass. `core` can't merge without the coordinator's approval and passing CI, and can't approve its own pull request. |
| 2. `API.lock` | Pass. `CODEOWNERS` requested `paul`'s review automatically, and "block on official review requests" kept the pull request from merging on the coordinator's approval alone. It merged once `paul` approved too. |
| 2b. Protected files | Not usable. With `API.lock` protected, no one could merge the pull request, `paul` included ("Changed protected files"). |
| 3. Spoofing | As expected, `core` could overwrite both failed CI statuses with `success` and merge a broken build. A first attempt straight after the statuses were posted was refused only because Forgejo hadn't caught up. |
| 4. Auto-merge | Pass. A merge `core` scheduled waited, with checks passed, until the coordinator approved, then merged within 10 seconds. |
| 5. Tags | Pass. Only `paul` can push `v*` tags. |
| 6. Webhooks | Pass. Issues opened and closed, label changes, comments, pull requests opened and closed, review requests, approvals, pushes and branch creation all arrived. No event for a finished CI run was subscribed; still to check. |
| 7. CI | Pass. `lake build` runs on every push and pull request, posting `checks / build (push)` and `checks / build (pull_request)`. |
| 8. Lake | Pass. `consumer` fetched `core` from Forgejo through the `insteadOf` rewrite, and `lake-manifest.json` kept the `github.com` URL. |
| 9. `tea` | Pass. It covers issues, labels, comments, pull requests and listing, and `tea api` covers the rest. `tea api` is as powerful as `gh api`. |
| 10. Mirror | Not run. |

What this means for the redesign:

- Approvals are the gate, as on GitHub. Whoever approves, the coordinator or a gatekeeper, must confirm CI from the Actions run (`/repos/{owner}/{repo}/actions/runs`), which agents can't post, never from commit statuses.
- `API.lock` at level 2 uses `CODEOWNERS` plus "block on official review requests", with the human on the approvals list.
- Agents can schedule "merge when checks succeed" and leave it; it waits for approval.
- Before relying on it: whether Forgejo sends a webhook when a CI run fails, so the dispatcher can wake an agent whose checks failed. If it doesn't, the dispatcher can poll Actions runs instead.
