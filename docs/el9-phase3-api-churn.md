# Phase 3 - API churn: EL8 pins -> EL9 pins

Method: class parameters were extracted directly from the Puppet source at each
module's **old tag** and **new tag** (full git history is local), then diffed.
This is exact, unlike reading CHANGELOGs. Cross-referenced against the 101 hiera
keys actually set in `PROD/data/`.

## Headline

| | count |
|---|---|
| Your hiera keys unaffected | **80 / 101** |
| Removed params you actually set | **1** |
| Pre-existing dead keys found | **3** |
| Params removed across modules you use | 17 |
| Classes removed | 2 |
| **Defaults changed** | **152** |

The version jumps are large but your *explicit* configuration is nearly intact.
The risk is almost entirely in **changed defaults for things you never set**.

---

## 1. Must fix - removed key you set

`simp_options::tcpwrappers` was removed in `simp_options` 3.0.1.

    data/scenarios/simp.yaml:38
    data/hostgroups/puppet.yaml:30

Delete both lines. tcpwrappers does not exist on RHEL 8+ regardless.

The other 18 removed params/classes are not referenced anywhere in your tree
(`simp::server::ldap`, `simp::sssd::client::*`, `ssh::server::conf::fips`, etc).

---

## 2. Highest impact - `simp/ssh` stops enforcing 28 sshd directives

`simp/ssh` 9.1.0 writes an `sshd_config` entry **only when the parameter is not
`undef`** (`functions/add_sshd_config.pp`). 6.13.1 shipped concrete defaults for
28 directives; 9.1.0 sets them all to `undef`, and the module ships no hiera data.

You pin 4 of them. **25 will silently stop being written** and fall back to sshd's
built-in defaults plus `/etc/ssh/sshd_config.d/50-redhat.conf`.

Full table: [ssh-unpinned-directives.md](migration/ssh-unpinned-directives.md)

### The one that actually breaks a STIG control

You set `ssh::server::conf::clientalivecountmax: 1` but **not** `clientaliveinterval`.
Under 6.13.1 the interval defaulted to `600`, so your idle-session timeout worked.
Under 9.1.0 the interval is `undef` -> not written -> sshd default is `0` = **no
timeout at all**, which makes your `countmax: 1` inert.

    ssh::server::conf::clientaliveinterval: 600     # add this

### Others worth pinning deliberately

`permitrootlogin` (was `false`), `usepam` (was tied to `simp_options::pam`, which you
set true), `permituserenvironment` (was `false`), `strictmodes` (was `true`),
`hostbasedauthentication` (was `false`), `ignorerhosts` (was `true`).

Several of these match sshd's own defaults, so the practical risk varies - but under
6.13.1 they were *explicitly written and auditable in sshd_config*, and under 9.1.0
they will not appear at all. For STIG evidence-gathering that difference matters.

---

## 3. Second highest - `simp/aide` no longer ships a default ruleset

aide 6.6.0 shipped **97 lines** of `data/common.yaml` supplying `aide::default_rules`
(deep-merged, knockout-prefixed). aide 9.0.2's `data/common.yaml` is a three-line
comment:

> This module ships no auto-applied data. A bare `include aide` installs the package only.

All your aide parameters survive (`enable`, `cron_method`, `cron_command`, `hour`,
`weekday`, `minute`, `rules`). But you set `aide::rules` (your `audit_config`
additions) and **not** `aide::default_rules` - so today you inherit SIMP's ruleset
covering `/boot`, `/bin`, `/sbin`, `/lib`, `/opt`, `/usr`, `/root`, `/etc` and more.

On EL9 you would monitor **only your six auditd binaries**. That is a file-integrity
-monitoring regression and a STIG finding.

The 6.6.0 ruleset is preserved at
[aide-6.6.0-default_rules.yaml](migration/aide-6.6.0-default_rules.yaml) - port it into
your hiera as `aide::default_rules`, reviewing paths for EL9 changes (e.g. `/usr/tmp`).

---

## 4. Pre-existing dead keys (broken today, not an EL9 regression)

