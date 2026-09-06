#!/bin/bash
#
# EL9 hiera overrides for simp-environment-skeleton.
#
# The default 'simp' scenario turns on catalysts whose backing packages DO NOT
# EXIST on RHEL 9. Verified against the RHEL 9.8 DVD (BaseOS + AppStream):
#
#   haveged        absent   -- dropped after EL7; RHEL 9 relies on the kernel
#                             CRNG, and ships rng-tools instead
#   tcp_wrappers   absent   -- libwrap was removed in RHEL 8
#
# Both are reached from code that always runs:
#
#   * pupmod/manifests/init.pp:268   `include 'haveged'` when simp_options::haveged
#     -- pupmod configures the puppetserver, so this is on the critical path.
#   * rsync/manifests/server/global.pp:45  `include 'tcpwrappers'` when
#     simp_options::tcpwrappers (also rsyslog, ssh, stunnel)
#
# Left unfixed, catalog compilation fails on tcpwrappers ("Could not find class
# ::tcpwrappers") and, past that, the run dies applying Package[haveged]. A run
# that dies partway with simp_options::firewall enabled can leave firewalld up
# with the allow-rules not yet applied -- i.e. it locks you out of the box.
#
# WHERE THESE GO
# --------------
# The environment hierarchy (environments/puppet/hiera.yaml) has a per-OS layer:
#
#     - name: Per-OS data
#       paths:
#       - "%{facts.os.family}.yaml"
#       - "%{facts.os.name}/%{facts.os.release.full}.yaml"
#       - "%{facts.os.name}/%{facts.os.release.major}.yaml"   <-- RedHat/9.yaml
#       - "%{facts.os.name}.yaml"
#
# which outranks the scenario layer, so RedHat/9.yaml is the correct home for
# these. It does NOT outrank the per-node layer, though, and `simp config`
# generates data/hosts/<fqdn>.yaml from data/hosts/puppet.your.domain.yaml --
# which sets both catalysts to true. So the template entries must be dropped as
# well, or they win and the per-OS file is ignored.
#
# Usage:  apply-el9-hiera.sh [<path to the environment component>]
#         defaults to ../../../src/assets/environment
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
component=${1:-$(cd "$here/../../.." && pwd)/src/assets/environment}
data="$component/environments/puppet/data"

[ -d "$data/scenarios" ] || { echo "FATAL: not an environment skeleton: $data" >&2; exit 1; }

echo "== writing $data/RedHat/9.yaml"
mkdir -p "$data/RedHat"
cat > "$data/RedHat/9.yaml" <<'YAML'
---
# EL9 overrides.
#
# This file sits in the environment's "Per-OS data" hiera layer, which outranks
# the scenario layer, so it corrects the 'simp' scenario defaults for RHEL 9
# without having to edit the scenario itself.
#
# Both catalysts below are disabled because the packages they manage DO NOT
# EXIST on RHEL 9 (verified against the RHEL 9.8 DVD, BaseOS + AppStream).

# haveged was dropped after EL7. RHEL 9 relies on the kernel CRNG and ships
# rng-tools. Leaving this true makes pupmod include the haveged class, whose
# Package['haveged'] cannot be satisfied -- which aborts the puppet run.
simp_options::haveged: false

# tcp_wrappers / libwrap were removed in RHEL 8. Leaving this true makes rsync,
# rsyslog, ssh and stunnel `include 'tcpwrappers'`, and catalog compilation
# fails with "Could not find class ::tcpwrappers" -- pupmod-simp-tcpwrappers is
# deliberately not in the EL9 pin set.
simp_options::tcpwrappers: false

# --- Firewall backend: iptables, not firewalld -------------------------------
#
# Site decision: this build uses SIMP's iptables backend everywhere. The 'simp'
# scenario ships iptables::use_firewalld: true, which this layer overrides.
#
# The two package keys are NOT optional on EL9. pupmod-simp-iptables 8.0.4 has
# no RedHat-9 data tier, so RHEL 9 falls through to data/os/RedHat.yaml, which
# is commented "# EL8+" and pins:
#     iptables::install::ipv4_package: iptables-services
# `iptables-services` does not exist on RHEL 9 -- it was renamed
# iptables-nft-services (verified against the RHEL 9.8 DVD).
#
# The rename alone would resolve, because iptables-nft-services carries
# `Provides: iptables-services`. But Puppet verifies a package by RESOURCE NAME
# (`rpm -q iptables-services`), which never matches the installed
# iptables-nft-services -- so the resource would reinstall on every run and
# never converge. Naming the real package keeps it idempotent.
#
# iptables-nft-services ships the iptables.service and ip6tables.service units
# that iptables::service manages, so the rest of the module is unchanged.
#
# NOTE: on RHEL 9 this is iptables-nft -- the legacy iptables syntax over an
# nftables backend. The xtables kernel path is gone. SIMP's semantics and
# iptables::listen::tcp_stateful are unaffected.
# simp_firewalld::enable: false is REQUIRED alongside use_firewalld: false, not
# optional. Without it the catalog fails to compile:
#
#   Duplicate declaration: Service[firewalld] is already declared at
#     modules/iptables/manifests/service.pp:104
#   cannot redeclare at modules/firewalld/manifests/init.pp:180
#     (file: modules/simp_ds389/manifests/instances/accounts.pp, line: 126)
#
# because iptables::service declares Service[firewalld] as 'stopped' when
# use_firewalld is false, while simp_ds389 opens its port with
# simp_firewalld::rule -- which `include simp_firewalld` -> `class {'firewalld'}`
# -> declares Service[firewalld] a second time.
#
# simp_firewalld wraps its whole body in `if $enable`, and simp_firewalld::rule
# is likewise guarded by `if $simp_firewalld::enable`, so setting this false
# makes those rules clean no-ops rather than errors.
#
# Only simp_ds389 and libreswan reach firewalld directly; the other 17 modules
# use the backend-agnostic iptables::listen::* and honour use_firewalld.
#
# This trio matches the site's existing EL8 production hiera
# (PROD/data/default.yaml).
iptables::enable: true
iptables::use_firewalld: false
simp_firewalld::enable: false
iptables::install::ipv4_package: iptables-nft-services
iptables::install::ipv6_package: iptables-nft-services

