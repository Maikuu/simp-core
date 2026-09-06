# Migrating the control-repo to RHEL 9

Audit of `/Users/mike/Work/PROD` (control-repo hiera + custom modules) against a
RHEL 9.8 SIMP server. Verified against the running EL9 puppetserver at
10.20.31.131 and the RHEL 9.8 DVD, not inferred.

Ordered by what actually breaks.

---

## 1. HARD BLOCKER — `additional_drives` uses `has_key()`

`has_key()` was **removed in puppetlabs-stdlib 9.0.0**. The EL9 server ships
**stdlib 10.0.0** — confirmed, zero `has_key` implementations exist in the
deployed module. Any catalog including `additional_drives` fails with
`Unknown function: 'has_key'`.

Three call sites, all mechanical:

| file | current | replacement |
| --- | --- | --- |
| `additional_drives/manifests/init.pp:46` | `has_key($details, 'device')` | `'device' in $details` |
| `additional_drives/manifests/init.pp:75` | `has_key($attributes, 'size')` | `'size' in $attributes` |
| `additional_drives/manifests/mount.pp:35` | `has_key($usable_disks[$drivename], 'size')` | `'size' in $usable_disks[$drivename]` |

`in` is the idiomatic replacement and works on all Puppet versions in play, so
the change is safe to make in the EL8 repo too rather than forking behaviour.

`additional_drives` is in `default.yaml`'s `classes` list, so this hits **every
node**, not just the puppetserver.

---

## 2. Hiera changes

### `hostgroups/puppet.yaml:71-72` — delete the ds389 dnf_module keys

```yaml
ds389::install::dnf_module: 389-ds        # DELETE
ds389::install::dnf_stream: '1.4'         # DELETE
ds389::install::dnf_enable_only: true     # DELETE
```

**RHEL 9.8 has no `389-ds` module stream.** The AppStream modules metadata
contains no 389-ds entry; `389-ds-base-2.8.0-6.el9_8` is a plain package. Left
in place these produce `package { '389-ds': ensure => '1.4' }`, which cannot
resolve.

These are also **redundant on EL8** — `pupmod-simp-ds389`'s own
`data/os/RedHat-8.yaml` already sets exactly those three values, and its
`data/os/RedHat.yaml` sets `package_list: [389-ds-base]`, which is the correct
EL9 answer. Deleting them makes the hiera work on both EL8 and EL9.

### `simp_options::haveged: true` -> `false`

Locations: `hostgroups/puppet.yaml:24`, `scenarios/simp.yaml:31`.

haveged is not in RHEL 9 (dropped after EL7, EPEL-only). `pupmod/init.pp:268`
does `include 'haveged'` when the catalyst is set, and pupmod configures the
puppetserver — so `Package[haveged]` fails the run. Observed exactly that:
`Error: Unable to find a match: haveged`.

Nothing replaces it. Linux 5.6+ (EL9 runs 5.14) reworked the RNG: `/dev/random`
no longer blocks on an entropy estimate, `entropy_avail` is pinned at the pool
size, and the kernel has an in-kernel jitterentropy source. `rng-tools`/`rngd`
exists if a daemon is wanted, but on a VM with no RDRAND/RDSEED and no
`/dev/hwrng` it only has jitterentropy to offer, which the kernel already uses.
The change that would actually help a VM is attaching a **virtio-rng** device.

### `simp_options::tcpwrappers: true` -> `false`

Locations: `hostgroups/puppet.yaml:30`, `scenarios/simp.yaml:38`.

tcp_wrappers/libwrap were removed in RHEL 8. `rsync`, `rsyslog`, `ssh` and
`stunnel` all `include 'tcpwrappers'` when the catalyst is on, and compilation
fails with `Could not find class ::tcpwrappers`.

### `default.yaml:163` — remove clamav

```yaml
clamav::enable_data_rsync: true    # DELETE
```

clamav is EPEL-only on RHEL 9. Being dropped from the estate anyway.

### Firewall — add the two EL9 package names

`default.yaml` already has the right trio:

```yaml
iptables::enable: true
iptables::use_firewalld: false
simp_firewalld::enable: false
```

`simp_firewalld::enable: false` is **required**, not optional — without it
`simp_ds389` pulls in the `firewalld` class and `Service[firewalld]` is declared
twice (once by `iptables::service` as stopped), failing compilation.

