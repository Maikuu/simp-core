#!/bin/bash
# EL9 / Puppet 8 patches for checked-out Puppet module sources.
#
# src/puppet/modules is populated by `rake deps:checkout`, which wipes it, so
# these live here and are re-applied rather than committed into the checkouts.
# Re-run after any deps:checkout, before `rake pkg:modules`.
#
# Usage:  bash build/el9-patches/modules/apply-el9-module-patches.sh
#
# ---------------------------------------------------------------------------
# $facts['environment'] is always empty on Puppet 8.
#
# It has never been a real Facter fact. Older Puppet populated the fact hash
# from node parameters, which carried 'environment'; Puppet 8 builds $facts from
# Facter plus custom facts only, so the interpolation silently yields ''.
#
# Verified on an EL9 node with include_legacy_facts=true (legacy facts such as
# osfamily resolve correctly, so this is a separate problem):
#
#     BUILTIN=[production]   FACTHASH=[]
#
# The visible symptom is rsync share names losing their middle term, e.g.
# simp_apache asking the server for 'apache__RedHat' when rsyncd.conf serves
# 'apache_production_RedHat':
#
#     @ERROR: Unknown module 'apache__RedHat'
#     Error: /Stage[main]/Simp_apache/Rsync[site]/action: ... Rsync exited with code 5
#
# The fix is the built-in $environment, which is correct at compile time both
# for master-compiled catalogs and for `puppet apply`. ($server_facts often gets
# used for this -- pupmod-simp-named does -- but it is empty under puppet apply,
# so it is the weaker choice.)
#
# This is an upstream SIMP bug, not an EL9 one: it affects any Puppet 8 master.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
MODS="$ROOT/src/puppet/modules"

[ -d "$MODS" ] || { echo "modules not checked out at $MODS"; exit 1; }

OLD='${facts['"'"'environment'"'"']}'
NEW='${environment}'

# module:relative manifest
TARGETS="
clamav:manifests/init.pp
dhcp:manifests/dhcpd.pp
freeradius:manifests/config/rsync.pp
simp_apache:manifests/init.pp
"

total=0
for entry in $TARGETS; do
  mod="${entry%%:*}"
  rel="${entry#*:}"
  f="$MODS/$mod/$rel"

  if [ ! -f "$f" ]; then
    echo "  [$mod] SKIP: $rel not present"
    continue
  fi

  n=$(grep -c -F "$OLD" "$f" || true)
  if [ "$n" -eq 0 ]; then
    echo "  [$mod] already patched ($rel)"
    continue
  fi

  # -F: fixed string, so the ${...} and quotes are not treated as patterns
  python3 - "$f" "$OLD" "$NEW" <<'PY'
import sys
path, old, new = sys.argv[1], sys.argv[2], sys.argv[3]
src = open(path).read()
open(path, 'w').write(src.replace(old, new))
PY
  echo "  [$mod] patched $n occurrence(s) in $rel"
  total=$((total + n))
done

echo
echo "  total replacements this run: $total"

# NOTE: pupmod-simp-named is no longer patched here. Its two EL9 fixes -- the
# /var/named mode and the rsync username -- now live in an EL9 fork pinned from
# Puppetfile.el9 as 7.0.2-el9, so they arrive as real commits with history
# rather than as a re-applied edit. See the SIMP_EL9_FORK_BASE note in
# Puppetfile.el9.

# NOTE: pupmod-simp-iptables is no longer patched here. Its nft-aware SysV
# status fix now lives in an EL9 fork pinned from Puppetfile.el9 as 8.0.5-el9.
# See the SIMP_EL9_FORK_BASE note there.

echo
echo "  --- verifying no \$facts['environment'] remains in any module ---"
if grep -rn -F "$OLD" "$MODS"/*/manifests/ 2>/dev/null; then
  echo "  ** still present above -- investigate **"
  exit 1
else
  echo "  clean"
fi

echo
echo "  --- puppet parser validate (skipped if puppet is absent) ---"
if command -v puppet >/dev/null 2>&1; then
  for entry in $TARGETS; do
    mod="${entry%%:*}"; rel="${entry#*:}"; f="$MODS/$mod/$rel"
    [ -f "$f" ] || continue
    printf '    %-46s ' "$mod/$rel"
    puppet parser validate "$f" >/dev/null 2>&1 && echo OK || echo "** FAILED **"
  done
else
  echo "    puppet not on PATH here; validated on the build host instead"
fi
