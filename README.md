# Inkproof agents: Docker Compose starter kit

One sandboxed container per Claude Code agent. Each agent clones its own
GitHub repository, works with full git, opens pull requests, and files
requests to other libraries as GitHub issues. What it can write is limited by
per-agent tokens and enforced by GitHub rulesets; all network traffic goes
through an allowlisting proxy.

The kit is set up for four agents in the `tentenths` organisation:

| Agent | Repository |
| --- | --- |
| `coordinator` | `inkproof-coordination` |
| `core` (Chart.Core) | `inkproof-core` |
| `scale` (Chart.Scale) | `inkproof-scale` |
| `consumer-metrics` (simulated consumer) | `inkproof-consumer-metrics` |

Every repository in the project starts with `inkproof-` (`REPO_PREFIX`), which
keeps it separate from the organisation's other work.

## Layout

```
compose.yaml                 proxy + one service per agent
.env.example                 organisation, repo prefix, machine user, your username, UID/GID
secrets/<agent>/             write-token and read-token files (never committed)
docker/agent/                agent image and the policy baked into it
  Dockerfile
  managed-settings.json      permissions + Stop hook (agents cannot edit)
  PROTOCOL.md                shared rules: trust, git, requests, done
  check-inbox.sh             Stop hook: keep working while requests are untriaged
  watch-work, agent-run      start a session when there is work; end it when idle
  activity-hook, run-status  record busy/idle for watch-work; summary for status.sh
  git-credential-agent       own repo -> write token, others -> read token
  gh-agent                   same choice for the GitHub CLI
  gitconfig, agent-init      git setup; clone own repo on first start
docker/proxy/                egress proxy (squid) and domain allowlist
roles/<agent>.md             per-agent role, mounted as the managed CLAUDE.md
templates/repo/              copy into every repository: CLAUDE.md, CI, pin
                             check, request issue template, CODEOWNERS
templates/rulesets/          rulesets applied by scripts/setup-repo.sh
.devcontainer/<agent>/       one devcontainer.json per agent, for VS Code
control/                     pause state, mounted read-only into agents (not committed)
scripts/                     up, agent, setup-repo, status, release, pause, resume
```

## How the boundaries are enforced

| Rule | Mechanism |
| --- | --- |
| Agent writes only its own repository | Write token scoped to that one repository |
| Agent can read dependencies and file requests on them | Read token: contents read-only, issues read/write |
| No force pushes, deleting `main`, or direct pushes to `main` | `main` ruleset: pull requests only, no deletion or force push |
| Only the human releases | `release-tags` ruleset: only admins create `v*` tags |
| Builds without warnings, tests pass, no `sorry` | Required `checks` status check |
| Agents can't weaken CI | Tokens lack Workflows permission; `.github/` owned by you |
| API and theorem changes need you | `API.lock` in CODEOWNERS; code-owner review required |
| Depend only on releases | `check-pins.sh` in CI rejects non-tag pins to your repos |
| Untrusted issues can't steer agents | Hook and protocol only consider `MACHINE_USER` and `HUMAN_USER` |
| No internet except essentials | Internal Docker network; squid allowlist is the only exit |
| Agents can't loosen their own rules | Settings, protocol, role, git config are root-owned |
| Only the human pauses and resumes agents | `control/` is mounted read-only |

## Setup

### 1. GitHub accounts and repositories

1. Create the four `inkproof-` repositories in `tentenths`. Fine-grained
   tokens can only reach repositories owned by their user or by an
   organisation the user belongs to, which is why they live in an
   organisation.
2. Create a **machine user** account for the agents (for example
   `tentenths-agents`) and add it to the organisation with **no** base
   permission, so it sees nothing else there. Give it **Write** on the four
   `inkproof-` repositories, never Admin or Maintain.
3. If the repositories are private, check that your plan supports rulesets
   and required reviews on private repositories (GitHub Team or Pro); on a
   free plan, make them public instead.
4. Optionally, require approval of fine-grained tokens and set a maximum
   lifetime. These are organisation-wide settings, so they also affect the
   organisation's other repositories and members.

### 2. Tokens