EL9 needs two more, because `pupmod-simp-iptables 8.0.4` has no `RedHat-9` data
tier and falls through to `data/os/RedHat.yaml`, which pins the EL8 name:

```yaml
iptables::install::ipv4_package: iptables-nft-services
iptables::install::ipv6_package: iptables-nft-services
```

`iptables-services` does not exist on RHEL 9. The rename alone would *appear* to
work — `iptables-nft-services` carries `Provides: iptables-services` — but
Puppet verifies by resource name (`rpm -q iptables-services`), which never
matches, so the resource never converges.

---

## 3. Two packages RHEL 9 does not install

SIMP's `iptables::service` writes its own SysV script and uses
`provider => 'redhat'`:

| package | provides | symptom without it |
| --- | --- | --- |
| `chkconfig` | `/sbin/chkconfig` | `Provider redhat is not functional on this host` |
| `initscripts` | `/etc/init.d/functions` | `/etc/init.d/iptables: line 22: /etc/init.d/functions: No such file or directory` |

RHEL 9 installs `initscripts-service` (for `/sbin/service`) but not
`initscripts`. Both are on the DVD and are now in the ISO keep-list; if nodes
are provisioned another way, they need adding there too.

---

## 4. SSH is opened by `profile::iptables::internal` — keep it

Worth being explicit, because it is load-bearing and easy to drop:

**SIMP never opens port 22.** `iptables::rules::base` allows loopback,
ESTABLISHED/RELATED and ICMP echo, then ends the chain with LOG + DROP.
`pupmod-simp-ssh` has no firewall integration at all. On a SIMP server the
generated ruleset opens 80, 443, 8140, 8141 and 8730 — and nothing else.

`profile::iptables::internal` is what keeps the estate reachable:

```puppet
iptables::listen::all { 'internal_all':
  trusted_nets => [ $internal_network, ..., '10.20.0.0/16', ... ],
}
```

Any EL9 node that gets `use_firewalld: false` **before** that profile applies
will firewall itself off on its first puppet run. The SIMP EL9 ISO now ships
`iptables::ports: {22: {proto: tcp}}` in its per-OS hiera to cover the window
between bootstrap and the control-repo landing; it becomes redundant (harmless)
once this profile applies.

---

## 5. PXE — `profile::tftpboot` is EL8-only

`profile/manifests/tftpboot.pp` defines only EL8 models:

```
tftpboot::linux_model      { 'el8_x86_64': ... }
tftpboot::linux_model_efi  { 'el8_x86_64_efi': ks => '.../pupclient_x86_64_efi_el8.cfg' }
tftpboot::assign_host      { 'default': model => 'el8_x86_64' }
```

EL9 clients need `el9_*` models and matching kickstarts. The EL9 ISO ships
`ks/pupclient_x86_64.cfg` as the PXE client kickstart to build them from.

---

## 6. Metadata hygiene — advisory, not blocking

Eight custom modules declare RedHat 7/8 only:

    profile 1.0.3        additional_drives 1.0.3   rbac 1.1.2
    base_repos 1.0.4     cracklib_dict 1.0.8       alloy 1.0.4
    vault 2.0.0          elasticagent (no metadata.json at all)

`localuser 1.0.0` and `zicam 0.3.0` already list 9.

**None of these call `simplib::assert_metadata`**, so unlike SIMP's own modules
the metadata is documentation only and will not fail a catalog on EL9. Worth
bumping for accuracy, but it is not what will break.

---

## What was checked and found clean

* No removed-in-stdlib-10 functions other than the `has_key` cases above
  (`validate_*`, `merge`, `is_string`, `dirname`, `join_keys_to_values` all absent).
* No legacy top-level facts (`$::operatingsystem`, `$facts['operatingsystem']`
  et al) in any custom module — so `include_legacy_facts` is needed only for
  `trlinkin-nsswitch`, which SIMP pulls in, not for site code.
* No hard-coded EL8 paths or URLs in module data. `base_repos` derives its base
  URL from `%{facts.networking.domain}` and takes `baseurl` from hiera, so it
  carries no version pin of its own — the repo *server* still needs EL9 content.


---

## 7. control-repo: `Puppetfile.simp` was stale (FIXED)

