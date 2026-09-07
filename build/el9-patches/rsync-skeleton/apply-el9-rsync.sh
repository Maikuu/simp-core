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

# --- BIND 9.16: query-source may not pin the DNS listener port ---------------
#
# The stock bind_dns named.conf carries, inherited from the EL7/EL8 trees this
# EL9 tree was copied from:
#
#   query-source    port 53;
#   query-source-v6 port 53;
#
# EL8 shipped BIND 9.11, which allowed it. EL9 ships 9.16, which rejects it
# outright -- named will not even parse the file:
#
#   /etc/named.conf:10: 'query-source' cannot specify the DNS listener port (53)
#
# Removing it is also correct on its own terms: a fixed source port defeats
# source-port randomisation, the post-Kaminsky cache-poisoning mitigation.
# Nothing is lost by dropping it, and EL10 will ship a newer BIND still.
#
# Verified: with these two lines commented the stock file passes
# `named-checkconf` clean on BIND 9.16.23, and they are the ONLY EL9 problem in
# it -- keep-response-order, controls/rndc, forwarders, allow-transfer and the
# stock zones all parse fine.
nc="$root/RedHat/9/bind_dns/default/named/etc/named.conf"
if [ -f "$nc" ]; then
  if grep -qE '^[[:space:]]*query-source(-v6)?[[:space:]]+port 53;' "$nc"; then
    # perl, not sed: BSD sed (macOS) supports neither \s nor \n-in-replacement,
    # and this script has to run on the Mac checkout as well as the build box.
    perl -i -pe '
      s{^(\s*)(query-source(?:-v6)?\s+port 53;)}
       {$1# EL9: BIND 9.16 rejects pinning the query source port (see apply-el9-rsync.sh)\n$1#$2}
    ' "$nc"
    echo "   bind_dns named.conf: query-source lines commented (BIND 9.16)"
  else
    echo "   bind_dns named.conf: query-source already handled"
  fi
else
  echo "   bind_dns named.conf: NOT FOUND at $nc" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# /var/named must ship 1770, not 0750.
#
# BIND runs -u named and aborts config parsing if its `directory` is not
# writable, so /var/named has to be group-writable; the bind RPM ships 1770
# (drwxrwx--T) deliberately -- sticky so group members cannot remove each
# other's zone files.
#
# The mode is NOT set by the RPM's %defattr and NOT by the rsync provider's
# --chmod (the provider runs with -p, preserve_perms defaults to true and no
# --chmod is passed -- verified against the live rsync command line). It comes
# from this .rsync.facl file, which simp-cli replays verbatim via
# `setfacl --restore` in Simp::Cli::Environment::SecondaryDirEnv#apply_facls
# when the environment is created.
#
# So the stanza itself has to carry the mode: group::rwx for group-write, and
# a `# flags:` line for the sticky bit, which setfacl --restore does honour
# (verified: --t restores 1770).
#
# Without this, every agent run reports File[/var/named] as a corrective
# change -- rsync faithfully delivers the skeleton's 0750 and the named module
# then puts it back to 1770, forever.
python3 - "$facl" <<'PYEOF'
import io, re, sys

path   = sys.argv[1]
target = 'RedHat/9/bind_dns/default/named/var/named'
text   = io.open(path, encoding='utf-8').read()
stanzas = text.split("\n\n")

hits = 0
for i, st in enumerate(stanzas):
    m = re.search(r'^# file: (.+)$', st, re.M)
    if not m or m.group(1).strip() != target:
        continue
    hits += 1
    if re.search(r'^# flags:', st, re.M):
        print("   .rsync.facl: /var/named already 1770")
        break
    st = re.sub(r'^(# group: .*)$', r'\1\n# flags: --t', st, count=1, flags=re.M)
    st = re.sub(r'^group::r-x$', 'group::rwx', st, count=1, flags=re.M)
    stanzas[i] = st
    io.open(path, 'w', encoding='utf-8').write("\n\n".join(stanzas))
    print("   .rsync.facl: /var/named set to 1770 (group::rwx + sticky)")
    break

if hits != 1:
    sys.exit("   FATAL: expected exactly 1 '%s' stanza, found %d" % (target, hits))
PYEOF