First, as an organisation owner, check that `tentenths` allows fine-grained
tokens: organisation **Settings → Personal access tokens → Settings**. (That
organisation page lists and approves tokens; it can't create them.)

Then, **signed in as the machine user**, create two **fine-grained** tokens
per agent at <https://github.com/settings/personal-access-tokens/new>
(personal **Settings**, under **Personal access tokens → Fine-grained
tokens**), with resource owner set to `tentenths` and a one-year expiry.
Never use classic tokens.

| Agent | write-token: repositories | read-token: repositories |
| --- | --- | --- |
| coordinator | inkproof-coordination | inkproof-core, inkproof-scale, inkproof-consumer-metrics |
| core | inkproof-core | inkproof-core (it has no dependencies) |
| scale | inkproof-scale | inkproof-core |
| consumer-metrics | inkproof-consumer-metrics | inkproof-core, inkproof-scale |

Permissions:

- **write-token**: Contents read/write, Pull requests read/write, Issues
  read/write. (Metadata read is added automatically.)
- **read-token**: Contents read-only, Issues read/write. The coordinator's
  read token also needs Pull requests read/write, so it can comment on
  pull requests that claim to complete a brief.
- **Never grant**: Administration, Workflows, Secrets, Actions,
  Environments, or anything else.

Save each token to `secrets/<agent>/write-token` and
`secrets/<agent>/read-token`, readable only by you (`chmod 600`).

Turn on **secret scanning with push protection** for the repositories, so a
token accidentally written into a commit is blocked.

**Rotating a token** (yearly, or at once if you suspect a leak): create the
replacement, then overwrite the file's contents in place, for example
`printf '%s' "$NEW_TOKEN" > secrets/core/write-token`. The agents read the
file on every use, so this takes effect without restarting anything. Don't
save it with an editor: many editors write a new file, which a running
container won't see. Then delete the old token on GitHub. At the same time,
check each token's repository list and the machine user's permissions.

### 3. Repositories

For each repository:

1. Copy `templates/repo/` into it (`CLAUDE.md`, `.github/`,
   `scripts/check-pins.sh`, `scripts/api-lock.sh.example`), replace
   `HUMAN_USER` in CODEOWNERS, and push as yourself. Create `CHANGELOG.md`.
   The library's agent writes `DESIGN.md` and, once it has a generator,
   `API.lock`.
2. Run `scripts/setup-repo.sh inkproof-core 1` (and so on) with your own `gh` login. It creates
   the request labels and the rulesets, and turns auto-merge on at level 2.
   Re-run it on existing repositories after upgrading the kit, so they get
   new labels such as `blocked`.

### 4. Containers

1. `cp .env.example .env` and fill it in.
2. Pin versions in `docker/agent/Dockerfile` and the proxy image tag in
   `compose.yaml`.
3. Pause the agents, so none starts work before Claude is ready for it:
   `scripts/pause.sh`. An unattended run that meets
   a login or other prompt waits until `MAX_RUN_MINUTES` runs out, and the
   work that started it is lost.
4. `scripts/up.sh` builds the image, checks the token files exist, starts
   everything, and each agent clones its repository. Lean toolchains live in
   the `elan-shared` volume, shared with any other project on this machine
   that mounts it.
5. Run `scripts/agent.sh coordinator` (or any agent) and log in to Claude.
   The login is kept in the `claude-agents` volume, which every agent shares,
   so the others are logged in too.
6. Run `scripts/agent.sh` once for each agent, and accept the prompts to
   trust its folder and to allow external imports in CLAUDE.md (the role
   file imports `PROTOCOL.md`). Claude asks these once for each agent's
   folder, even though the login is shared.
7. Run `scripts/resume.sh`.

If the `claude-agents` volume is ever recreated, repeat steps 5 and 6 with
the agents paused (`scripts/pause.sh`), then resume them.

## Daily use

Agents start themselves. Every few minutes, `watch-work` in each container
polls GitHub with that agent's own tokens and starts a Claude session when it
finds work from a trusted author:

- for every agent, on its own repository: an untriaged request; a new comment
  or review on an open issue or pull request, unless it is the agent's own or
  marked `(no reply needed)`; a failing check, or a branch behind `main`, on
  one of its pull requests; a release of a repository that one of its
  `blocked` issues names in a `Blocked-by:` line;
- for the coordinator, across the `inkproof-` repositories: a request filed,
  a pull request opened or merged, a release published, and
  `ready-for-release` or `needs-approval` added or removed.

Each agent has at most one session at a time. A run starts in tmux, so you
can attach to it, and in the `dontAsk` permission mode, so anything
`managed-settings.json` doesn't allow is refused rather than waiting for you.
It ends when Claude stops and no one is attached; work found meanwhile waits
for the next run. If Claude never finished a reply, for example because it
was stuck at a login or trust prompt, the run's work waits again for the
next one. Settings in `.env` (defaults in `compose.yaml`):
`POLL_INTERVAL` (300 seconds), `MAX_RUNS_PER_DAY` (20 per agent, UTC days)
and `MAX_RUN_MINUTES` (240, after which an unattended busy run is stopped).
When an agent reaches its cap, it opens a `needs-approval` issue on its own
repository that mentions you, so GitHub notifies you; later caps comment on
the same issue until you close it.

- `scripts/agent.sh core` attaches to core's Claude session (in tmux inside
  the container), whether you or `watch-work` started it. Detach with
  `Ctrl-b d`; the agent keeps running. A session you leave detached, idle or
  never given a prompt, is closed when work arrives; `claude --continue`
  brings it back.