# --- SSH MUST be opened explicitly. Do not remove. ---------------------------
#
# SIMP does NOT open port 22 anywhere. iptables::rules::base allows loopback,
# ESTABLISHED/RELATED and ICMP echo, then ends the chain with LOG + DROP, and
# pupmod-simp-ssh has no firewall integration at all.
#
# On the default firewalld path that is masked. On the iptables path the first
# real `puppet agent -t` writes a ruleset with no SSH accept and then STARTS the
# service -- locking out every remote session. Verified: the generated ruleset
# opened 80/443/8140/8141/8730 and nothing else.
#
# In production the site supplies this via profile::iptables::internal, but a
# freshly bootstrapped server has no control-repo yet, so the image must carry
# a rule of its own. trusted_nets is inherited from simp_options::trusted_nets,
# i.e. whatever was answered during `simp config`, giving:
#
#   -m state --state NEW -m tcp -p tcp -s <trusted_nets> --dports 22 -j ACCEPT
iptables::ports:
  22:
    proto: tcp

# --- Never fetch the OpenVox release RPM from the internet ------------------
#
# pupmod::master::install has two branches. Without pupmod::openvox_rpm_path it
# declares a package whose NAME is a vendor URL:
#
#   package { 'https://yum.voxpupuli.org/openvox8-release-el-9.noarch.rpm': }
#
# That fails on every run, for two independent reasons:
#
#  1. simp_options::package_ensure defaults to 'latest', so Puppet runs
#     `dnf -y upgrade <url>`. dnf will not upgrade a package that is not
#     installed, so it exits 1 with "No packages marked for upgrade." Setting
#     ensure to 'installed' would instead make dnf *install* it, over the
#     internet.
#  2. These nodes never reach the internet, and the release RPM's only purpose
#     is to add yum.voxpupuli.org as a repo -- exactly what must not happen on
#     an air-gapped network. Note the failure is NOT a network block: a test
#     node reached the vendor fine, so this would appear to "work" on a
#     connected build/test box and break on a real air-gapped one.
#
# Setting openvox_rpm_path takes the other branch, which declares the real
# package and skips the release RPM entirely:
#
#   package { 'openvox-server': ensure => $package_ensure, source => <path> }
#
# The path below is the RPM this ISO already bakes into the server's own yum
# tree, so nothing is fetched. pupmod::master::install is master-only
# (assert_private, reached via pupmod::master) and that tree exists on the SIMP
# server, which is the only place the class is evaluated. openvox-server is also
# in the local 'puppet' repo, so with ensure => latest Puppet resolves the same
# version already installed and makes no change.
#
# Version-pinned because Puppet's package source needs an exact file. Keep it in
# step with the openvox-server RPM synced in the build (see the "External
# packages" step in docs/el9-build-procedure.md), or override it per-site once
# the reposerver exists.
pupmod::openvox_rpm_path: /var/www/yum/SIMP/RedHat/9/x86_64/puppet/openvox-server-8.15.2-1.el9.noarch.rpm
YAML

# The per-node layer outranks per-OS, and `simp config` copies these templates
# verbatim, so the entries have to come out of the templates too.
for tmpl in "$data"/hosts/*.yaml; do
  [ -f "$tmpl" ] || continue
  changed=0
  for key in simp_options::haveged simp_options::tcpwrappers iptables::use_firewalld; do
    if grep -qE "^${key}: true" "$tmpl"; then
      # NOTE: written with python, not sed. BSD/macOS sed treats `-i -E` as
      # "-i with backup suffix -E", which silently litters <file>-E backups and
      # drops extended-regex mode; GNU sed does not. python keeps this portable.
      python3 - "$tmpl" "$key" <<'PYEOF'
import io, sys
path, key = sys.argv[1], sys.argv[2]
s = io.open(path, encoding='utf-8').read()
old = "%s: true" % key
new = ("# %s intentionally omitted on EL9. The per-node layer outranks\n"
       "# per-OS, so leaving it here would defeat data/RedHat/9.yaml -- set it there." % key)
io.open(path, 'w', encoding='utf-8').write(s.replace(old, new))
PYEOF
      changed=1
    fi
  done
  [ "$changed" = 1 ] && echo "== de-pinned EL9-overridden keys in $(basename "$tmpl")"
done

echo
echo "== result"
echo "--- data/RedHat/9.yaml ---"
grep -vE '^\s*#|^\s*$|^---' "$data/RedHat/9.yaml" | sed 's/^/    /'
echo "--- remaining 'true' settings for these keys in host templates ---"
grep -n -E "^(simp_options::(haveged|tcpwrappers)|iptables::use_firewalld): true" "$data"/hosts/*.yaml 2>/dev/null || echo "    (none -- correct)"
