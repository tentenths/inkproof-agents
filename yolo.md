From: coordinator
Building against: `main` of inkproof-agents (autonomy levels 1 and 2 in `scripts/setup-repo.sh`)
Priority: high

## Use case

The human wants to step back from day-to-day operation of the Inkproof agents. Their primary interface becomes the coordinator: the coordinator files briefs and requests as issues, each library's agent picks them up without the human attaching to it, pull requests merge themselves when checks pass, releases happen when work is verified, and requesters verify and close. The human is involved only at the end of a milestone and when a question or trade-off needs human judgement.

How the kit achieves this is yours to design. What follows are the needs, the constraints, and how we'll know it works.

## Current limitation

- **Agents only work while attached.** Each agent runs only while the human runs `scripts/agent.sh` for it and gives it a prompt. The Stop hook (`check-inbox.sh`) keeps a running session going while requests are untriaged, but nothing starts a session when work appears. In Milestone 1 the human relayed every hand-off ("Done") between the coordinator and the libraries.
- **Merging needs the human.** At level 1, every pull request waits for the human. At level 2, anything touching `API.lock`, `.github/` or `lean-toolchain` still does, and in practice every library pull request touches `API.lock`.
- **Releasing needs the human.** Only the human releases (`scripts/release.sh`; the `release-tags` ruleset). Each release blocks every consumer downstream of it.
- **The `API.lock` gate is the human.** Code-owner review on `API.lock` is the only check that blocks a library from proving something weaker than its requirement. The coordinator's review is advisory and can come too late: in Milestone 1, Scale's pull request was merged and released before the coordinator reviewed it.
- **One shared account.** All agents act as the same machine user (`inkproof-tentenths`). No agent can approve another's pull request, because GitHub sees the author approving their own, and no agent can tell from the author which agent wrote a comment.

## Acceptance criteria

**Stage 1: agents start themselves.**

Stage 1 removes the human as relay. It does not remove the human as merger: because library pull requests touch `API.lock`, most still wait for the human until Stage 2.

- Each agent starts work without the human when its repository has work for it. That means at least:
  - an untriaged request from a trusted author;
  - a new comment from a trusted author on one of its open issues or pull requests;
  - a failing check on one of its pull requests;
  - one of its pull requests falling behind `main` (the `main` ruleset requires branches to be up to date, and auto-merge does not update them), unless the kit updates such branches itself;
  - a release of a dependency it is blocked on. The protocol defines how an agent records that it is blocked, in a form a script can read (for example a label and a `Blocked-by: <owner>/<repo>#<n>` line).
- The coordinator starts on events across the `inkproof-` repositories:
  - a request filed;
  - a pull request opened or merged;
  - `ready-for-release` added;
  - a release published;
  - an escalation label (`needs-approval` in Stage 1, `needs-human` in Stage 2) added or removed.
- An agent starts within a configurable delay of the event, by default at most 15 minutes.
- Runs are bounded:
  - at most one session per agent at a time;
  - a configurable cap on runs per agent per day, and optionally on spend. Reaching a cap is shown in status and reported to the human the same way as an escalation;
  - every comment an agent writes starts with `From: <agent>`, as requests already do. A comment from the agent itself does not start its session. The protocol defines how a comment marks itself as needing no reply (an acknowledgement), and such a comment starts no session;
  - an agent with nothing unblocked stops.
- Runs need no one present:
  - an unattended run never waits on a permission prompt, and the deny rules in `managed-settings.json` are shown to hold in the permission mode it uses;
  - the README states which Claude credential unattended runs use, and that this use is within that credential's terms.
- Pull requests that need no human review merge themselves once required checks pass, with GitHub auto-merge enabled by `scripts/setup-repo.sh` at level 2.
- The human can still:
  - attach to any agent, including one running a session it started itself, and watch or steer it;
  - see what ran, when, what started it, and how it ended, from one command such as an extended `scripts/status.sh`;
  - pause and resume all agents with one command. Pause starts no new sessions, stops running ones at their next stop, and holds auto-merges and releases, so nothing changes on GitHub while paused except by the human.
- None of the existing boundaries weaken:
  - scoped tokens;
  - the proxy allowlist;
  - no workflow permission for agents;
  - the required `checks` status;
  - root-owned policy files;
  - trusted-author filtering.

**Stage 2 (autonomy level 3): releases without the human, and a replacement for the `API.lock` gate.**

This level replaces the "Level 3" sketched in the README.

