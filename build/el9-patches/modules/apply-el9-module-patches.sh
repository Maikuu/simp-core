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

# ---------------------------------------------------------------------------
# The SysV status check cannot see an nf_tables-backed firewall.
#
# iptables::service hardcodes provider => 'redhat' and ships its own SysV
# scripts, so Puppet asks /etc/init.d/iptables whether the service is running.
# That script snapshots the active tables once, at load:
#
#     NF_TABLES=$(cat /proc/net/ip_tables_names 2>/dev/null)
#
# EL9's iptables is v1.8.10 (nf_tables). The legacy xtables list exists but is
# always EMPTY, even with rules loaded, so status() falls through to
#
#     iptables: Firewall is not configured.     (exit 3)
#
# Puppet therefore believes the service is stopped on every run and "starts" it
# again -- a corrective change on every single agent run, forever:
#
#     Notice: /Stage[main]/Iptables::Service/Service[iptables]/ensure:
#       ensure changed 'stopped' to 'running' (corrective)
#
# Verified on an EL9 node: /proc/net/ip_tables_names is empty while
# `iptables-save` reports "mangle raw filter nat" and 18 non-policy rules are
# live.
#
# The fallback is deliberately guarded on the lockfile. `iptables-save` prints
# the built-in tables even when the firewall is stopped, so using it
# unconditionally would make a stopped firewall look running and break
# `ensure => stopped`. The lockfile is what start()/stop() actually maintain, so
# gating on it keeps both states honest:
#
#   legacy kernel      proc file non-empty  -> unchanged
#   nft + started      lockfile present     -> tables found, status 0
#   nft + stopped      lockfile absent      -> stays empty, "not running"
# ---------------------------------------------------------------------------
IPT_OLD='NF_TABLES=$(cat "$PROC_IPTABLES_NAMES" 2>/dev/null)'
read -r -d '' IPT_NEW <<'IPTEOF' || true
NF_TABLES=$(cat "$PROC_IPTABLES_NAMES" 2>/dev/null)

# EL9: with the nf_tables backend (iptables-nft) the legacy xtables list at
# $PROC_IPTABLES_NAMES stays empty even when rules are loaded, so every caller
# below decides the firewall is unconfigured -- which makes status() return 3
# and Puppet re-"start" the service on every run. Ask iptables itself instead.
#
# Guarded on the lockfile on purpose: ${IPTABLES}-save prints the built-in
# tables even when the firewall is stopped, so an unguarded fallback would
# report a stopped firewall as running. The lockfile is what start()/stop()
# maintain, so it is the honest discriminator.
if [ -z "$NF_TABLES" ] && [ -f "$VAR_SUBSYS_IPTABLES" ]; then
    NF_TABLES=$(/sbin/${IPTABLES}-save 2>/dev/null | sed -n 's/^\*//p')
fi
IPTEOF

for f in iptables ip6tables; do
  t="$MODS/iptables/files/$f"
  if [ ! -f "$t" ]; then echo "  [iptables] SKIP: files/$f absent"; continue; fi
  if grep -q 'nf_tables backend (iptables-nft)' "$t"; then
    echo "  [iptables] already patched (files/$f)"
    continue
  fi
  if ! grep -qF "$IPT_OLD" "$t"; then
    echo "  [iptables] FAILED: anchor not found in files/$f"; exit 1
  fi
  python3 - "$t" "$IPT_OLD" "$IPT_NEW" <<'PY'
import sys
path, old, new = sys.argv[1], sys.argv[2], sys.argv[3]
s = open(path).read()
assert s.count(old) == 1, f"{path}: anchor matched {s.count(old)}x"
open(path, 'w').write(s.replace(old, new))
PY
  echo "  [iptables] patched files/$f (nft-aware status)"
done

echo "  --- bash -n on the patched init scripts ---"
for f in iptables ip6tables; do
  t="$MODS/iptables/files/$f"
  [ -f "$t" ] || continue
  printf '    %-42s ' "iptables/files/$f"
  bash -n "$t" 2>/dev/null && echo OK || echo "** FAILED **"
done

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