| key | problem |
|---|---|
| `ssh::server::conf::authorizedkeyfile` | typo - the parameter is `authorizedkeys**f**ile`. Never applied, at 6.13.1 or 9.1.0. |
| `simp_apache::conf::ssl::trusted_nets` | the class is `simp_apache::ssl`; no `conf/ssl.pp` exists at either version. |
| `yum::config` | `yum::config` is a *defined type*, not a class parameter, at both v5.4.0 and v8.0.0. The parameter is `yum::config_options` (a Hash). |

The `authorizedkeyfile` typo has a real consequence. Because your override never
applied, your systems currently use 6.13.1's default `/etc/ssh/local_keys/%u`. On EL9
that default becomes `undef`, so sshd falls back to `.ssh/authorized_keys` - which is
what you were *trying* to set. Decide deliberately rather than inheriting it by accident:

    ssh::server::conf::authorizedkeysfile: '.ssh/authorized_keys'   # note the 's'

`yum::config: 'installonly_limit=4'` should become:

    yum::config_options:
      installonly_limit: 4

---

## 5. Per-module churn

| module | jump | -cls | -param | +param | ~default |
|---|---|---:|---:|---:|---:|
| `ssh` | 6.13.1 -> 9.1.0 | 0 | 3 | 4 | **44** |
| `simp` | 4.16.6 -> 9.0.1 | 1 | 8 | 3 | **30** |
| `rsyslog` | 8.2.0 -> 10.0.0 | 0 | 1 | 2 | 18 |
| `aide` | 6.6.0 -> 9.0.2 | 0 | 0 | 8 | 16 |
| `auditd` | 8.8.0 -> 10.1.2 | 0 | 1 | 8 | 10 |
| `pupmod` | 8.3.1 -> 12.3.0 | 0 | 2 | 11 | 5 |
| `simp_options` | 1.6.0 -> 3.0.1 | 1 | 2 | 1 | 2 |
| `pam` | 6.11.1 -> 9.2.0 | 0 | 0 | 26 | 3 |
| `sssd` | 7.4.1 -> 10.1.2 | 0 | 0 | 10 | 3 |
| `simp_firewalld` | 0.3.1 -> 3.0.0 | 0 | 0 | 5 | 2 |
| `simplib` `selinux` `compliance_markup` `svckill` `issue` `simp_grub` | various | 0 | 0 | 0 | 0 |

`pam` gaining 26 parameters and `sssd` 10 is added capability, not breakage.

`rsyslog` is the inverse of ssh: 7 queue-tuning parameters go from `undef` to
*computed* defaults derived from system memory and CPU count
(`main_msg_queue_size`, `_high_watermark`, `_worker_threads`, ...). Behaviour will
change on every host, sized to the hardware. Review on the puppet server, where
queue behaviour matters most.

---

## Recommended hiera changes

```yaml
# --- remove -------------------------------------------------------------
# simp_options::tcpwrappers: true            # removed in simp_options 3.0.1
#   (data/scenarios/simp.yaml:38, data/hostgroups/puppet.yaml:30)

# --- fix ----------------------------------------------------------------
ssh::server::conf::authorizedkeysfile: '.ssh/authorized_keys'   # was misspelled
simp_apache::ssl::trusted_nets: "%{alias('simp_options::trusted_nets')}"
yum::config_options:
  installonly_limit: 4

# --- add: restore enforcement lost in the ssh 9.x default change ---------
ssh::server::conf::clientaliveinterval: 600    # STIG idle timeout; countmax alone is inert
ssh::server::conf::permitrootlogin: false
ssh::server::conf::permituserenvironment: false
ssh::server::conf::strictmodes: true
ssh::server::conf::hostbasedauthentication: false
ssh::server::conf::ignorerhosts: true

# --- add: restore the AIDE ruleset --------------------------------------
# port docs/migration/aide-6.6.0-default_rules.yaml into aide::default_rules
```

## Limits of this analysis

Parameters were compared by name and default-value text. This does **not** catch:
behaviour changes inside class bodies, data-type tightening that rejects values you
currently pass, template changes, or changes in `simp-rake-helpers`-generated RPM
scriptlets. Those surface only when a catalog compiles and a node converges - Phase 6.
