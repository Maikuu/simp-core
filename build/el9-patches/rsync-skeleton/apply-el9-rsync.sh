#!/bin/bash
#
# Re-base the SIMP rsync skeleton on EL9.
#
# WHY
# ---
# simp-rsync-skeleton ships /usr/share/simp/environment-skeleton/rsync, which
# `simp config` copies to /var/simp/environments/<env>/rsync. Upstream 7.1.1
# provides:
#
#     rsync/RedHat/7/        bind_dns skeleton
#     rsync/RedHat/8/        bind_dns skeleton (byte-identical to 7)
#     rsync/RedHat/Global/   dhcpd, tftpboot, apache, snmp, freeradius
#     rsync/Global/          clamav, mcafee, jenkins_plugins
#
# There is no RedHat/9, and that is a functional gap on EL9, not cosmetic:
#
#   * the simp_rsync_environments fact (pupmod-simp-simp,
#     lib/facter/simp_rsync_environments.rb) walks the tree looking for
#     '.shares' files and builds a hash of what it finds;
#   * simp::server::rsync_shares turns that hash into rsync shares;
#   * clients ask for a share named after their own OS *and major version* --
#     e.g. named/manifests/chroot.pp:39
#         $_rsync_user = "bind_dns_..._${facts['os']['name']}_${facts['os']['release']['major']}"
#     which on EL9 resolves to '..._RedHat_9'.
#
# So an EL9 client configuring DNS asks for a share that does not exist.
#
# This script replaces RedHat/7 and RedHat/8 with RedHat/9 (they are identical,
# so 8 is used as the base) and keeps RedHat/Global, which is where dhcpd,
# tftpboot and apache live and is version-independent.
#
# It also rewrites rsync/.rsync.facl, which the RPM installs as %config and
# which carries one ACL stanza per path. Without that, the new RedHat/9 tree
# would ship with no FACLs.
#
# Usage:  apply-el9-rsync.sh [<path to the rsync_data component>]
#         defaults to ../../../src/assets/rsync_data
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
component=${1:-$(cd "$here/../../.." && pwd)/src/assets/rsync_data}
root="$component/rsync"

[ -d "$root/RedHat" ] || { echo "FATAL: not an rsync skeleton: $root" >&2; exit 1; }

echo "== before"
ls -1 "$root/RedHat" | sed 's/^/     RedHat\//'

if [ -d "$root/RedHat/9" ]; then
  echo "== RedHat/9 already present -- nothing to copy"
else
  base=""
  for cand in 8 7; do [ -d "$root/RedHat/$cand" ] && { base=$cand; break; }; done
  [ -n "$base" ] || { echo "FATAL: no RedHat/7 or /8 to use as a base" >&2; exit 1; }
  echo "== creating RedHat/9 from RedHat/$base"
  cp -a "$root/RedHat/$base" "$root/RedHat/9"
fi

for old in 7 8; do
  if [ -d "$root/RedHat/$old" ]; then
    echo "== removing RedHat/$old"
    rm -rf "$root/RedHat/$old"
  fi
done

# ---------------------------------------------------------------------------
# .rsync.facl: drop the RedHat/7 and RedHat/8 stanzas, emit RedHat/9 ones.
# Stanzas are blank-line separated and begin with '# file: <path>'.
# ---------------------------------------------------------------------------
facl="$root/.rsync.facl"
if [ -f "$facl" ]; then
  python3 - "$facl" <<'PYEOF'
import io, re, sys

path = sys.argv[1]
text = io.open(path, encoding='utf-8').read()
stanzas = text.split("\n\n")

out, made9 = [], False
for st in stanzas:
    m = re.search(r'^# file: (.+)$', st, re.M)
    p = m.group(1).strip() if m else None

    if p and re.match(r'^RedHat/7(/|$)', p):
        continue                                  # drop EL7 outright
    if p and re.match(r'^RedHat/8(/|$)', p):
        out.append(re.sub(r'^(# file: RedHat/)8', r'\g<1>9', st, flags=re.M))
        made9 = True
        continue
    if p and re.match(r'^RedHat/9(/|$)', p):
        out.append(st); made9 = True             # already converted; keep as-is
        continue
    out.append(st)

io.open(path, 'w', encoding='utf-8').write("\n\n".join(out))
kept = sum(1 for s in out if re.search(r'^# file: RedHat/9', s, re.M))
print("   .rsync.facl: %d RedHat/9 stanzas, %d total" %
      (kept, sum(1 for s in out if re.search(r'^# file:', s, re.M))))
if not made9:
    sys.exit("   FATAL: no RedHat/9 stanzas produced")
PYEOF
else
  echo "   WARNING: $facl not found -- FACLs not updated"
fi

echo
echo "== after"
ls -1 "$root/RedHat" | sed 's/^/     RedHat\//'
echo "   RedHat/9 files: $(find "$root/RedHat/9" -type f | wc -l | tr -d ' ')"
echo
echo "== leftover EL7/EL8 references"
if grep -rn 'RedHat/[78]' "$root" 2>/dev/null | head -5; then :; else echo "   none"; fi
