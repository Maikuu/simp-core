#!/bin/bash
# Build topic branches for PRs back to simp/simp-core.
#
# Uses a detached git worktree so your checkout and uncommitted work are never
# touched: no branch switching happens in this directory.
#
# Safe to re-run; existing branches are rebuilt from scratch.
set -euo pipefail

SP="/private/tmp/claude-501/-Users-mike-Work-SIMP-RHEL9/3c9c8eb4-9e5e-426a-8980-d1537eafdd33/scratchpad"
WT="$(mktemp -d)/simp-core-pr"

cleanup() { git worktree remove --force "$WT" 2>/dev/null || true; }
trap cleanup EXIT

git fetch upstream --quiet
git worktree add --quiet --detach "$WT" upstream/master

# ---------------------------------------------------------------- PR 1
git -C "$WT" checkout -q --detach upstream/master
cp "$SP/pr1_metadata.json" "$WT/metadata.json"
git -C "$WT" add metadata.json
git -C "$WT" commit -q -F - <<'MSG'
Fix three stale dependency entries in metadata.json

The dependency list drifted from the Puppetfile:

* onyxpoint/gpasswd -> simp/gpasswd. Renamed in the Puppetfile by dfc2829
  ("Rename gpasswd Puppetfile entries to simp-gpasswd") but metadata.json
  was not updated.
* simp/ntpd removed. Dropped from the super-release by ab2db7d
  ("Remove simp-ntpd from super-release") but still declared here.
* puppet-nsswitch -> trlinkin/nsswitch. The Puppetfile ships
  trlinkin-nsswitch; no puppet-nsswitch module is checked out.

Found while auditing declared dependencies against a resolved
Puppetfile checkout: all three names fail to resolve against src/.
MSG
git -C "$WT" branch -f fix/metadata-stale-dependency-names HEAD
echo "  built fix/metadata-stale-dependency-names"

# ---------------------------------------------------------------- PR 2
git -C "$WT" checkout -q --detach upstream/master
git -C "$WT" apply "$SP/pr2_dockerfiles.patch"
git -C "$WT" add build/Dockerfiles
git -C "$WT" commit -q -F - <<'MSG'
Install mock and keep genisoimage in the EL9/EL10 build images

Two fixes for the EL9/EL10 dev-package scripts:

* mock was never installed, although build/README.md documents a
  per-distribution mock.cfg for the ISO build. It is in EPEL for both
  EL9 and EL10, so install it.

* genisoimage was installed with a trailing `||:`, so a failure to
  install it was silent. It must not be optional: it ships
  /usr/bin/isoinfo, and simp-rake-helpers aborts build:auto with
  "The following required commands were not found on your system:
  isoinfo" when it is absent. xorriso provides mkisofs but does not
  provide isoinfo, so it is not a substitute. Install genisoimage,
  isomd5sum and xorriso as hard requirements.

Found while running build:auto for an EL9 ISO: the build aborted on
the missing isoinfo despite xorriso being present.
MSG
git -C "$WT" branch -f fix/el9-el10-iso-build-deps HEAD
echo "  built fix/el9-el10-iso-build-deps"

echo
echo "Your branch and working tree were not touched: $(git branch --show-current)"
echo
echo "Review:"
echo "  git log -p upstream/master..fix/metadata-stale-dependency-names"
echo "  git log -p upstream/master..fix/el9-el10-iso-build-deps"
echo
echo "Push:"
echo "  git push github fix/metadata-stale-dependency-names"
echo "  git push github fix/el9-el10-iso-build-deps"
