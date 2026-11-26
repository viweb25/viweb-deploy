#!/usr/bin/env bash
# Prepare a release: pin versions.env to the latest commit on main of every app repo,
# after checking that CI pushed an image for that commit. Run on your laptop:
#   scripts/release.sh            # all repos at latest main
#   scripts/release.sh api        # only the API (for a hotfix)
# Then commit, open a pull request, review the diff, and merge to deploy.
# Needs: git access to the repos and `docker login ghcr.io` (read:packages).
set -euo pipefail

cd "$(dirname "$0")/.."
OWNER=viweb25
declare -A REPOS=(
  [frontend]="viweb-frontend FRONTEND_TAG"
  [api]="viweb-ai API_TAG"
  [db]="viweb-db DB_TAG"
  [inference]="viweb-inference INFERENCE_TAG"
)
selected=("$@")
[[ ${#selected[@]} -eq 0 ]] && selected=(frontend api db inference)

for name in "${selected[@]}"; do
  [[ -n ${REPOS[$name]:-} ]] || { echo "Unknown service '$name'. Use: ${!REPOS[*]}" >&2; exit 1; }
  read -r repo key <<< "${REPOS[$name]}"
  sha=$(git ls-remote "https://github.com/$OWNER/$repo.git" refs/heads/main | cut -c1-12)
  [[ -n $sha ]] || { echo "Could not read main of $repo" >&2; exit 1; }
  tag="sha-$sha"
  if ! docker manifest inspect "ghcr.io/$OWNER/$repo:$tag" >/dev/null 2>&1; then
    echo "No image ghcr.io/$OWNER/$repo:$tag yet. Wait for CI on main to finish (or fix it)." >&2
    exit 1
  fi
  sed -i "s/^$key=.*/$key=$tag/" versions.env
  echo "$key=$tag"
done

echo
git --no-pager diff -- versions.env
echo
echo "Next: git checkout -b release/$(date +%F) && git commit -am 'Release $(date +%F)' && git push"
