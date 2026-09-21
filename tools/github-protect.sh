#!/usr/bin/env bash
#
# Ascent - the rules that guard main, as something you can read and re-apply.
#
# Kept here rather than only in GitHub's settings screen, because a policy that
# lives in a web form is a policy nobody can review, diff, or restore after
# somebody changes it at two in the morning.
#
#   ./tools/github-protect.sh                    apply to crewtives/ascent
#   ./tools/github-protect.sh owner/repo         apply somewhere else
#
# Requires `gh` authenticated with the `repo` scope. NOTE: GitHub only offers
# rulesets on PUBLIC repositories for free accounts -- on a private one this
# answers 403 asking for Pro, which is not a mistake in this script.
#
set -euo pipefail

REPO="${1:-crewtives/ascent}"

# What each rule is for:
#
#   deletion / non_fast_forward   main cannot be deleted, and history cannot be
#                                 rewritten out from under anyone.
#   required_linear_history       no merge commits on main; every pull request
#                                 lands as one squashed commit with a written
#                                 subject, which is also how this history reads.
#   pull_request                  nothing reaches main without a pull request,
#                                 one approving review, the code owner's review,
#                                 and every conversation resolved. A new push
#                                 dismisses stale approvals -- an approval is of
#                                 a diff, not of a person -- and whoever pushed
#                                 last cannot be the one who approves it, so a
#                                 future collaborator cannot wave their own work
#                                 through.
#   required_status_checks        the three gates (lint, test, smoke) have to be
#                                 green, against an up-to-date branch. `strict`
#                                 is what stops two pull requests that each pass
#                                 alone from breaking main together.
#
# The repository admin bypasses all of it on purpose: this repository is
# published in batches from the development tree, and that push is a direct one.
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

# Update the ruleset called "main" if it is already there, rather than stacking a
# second one beside it: two rulesets on one branch both apply, and working out
# which of them refused a push is an afternoon.
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