- **The `API.lock` gate.**
  - A pull request that changes `API.lock` cannot merge until the coordinator has recorded a passing verdict on its head commit, as a required check rather than a comment. A failing verdict blocks the merge, and a new push needs a new verdict.
  - The ruleset accepts that check only from the coordinator's identity (for example by pinning it to a GitHub App), so no other account can satisfy it by posting a status with the same name.
  - A pull request that doesn't change `API.lock` passes the check without waiting for a coordinator session.
  - The coordinator issues its verdict under an identity distinct from the library agents', so GitHub treats it as independent. Its credentials (for example the App's private key) stay outside every container; no agent, the coordinator included, can obtain a token with more than the verdict and release paths need.
  - `/API.lock` leaves `CODEOWNERS` at this level. `/.github/` and `/lean-toolchain` stay, so those changes still need the human.
- **Releases.** A library's work is released once:
  - its brief or request is `ready-for-release`;
  - the coordinator has verified the merged work against that brief's or request's acceptance criteria. This is a check before release; the requester's check after release, by upgrading, still decides `verified`;
  - its `CHANGELOG.md` has the entry the protocol requires, for the version the release path will create.
- One release covers all work merged since the previous tag. The release path computes the version from the `API.lock` diff since that tag, and refuses if the `CHANGELOG.md` entry names a different version:
  - before 1.0: minor if `API.lock` changed, patch otherwise;
  - from 1.0: major if a declaration was removed or its signature or statement changed, minor if declarations were only added, patch otherwise.
- **Who releases.** No agent can create a tag or release outside that path.
- **Escalation.** `needs-human` replaces `needs-approval`, in the labels `scripts/setup-repo.sh` creates and in the policy text. Questions and trade-offs that need the human get the `needs-human` label and are listed in `NEEDS-HUMAN.md`. The human is notified of every `needs-human` item and of nothing else routine. GitHub has no per-label subscription, so the kit provides the mechanism.
- **Milestone review.**
  - At the end of each milestone the human gets the milestone's whole `API.lock` diff, for every library, from the tags at the milestone's start to those at its end. So anything the coordinator passed still reaches the human once.
  - A change the human rejects is fixed forward: it becomes a brief, and its fix ships in a new release. Published tags are never moved or deleted.
- **Policy text.** `docker/agent/PROTOCOL.md`, `roles/` and `templates/repo/` are updated to match, and the changes are proposed for the human's review. That includes:
  - "Changes to `API.lock` need the human's review";
  - "never create tags or releases. The human releases";
  - "Escalate: add `needs-approval` and wait for the human";
  - in `roles/coordinator.md`, "Your verdicts are advisory … never block": the `API.lock` verdict now blocks. Verdicts on scope stay advisory.
- **What still needs the human.** After the change, only these do:
  - changes to `REQUIREMENTS.md`;
  - changes to `.github/` and `lean-toolchain`;
  - milestone acceptance;
  - `needs-human` questions;
  - changes to the kit and its policy.

  GitHub enforces each of these, for example `REQUIREMENTS.md` through `CODEOWNERS` in `inkproof-coordination`, rather than the protocol alone.
- **Boundaries this stage changes.** It intentionally replaces two rows of the README's boundaries table: "Only the human releases" becomes the release path above, and "API and theorem changes need you" becomes the coordinator's required check plus milestone review. The README's table is updated to say so. The coordinator's identity is added to `TRUSTED_AUTHORS`. No other boundary weakens.
- **Rollout.** The autonomy level is still set per repository, so the human can raise it one library at a time and fall back. A library at level 3 may depend on one at a lower level, and it then waits for that library's human-made releases as it does today.

**Both stages.**

- The README states, for each level:
  - what the human must set up: accounts, a GitHub App, secrets, rulesets;
  - what runs where, and what it costs to run.
- Anything the human must do by hand is listed as a step, not left implicit.

## How we'll know it works

- **End to end.** On a level-3 library, a brief filed by the coordinator is implemented, merged, released, picked up by its consumer and marked `verified` with no human action.
- **Negative tests.** Each is shown to fail safely:
  - a pull request whose `API.lock` weakens a theorem against its requirement is blocked by the coordinator's check;
  - a status named like the coordinator's check, posted by the machine user, does not satisfy it;
  - an agent's attempt to create a tag or release is refused;
  - an issue or comment from an untrusted author starts no session;
  - a burst of comments and acknowledgements between two agents stays within the cap and ends;
  - while paused, no session starts and nothing merges or releases.

## Impact if not done

The human remains the relay between every agent hand-off, and the bottleneck for every merge and release. At Milestone 2's scale, with more simulated consumers and two more libraries in Milestone 3, that means the project waits on the human most of the time.
