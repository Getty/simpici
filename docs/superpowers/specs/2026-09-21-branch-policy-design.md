# Branch protection and optional CI policy

As of: 2026-09-21. The branch defaults and the choice of policy source have
been decided. The native metadata integration below is a proposed extension.
This document does not describe an already implemented feature.

## Goal and scope

SimpiCI remains usable without a mandatory policy. The existing `.cicd/*.sh`
files remain the job plan; no second pipeline language is introduced.
The optional repository policy decides whether runs are admitted before
repository code is executed. Build steps and voluntary job skipping remain
in the scripts.

Branch protection is a trust decision managed by the operator or forge.
SimpiCI should use the reported protection status, not reimplement every
provider's review, role and bypass rules. This does not independently verify
how effectively those rules provide protection.

## Agreed defaults

The following rules apply to branch runs of the configured repository.
Existing source and ref filters still apply. These rules are not blanket
permission for fork PRs, tags, additional repositories or credentials.

| State | Behavior without additional permission |
| --- | --- |
| Reliably established: no protected branches | All branches observed through normal operation may run their own `.cicd` jobs. |
| Protected branches exist, no valid policy | Only protected branches may run their `.cicd` jobs. |
| Protected branches and a valid policy | The policy may additionally allow unprotected branches. |
| Metadata is incomplete, unknown or the query failed | Do not authorize new runs based on this unknown data; do not fall back to “no protection.” |

Neither regular mode requires a policy. Explicitly confirming that the last
branch protection has been removed switches back to the mode where all
branches are treated equally. This is a permission change made by the
authority responsible for the metadata, not a way of handling a failed query.

Admitting a run does not automatically grant secrets, Docker socket access
or deployment rights. Existing credential boundaries remain in place;
untrusted fork/PR code must not bypass them through a branch policy.

## Agreed policy source

- A repository-wide policy is looked up at `.cicd/policy.json` on the default
  branch. Its specific rule syntax is outside the scope of this decision.
- Once protected branches exist, the default branch itself must be protected
  for its policy to be accepted as authoritative.
- If only another branch is protected, the default remains “protected
  branches only” without a protected default branch. That other branch's
  policy does not automatically replace the default branch's policy.
- Multiple protected branches do not create competing policy sources.
  Neither commit timestamps nor the most recently updated branch determine
  the selection. There is no additional `policy_branch` setting.
- A policy on the candidate/feature branch cannot authorize that branch
  itself. For admitted branch runs, its `.cicd` scripts remain executable
  candidate code, not an authorization source.
- Resolve the selected policy version to an exact commit before execution
  and associate it with the run decision; do not reload the latest branch
  version during a run.

GitHub, GitLab and Forgejo provide the default branch as `default_branch` in
repository or project metadata. “Default” does not mean “protected”;
protection status is determined separately. For empty repositories, a
configured branch name without an actual commit is not enough.

## Native simpicid: proposed metadata integration

The existing daemon JSON configuration already contains `repositories[]`
(see `etc/simpici.example.json`). This is where the operator's choice of
metadata source belongs, not in the candidate checkout or in a URL freely
chosen by the event sender.

A source provides the same facts for each repository:

```json
{
  "default_branch": "main",
  "protected_branches": ["main", "release/1.x"]
}
```

These are exact branch names, not patterns. For comparisons with events,
they are mapped to canonical `refs/heads/...` after validation. The list must
be complete, including branches outside the currently observed ref filters.
Forge APIs therefore require particular attention to pagination and effective
branch protection. An explicit empty list means “no protected branches”;
a missing field does not.

### Three possible sources, one shared contract

| Source | Responsibility |
| --- | --- |
| Static operator configuration | The operator defines the default branch and protected branches for their own Git hosting or a deliberately local view. |
| Forge adapter | GitHub, GitLab or Forgejo provide repository identity, the default branch and branch protection through their APIs. |
| Trusted JSON URL | An endpoint chosen by the operator provides the complete metadata set for this repository. |

Static declarations do not replace Git server access control. If a branch
is declared protected locally, the operator is responsible for ensuring that
only trusted people can change its authoritative contents.

Proposed excerpt of a `repositories[]` entry for static data:

```json
{
  "branch_metadata": {
    "source": "static",
    "default_branch": "main",
    "protected_branches": ["main", "release/1.x"]
  }
}
```

Alternatively, the same configuration location with a custom endpoint:

```json
{
  "branch_metadata": {
    "source": "url",
    "url": "https://ci-config.example/repos/example/branches.json"
  }
}
```

These keys are design examples, not configuration supported today.
Exactly one authoritative source is selected per repository; no silent
mixing and no automatic switch from a failed URL/forge query to static,
less restrictive declarations.

The URL is a trust anchor, like the local configuration: accept it only from
operator configuration, use HTTPS with certificate verification, retain the
repository association and do not accept arbitrary redirect targets or URLs
from job code or webhook payloads. Responses need size limits, a timeout and
schema validation. Credentials stay in the control plane. The endpoint
provides data, not shell scripts or job instructions.

## Preparing for later implementation

- Separate metadata retrieval and admission decisions from the shell executor.
  The executor only discovers and starts jobs for a run that has already been
  admitted; a job must not determine its own admission.
- Provide a shared admission path for native local operation, the dispatcher
  and ordinary manual or future webhook inputs. Checking only `GitPoll` is
  not enough: the one-shot entry point does not use it.
- Hosted entry points should use the same decision contract. The metadata
  source differs, not the meaning of the defaults.
- Associate the candidate commit, the metadata used and, where applicable,
  the policy commit with the decision. Workers must not independently expand
  a decision by using a different metadata source.
- Rollout to existing configurations, the specific policy syntax, PR/tag
  admission, credential profiles and queue/deduplication behavior when the
  policy changes need their own scoped implementation design before being
  implemented. No new runtime defaults are enabled here.

Later tests must, at a minimum, distinguish known empty protection lists from
errors, cover multiple protected branches and an unprotected default branch,
rule out self-authorization through candidate policies and verify identical
decisions for static, URL and forge metadata.

## References

- [GitHub Repository API](https://docs.github.com/en/rest/repos/repos#get-a-repository)
- [GitHub Rulesets API](https://docs.github.com/en/rest/repos/rules)
- [GitLab Project API](https://docs.gitlab.com/api/projects/#get-a-single-project)
- [GitLab Protected Branches](https://docs.gitlab.com/api/protected_branches/)
- [Forgejo Branch Protection](https://forgejo.org/docs/latest/user/repository/protection/)
- [Forgejo OpenAPI](https://codeberg.org/swagger.v1.json)