`SIMP_RHEL9/control-repo/Puppetfile.simp` carried the EL8 pin set and would have
failed on the first `r10k puppetfile install`. Tested every pin against the EL9
server's local git repos:

| | |
| --- | --- |
| resolvable | **1 of 77** |
| tag missing (repo present, EL8 version) | 62 |
| repo missing entirely | 14 |

e.g. it pinned `puppetlabs-stdlib 7.1.0` and `simp-simplib 4.10.4`; the EL9
server has `10.0.0` and `7.0.1`. The 14 absent repos are the
`herculesteam-augeasproviders_*` set (replaced by `puppet-augeasproviders_*`)
and `onyxpoint-gpasswd` (replaced by `simp-gpasswd`).

This is a **generated** file, so the fix is to regenerate it on the EL9 server:

```
simp puppetfile generate > Puppetfile.simp
```

Done — 71 modules, **71/71 pins now resolve**. The old file is kept as
`Puppetfile.simp.el8-orig`.

Module set delta EL8 -> EL9:

* **dropped (14):** `herculesteam-augeasproviders_{core,grub,ssh,sysctl}`,
  `onyxpoint-gpasswd`, `simp-chkrootkit`, `simp-incron`, `simp-network`,
  `simp-ntpd`, `simp-rkhunter`, `simp-simp_openldap`, `simp-sudosh`,
  `simp-tcpwrappers`, `simp-xinetd`
* **added (8):** `puppet-augeasproviders_{core,grub,ssh,sysctl}`,
  `puppetlabs-augeas_core`, `simp-ds389`, `simp-gpasswd`, `simp-simp`

Every one of those is explainable: openldap-servers and tcp_wrappers are gone
from RHEL 8+, network-scripts from EL9, ntpd is replaced by chrony, and
incron/chkrootkit/rkhunter/sudosh/xinetd are not in the EL9 pin set.

---

## 8. `site.pp` depends on legacy facts, and fails SILENTLY without them

`manifests/site.pp` routes every node to a hostgroup with:

```puppet
case $facts['hostname'] { /^puppet/: { $hostgroup = 'puppet' } ... }
```

`hostname` (and `fqdn`, used in the notify) are **legacy top-level facts**.
Puppet 8 does not provide them unless `include_legacy_facts = true`. Measured on
the EL9 server:

```
legacy facts DISABLED:  hostname=          hostgroup=default
legacy facts ENABLED:   hostname=puppet    hostgroup=puppet
```

There is **no error** in the disabled case. The case statement simply matches
nothing, falls through to `default`, and the node silently gets the wrong hiera
layer — so the puppetserver would never pick up `hostgroups/puppet.yaml`, which
is where `simp::classes` (simp_ds389, simp::server::yum, simp_grub,
simp::server, dhcp) and the firewall settings live.

The EL9 ISO sets `include_legacy_facts = true` in its kickstart, so this works
today. But it is an invisible dependency of the whole hostgroup scheme on one
puppet.conf setting. Hardening it is a two-line change:

```puppet
$facts['networking']['hostname']    # instead of $facts['hostname']
$facts['networking']['fqdn']        # instead of $facts['fqdn']
```

---

## 9. Still outstanding in the control-repo (needs action outside this tree)

* **`Puppetfile.custom` points at the site git server** (`PUPPET_GIT_SERVER_URL`).
  The module edits made under `SIMP_RHEL9/untested/` are local working copies —
  they do not reach a node until pushed to those repos.
* **The hieradata is a separate repo.** `control-repo/` has no `data/`;
  `SIMP_RHEL9/untested/data` is where the hiera changes were made, and it needs
  pushing the same way.
* **Two custom modules pin EL8 package versions**, per their own ref comments:
  `docker_ce` (`:ref => '1.1.6' # v28.3.3 | v2.3.1-1.el8`) and
  `gitlab` (`:ref => '1.0.8' # v18.11.9-ee.0.el8`). Those are EL8 RPM builds.

## Verified clean in the control-repo

* `hiera.yaml` is byte-identical to the SIMP EL9 environment skeleton.
* `environment.conf` — `environment_timeout = 0`, so hieradata edits take effect
  without a puppetserver reload.
* `.r10kignore` already excludes `data/simp_config_settings.yaml`.
