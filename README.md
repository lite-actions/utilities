# utilities

Org-wide automation for `lite-actions` that does not belong inside an action.

**There is nothing here to consume.** Every other repository in the org ships an
action you can `uses:`. This one ships nothing — it runs things *on* the org.
It exists so that automation about the org does not have to live in a repository
of shared actions, which is where the auto-merge monitor started and did not
belong.

## What runs here

| workflow | trigger | what it does |
| --- | --- | --- |
| `unstick-auto-merge.yml` | every 15 minutes | completes merges that GitHub's auto-merge agreed to and then failed to perform |
| `branch-protection.yml` | manual — **inert by design** | checks branch protection against `branch-protection.yml`, or applies it |

### `unstick-auto-merge`

GitHub's auto-merge intermittently fails to fire. A pull request that is
approved, passing and armed simply sits there: the run is green, nothing errors,
and the only evidence is an open PR nobody is watching. It is a [known
issue](https://github.com/orgs/community/discussions/130262) reported since June
2024 with no acknowledged fix, and it happened roughly once in 28 changelog PRs.

This does not try to prevent it. It detects a PR that GitHub agreed was ready and
then failed to merge, and completes the merge itself — posting a diagnosis to
Slack for each one, so a stall is visible rather than silent.

It only sees **public** repositories. `CHANGELOG_BOT_TOKEN` carries
`public_repo`, which cannot reach a private repo, so widening coverage is a
decision about token scope rather than a one-line change.

### `branch-protection`

Branch protection is uniform across eight repositories by convention, not by
enforcement — organisation rulesets need GitHub Team, and this org is on Free.
`branch-protection.yml` is the intent and `scripts/sync-branch-protection.sh`
is the mechanism.

**Run the script locally.** The workflow reads `PROTECTION_ADMIN_TOKEN`, a
secret that is deliberately never created: reading branch protection requires
admin rather than write, and a stored token that can rewrite protection across
the org is the one credential whose leak would disable every protection and then
permit any push. Running it from a machine whose `gh` auth is already admin
removes that risk instead of relocating it.

```bash
bash scripts/sync-branch-protection.sh            # check; exits non-zero on drift
bash scripts/sync-branch-protection.sh --apply    # correct it
```

It refuses to run at all if the spec would weaken the org — `enforce_admins`
off, or force pushes or deletions permitted.

## Why this repository is public

A private repository bills Actions minutes against the org's 2,000/month Free
allowance, rounded up per job. The monitor runs every 15 minutes — roughly 2,880
billed minutes a month, which exceeds the whole allowance on its own. Public
costs nothing and the code here is not secret.

Secrets are not exposed to fork pull requests, and merging requires a review and
a code-owner approval, so being public is not itself an exposure.

## Conventions

Pure shell, like the rest of the org: no Node, no Docker, no `node_modules`.
Commits and branches follow Conventional Commits — note that branch types are a
*different, shorter* list than commit types.
