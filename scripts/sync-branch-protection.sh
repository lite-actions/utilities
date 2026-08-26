#!/usr/bin/env bash
#
# Keep branch protection in sync with branch-protection.yml.
#
# Default is a read-only check that exits non-zero on drift. --apply writes the
# desired state. Both need a token with admin on the repositories: reading
# branch protection requires admin, not just write, so there is no cheaper
# read-only credential.
#
# Intended to be run locally, from a machine whose `gh` auth is already admin.
# The dispatch workflow that wraps it is inert on purpose - no admin token is
# stored anywhere in the org. See ENGINEERING-NOTES "Tokens and secrets".
#
# Usage:
#   scripts/sync-branch-protection.sh [--apply] [repo ...]
#   SPEC=other.yml ORG=other-org scripts/sync-branch-protection.sh
#
# Requires: gh (authenticated, admin), jq, yq.
# Deliberately bash 3.2 compatible - no associative arrays.

set -euo pipefail

ORG="${ORG:-lite-actions}"
SPEC="${SPEC:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/branch-protection.yml}"
APPLY=false

ARGS=()
for arg in "$@"; do
  case "${arg}" in
    --apply) APPLY=true ;;
    -h|--help) sed -n '2,18p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) ARGS+=("${arg}") ;;
  esac
done

[ -f "${SPEC}" ] || { echo "Spec not found: ${SPEC}" >&2; exit 1; }

# Refuse to apply a spec that weakens the org. enforce_admins false is called
# out by name in the engineering notes as the shortcut never to take, and a
# spec permitting force-pushes or deletions on main is a mistake, not a policy.
guard() {
  local key expect actual
  for pair in "enforce_admins true" "allow_force_pushes false" "allow_deletions false"; do
    key="${pair%% *}"; expect="${pair##* }"
    actual="$(yq -r ".defaults.${key}" "${SPEC}")"
    if [ "${actual}" != "${expect}" ]; then
      echo "::error::Refusing to run: defaults.${key} is '${actual}', expected '${expect}'. That weakens every managed repository." >&2
      exit 1
    fi
  done
}
guard

d() { yq -r ".defaults.$1" "${SPEC}"; }

if [ "${#ARGS[@]}" -gt 0 ]; then
  REPOS=("${ARGS[@]}")
else
  REPOS=()
  while IFS= read -r name; do
    [ -n "${name}" ] && REPOS+=("${name}")
  done < <(yq -r '.repos | keys | .[]' "${SPEC}")
fi

# The PUT body, built once from defaults plus this repo's checks.
desired_json() {
  local repo="$1" checks
  checks="$(yq -o=json -I=0 ".repos.\"${repo}\"" "${SPEC}")"
  jq -n \
    --argjson contexts "${checks}" \
    --argjson strict "$(d strict)" \
    --argjson admins "$(d enforce_admins)" \
    --argjson count "$(d required_approving_review_count)" \
    --argjson stale "$(d dismiss_stale_reviews)" \
    --argjson owners "$(d require_code_owner_reviews)" \
    --argjson lastpush "$(d require_last_push_approval)" \
    --argjson conv "$(d required_conversation_resolution)" \
    --argjson linear "$(d required_linear_history)" \
    --argjson force "$(d allow_force_pushes)" \
    --argjson del "$(d allow_deletions)" \
    '{
      required_status_checks: { strict: $strict, contexts: $contexts },
      enforce_admins: $admins,
      required_pull_request_reviews: {
        dismiss_stale_reviews: $stale,
        require_code_owner_reviews: $owners,
        require_last_push_approval: $lastpush,
        required_approving_review_count: $count
      },
      restrictions: null,
      required_linear_history: $linear,
      allow_force_pushes: $force,
      allow_deletions: $del,
      required_conversation_resolution: $conv,
      block_creations: false,
      lock_branch: false,
      allow_fork_syncing: false
    }'
}

# Normalise current protection to the same shape, so a plain string compare is
# a meaningful diff rather than a JSON key-order accident.
current_json() {
  jq -S '{
    required_status_checks: {
      strict: (.required_status_checks.strict // false),
      contexts: (.required_status_checks.contexts // [])
    },
    enforce_admins: (.enforce_admins.enabled // false),
    required_pull_request_reviews: {
      dismiss_stale_reviews: (.required_pull_request_reviews.dismiss_stale_reviews // false),
      require_code_owner_reviews: (.required_pull_request_reviews.require_code_owner_reviews // false),
      require_last_push_approval: (.required_pull_request_reviews.require_last_push_approval // false),
      required_approving_review_count: (.required_pull_request_reviews.required_approving_review_count // 0)
    },
    restrictions: null,
    required_linear_history: (.required_linear_history.enabled // false),
    allow_force_pushes: (.allow_force_pushes.enabled // false),
    allow_deletions: (.allow_deletions.enabled // false),
    required_conversation_resolution: (.required_conversation_resolution.enabled // false),
    block_creations: false,
    lock_branch: false,
    allow_fork_syncing: false
  }'
}

drift=0
changed=0

for repo in "${REPOS[@]}"; do
  want="$(desired_json "${repo}" | jq -S '.')"

  raw="$(gh api "repos/${ORG}/${repo}/branches/main/protection" 2>&1 || true)"
  case "${raw}" in
    *"Upgrade to GitHub"*)
      echo "SKIP     ${repo}: branch protection unavailable on this plan (private repository)"
      continue ;;
    *'"required_status_checks"'*) have="$(printf '%s' "${raw}" | current_json)" ;;
    *) have='null' ;;
  esac

  if [ "${have}" = "null" ]; then
    echo "DRIFT    ${repo}: not protected at all"
    drift=1
  elif [ "${have}" = "${want}" ]; then
    echo "OK       ${repo}"
    continue
  else
    echo "DRIFT    ${repo}:"
    diff <(printf '%s\n' "${have}") <(printf '%s\n' "${want}") \
      | sed -n 's/^[<>]/    &/p' || true
    drift=1
  fi

  if [ "${APPLY}" = "true" ]; then
    printf '%s' "$(desired_json "${repo}")" \
      | gh api -X PUT "repos/${ORG}/${repo}/branches/main/protection" \
          -H "Accept: application/vnd.github+json" --input - >/dev/null
    echo "APPLIED  ${repo}"
    changed=1
  fi

  # required_signatures is a separate endpoint and is not part of the PUT body,
  # so it survives the write above and has to be checked on its own.
  sig="$(gh api "repos/${ORG}/${repo}/branches/main/protection/required_signatures" \
          --jq '.enabled' 2>/dev/null || echo 'unknown')"
  if [ "${sig}" != "$(d required_signatures)" ]; then
    echo "         signatures=${sig}, want $(d required_signatures)"
    if [ "${APPLY}" = "true" ]; then
      gh api -X POST "repos/${ORG}/${repo}/branches/main/protection/required_signatures" >/dev/null
      echo "         signatures enabled"
    fi
  fi
done

if [ "${drift}" -eq 0 ]; then
  echo
  echo "All managed repositories match the spec."
  exit 0
fi

echo
if [ "${APPLY}" = "true" ] && [ "${changed}" -eq 1 ]; then
  echo "Drift found and applied. Re-run without --apply to confirm."
  exit 0
fi
echo "Drift found. Re-run with --apply to correct it."
exit 1