- `scripts/status.sh` lists open requests with their state labels, and open
  pull requests, across the `inkproof-` repositories, then each agent's state
  and recent runs: when, what started them, and how they ended (completed,
  exited, timed out, stopped by pause, or the daily cap reached).
  `scripts/status.sh 20` shows more runs. Each run lists its transcript, which
  you can resume from with `claude --resume`.
- `scripts/pause.sh` pauses every agent: no new sessions, running ones stop
  at their next stop, and auto-merge is switched off on open pull requests.
  `scripts/resume.sh` switches it back on, in your name, and work that
  arrived meanwhile starts.
- Review and merge pull requests on GitHub as usual.
- `scripts/release.sh inkproof-core v0.2.0` tags `main` and creates a GitHub release.
  Consumers then bump their pinned version, for example in `lakefile.toml`:

  ```toml
  [[require]]
  name = "core"
  git = "https://github.com/tentenths/inkproof-core"
  rev = "v0.2.0"
  ```

- `docker compose logs proxy | grep DENIED` shows blocked network requests.

## Autonomy levels

`scripts/setup-repo.sh <repo> <level>` sets the level per repository, so you
can raise it one library at a time.

- **Level 1**: agents push branches and open pull requests; you approve. Once
  approved, either of you can merge.
- **Level 2**: auto-merge is on, so agents' pull requests merge themselves
  once checks pass. Pull requests touching `API.lock`, `.github/` or
  `lean-toolchain` still need your review, and in practice that is most
  library pull requests.
- **Level 3 (not in the kit yet)**: agents release patch and minor versions
  when `API.lock` is unchanged. This needs a release workflow allowed to
  create tags, for example a GitHub App added as a bypass actor on the
  `release-tags` ruleset.

Before raising a level, look at how often you revert agents' work, how many
requests are resolved without you, and whether consumers drift toward
workarounds.

## What runs where, and what it costs

At levels 1 and 2 everything runs in the containers on your machine: the
proxy, and in each agent container `watch-work` and the Claude sessions it
starts. Nothing runs on GitHub but the `checks` workflow, and nothing needs
an extra account, App or secret.

- **Claude**: unattended runs use the same Claude login as interactive ones,
  in the `claude-agents` volume, so they count against that account's usage
  limits or bill. Most of the cost is runs; `MAX_RUNS_PER_DAY` and
  `MAX_RUN_MINUTES` bound it at 20 runs of at most 4 hours per agent per
  day by default.
- **GitHub API**: the agents share the machine user's rate limit of 5,000
  requests an hour. Each poll costs a library agent about five requests plus
  one per blocked dependency, and the coordinator about four per
  repository, a few hundred an hour in all at the default interval.
- **GitHub Actions**: one `checks` run per push, as before.

## Using VS Code

