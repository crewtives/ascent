#!/usr/bin/env bash
#
# Ascent - the rules that guard main, as a script that can be read and re-applied.
#
# A policy kept only in GitHub's settings cannot be reviewed, diffed or restored.
#
#   ./tools/github-protect.sh                    apply to crewtives/ascent
#   ./tools/github-protect.sh owner/repo         apply somewhere else
#
# Requires `gh` authenticated with the `repo` scope. GitHub offers rulesets on
# private repositories only on paid plans; there this answers 403.
#
set -euo pipefail

REPO="${1:-crewtives/ascent}"

# What each rule is for:
#
#   deletion / non_fast_forward   main cannot be deleted or have its history
#                                 rewritten.
#   required_linear_history       no merge commits: each pull request lands as one
#                                 squashed commit.
#   pull_request                  a pull request with one approval, the code
#                                 owner's review and every conversation resolved.
#                                 A new push dismisses earlier approvals, and
#                                 whoever pushed last cannot approve.
#   required_status_checks        lint, test and smoke green against an up-to-date
#                                 branch (`strict`), so two pull requests that each
#                                 pass alone cannot break main together.
#
# The repository admin bypasses all of it, because each publication is a direct
# push.
read -r -d '' RULESET <<'JSON' || true
{
  "name": "main",
  "target": "branch",
  "enforcement": "active",
  "bypass_actors": [
    { "actor_id": 5, "actor_type": "RepositoryRole", "bypass_mode": "always" }
  ],
  "conditions": { "ref_name": { "include": ["~DEFAULT_BRANCH"], "exclude": [] } },
  "rules": [
    { "type": "deletion" },
    { "type": "non_fast_forward" },
    { "type": "required_linear_history" },
    { "type": "pull_request",
      "parameters": {
        "required_approving_review_count": 1,
        "dismiss_stale_reviews_on_push": true,
        "require_code_owner_review": true,
        "require_last_push_approval": true,
        "required_review_thread_resolution": true,
        "allowed_merge_methods": ["squash"]
      }
    },
    { "type": "required_status_checks",
      "parameters": {
        "strict_required_status_checks_policy": true,
        "required_status_checks": [ { "context": "lint, test, smoke" } ]
      }
    }
  ]
}
JSON

# Update the ruleset called "main" if it exists instead of adding a second one:
# two rulesets on one branch both apply.
existing="$(gh api "/repos/$REPO/rulesets" --jq '.[] | select(.name == "main") | .id' 2>/dev/null || true)"

if [ -n "$existing" ]; then
  printf '\033[36m==>\033[0m updating ruleset %s on %s\n' "$existing" "$REPO"
  printf '%s' "$RULESET" | gh api -X PUT "/repos/$REPO/rulesets/$existing" --input - >/dev/null
else
  printf '\033[36m==>\033[0m creating the ruleset on %s\n' "$REPO"
  printf '%s' "$RULESET" | gh api -X POST "/repos/$REPO/rulesets" --input - >/dev/null
fi

printf '\033[32m  ok\033[0m main now requires a pull request, a review and the three gates\n'
gh api "/repos/$REPO/rulesets" --jq '.[] | "  - \(.name): \(.enforcement)"'
