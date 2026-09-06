#!/bin/bash
# One-time remote setup for the SIMP EL9 fork.
#
# Prereq: fork https://github.com/simp/simp-core to your GitHub account
#         (web UI: "Fork" button), and create an empty simp-core project
#         in GitLab. Then fill these in and run this script.

GITHUB_USER="maikuu"                                        # e.g. mikemadeit
GITLAB_URL="https://github.com/Maikuu/simp-core.git"

set -euo pipefail
[ -n "$GITHUB_USER" ] || { echo "Set GITHUB_USER at the top of this script."; exit 1; }

# upstream = the real SIMP project (fetch-only; never push here)
git remote get-url upstream >/dev/null 2>&1 \
  || git remote add upstream https://github.com/simp/simp-core.git
git remote set-url --push upstream DISABLED

# github = your fork, for PRing EL9 work back to SIMP
git remote get-url github >/dev/null 2>&1 \
  && git remote set-url github "https://github.com/${GITHUB_USER}/simp-core.git" \
  || git remote add github "https://github.com/${GITHUB_USER}/simp-core.git"

# origin = GitLab, where the work and CI actually live
git remote get-url origin >/dev/null 2>&1 \
  && git remote set-url origin "$GITLAB_URL" \
  || git remote add origin "$GITLAB_URL"

echo "--- remotes ---"
git remote -v
echo
echo "Next:  git push -u origin 6.7.0-RHEL-9.8"