Each `.devcontainer/<agent>/devcontainer.json` points VS Code at one service
of the compose file. Open the kit folder, run **Dev Containers: Open Folder in
Container...**, and pick the agent; use one window per agent. Closing a window
doesn't stop the agent. Run Claude in tmux (`tmux new-session -A -s claude
claude`) so it's the same session the scripts attach to.

What VS Code costs you:

- **A wider sandbox.** VS Code installs its server and extensions in every
  container, so enable the commented-out VS Code domains in
  `allowed-domains.txt`.
- **Host integration you may not want.** The Dev Containers extension can
  bring your git config, credential helper and possibly SSH agent into the
  container. Here that's actively harmful: your credentials would override
  the agent's scoped tokens. In your host VS Code settings turn off
  `dev.containers.copyGitConfig` and set
  `dev.containers.gitCredentialHelperConfigLocation` to `none`, and check the
  Dev Containers documentation for SSH-agent forwarding. Port forwarding is
  already off in these configs.
- **Weight.** One window and one VS Code server per agent.

Isolation, tokens, proxy and policy come from the compose file and GitHub, so
they're identical either way.

## Adding an agent

1. Create its `inkproof-` repository, add the machine user with Write, and
   run `scripts/setup-repo.sh`.
2. Create its two tokens in `secrets/<agent>/`.
3. Add a service, secrets and volumes to `compose.yaml` (copy `scale`, and
   set `AGENT_REPO` and `working_dir` to the new repository), a
   `roles/<agent>.md` and a `.devcontainer/<agent>/devcontainer.json`.
4. Add the new repository to the coordinator's read token, and to the read
   tokens of agents that depend on it.

## Check before relying on it

These depend on behaviour that changes between versions. Confirm each against
current documentation, then remove it from this list.

- [ ] Claude Code reads `/etc/claude-code/managed-settings.json` and
      `/etc/claude-code/CLAUDE.md` on Linux, and honours the `@` import in
      the managed CLAUDE.md.
- [ ] The deny rules hold in the permission mode you run agents in.
- [ ] The Stop hook's `stop_hook_active` field and exit-code-2 behaviour.
- [ ] Claude Code, git, gh, elan, Lake and npm all honour `HTTPS_PROXY`.
- [ ] Fine-grained tokens for an organisation member behave as described,
      including Issues write with Contents read-only.
- [ ] Repository role ID 5 is "admin" in ruleset `bypass_actors`.
- [ ] Code-owner review is still enforced with zero required approvals
      (level 2).
- [ ] Lasm's prerequisites beyond Node and the Lean toolchain.
- [ ] `claude mcp add` in `agent-init` registers lean-lsp-mcp, and its
      tools appear in each agent's session.
- [ ] `CLAUDE_CONFIG_DIR` keeps all Claude Code state inside the volume, and
      several Claude Code sessions can share one login without one refresh
      invalidating the others.
- [ ] The deny rules hold in the `dontAsk` permission mode unattended runs
      use, and `managed-settings.json` allows everything agents routinely
      need: in `dontAsk` anything else is silently refused.
- [ ] Running Claude unattended with the shared login is within the terms
      of that account's plan; if not, give unattended runs an API key.
- [ ] `UserPromptSubmit` fires for the prompt `agent-run` passes on the
      command line, `transcript_path` is in the Stop hook's input, and
      `SessionStart` gives a `source` of `startup`, `resume` or `clear`.
- [ ] `gh pr list --json` returns `mergeStateStatus` as `BEHIND` for a pull
      request behind `main`, and `gh pr update-branch` exists in the pinned
      `gh`.
- [ ] Concurrent use of `elan-shared` (agents and other projects installing
      toolchains at once) is safe; `agent-init` serialises only the agents.

## Known risks

- **Tokens are readable inside each container.** A leak may go unnoticed
  until the token expires, up to a year. The damage is limited by scope and
  rulesets: a leaked token can push branches and open pull requests and
  issues, but can't push to `main` directly, skip checks, edit CI, change
  settings or create release tags. Revoke and replace any token you suspect,
  and delete all of them if the experiment ends.
- **Boundaries depend on GitHub configuration.** A token with an extra
  repository, or the machine user gaining Admin, would quietly widen what an
  agent can do. Audit token repository lists and collaborator roles
  periodically.
- **All agents share one machine user**, so GitHub can't tell them apart.
  Agents identify themselves in commit names and with `From:` in requests.
  GitHub Apps (one per agent, minted by a small token service outside the
  containers) would give separate identities and short-lived tokens.
- **The run log is the agent's to edit.** `watch-work` runs as the agent's
  user and keeps its state in `/workspace/.inkproof`, so an agent could
  rewrite its own history in `scripts/status.sh`. GitHub's record is the
  one to trust.
- **Public repositories expose agents to anyone's issues.** The trusted-author
  filter handles this, but keeping repositories private during the experiment
  is simpler.
