# Phase 3b - first real catalog compile on EL9

Test rig: AlmaLinux 9.8 / OpenVox 8.29.0 / facter 5.6.1, x86_64, at 10.20.31.130.
Environment: EL9 module set from `Puppetfile.el9`, plus `PROD/{data,profile,role}`
and 30 custom modules, compiled as `puppet.change.me` -> `role::core::puppet`.

## Result

**Catalog compiles: 1409 resources, 234 classes, 2.38s.**

It took **seven** rounds to get there. Each error is below, classified as a real
EL9 finding or a test-environment artifact.

## THE headline: legacy facts are gone in Puppet 8

OpenVox 8 defaults `include_legacy_facts = false`, so `$facts['fqdn']`,
`$facts['hostname']`, `$facts['domain']`, `$facts['operatingsystem']` and friends
are **empty**. Only structured facts (`$facts['networking']['fqdn']`) work.

Verified on the box:

    facts.domain   = ><          networking.domain = >change.me<
    facts.fqdn     = ><          networking.fqdn   = >puppet.change.me<

This is the single largest migration item, and **it is almost entirely in your own
code, not SIMP's.** SIMP's EL9 modules are clean; one latent case in `krb5`
(`is_string`) that your config never reaches.

### Scale: 51 files across your custom modules

| legacy fact | uses | replacement |
|---|---:|---|
| `$facts['fqdn']` | 30 | `$facts['networking']['fqdn']` |
| `$facts['operatingsystemmajrelease']` | 30 | `$facts['os']['release']['major']` |
| `$facts['domain']` | 19 | `$facts['networking']['domain']` |
| `$facts['hostname']` | 13 | `$facts['networking']['hostname']` |
| `$facts['operatingsystem']` | 6 | `$facts['os']['name']` |
| `$facts['ipaddress']` | 5 | `$facts['networking']['ip']` |
| `$facts['selinux']` | 5 | `$facts['os']['selinux']['enabled']` |
| `$facts['network']` | 3 | `$facts['networking']['network']` |
| `$facts['osfamily']` | 2 | `$facts['os']['family']` |
| `$facts['architecture']`, `['operatingsystemrelease']`, `['memorysize']`, `['processorcount']` | 1 each | see above |

Worst-affected: `rbac` (7 sites, all `hostname` regex matching), `rke2`,
`nifi_registry`, `gitlab`, `nifi`, `cert_manager`, `ds389`, `docker_ce`.

Plus **8 sites in hiera** (see Phase 3 report) and the hierarchy paths in
`hiera.yaml` (`hosts/%{facts.fqdn}`, `domains/%{facts.domain}`) - though per-host
lookup survives because `hosts/%{trusted.certname}` is listed first.

### Two options

1. **`puppet config set include_legacy_facts true`** - one line, unblocks everything.
   Still supported in Puppet 8. It is a deprecated compatibility shim, so this is a
   bridge, not a destination.
2. **Fix the 51 files** - correct, mechanical, and mostly `sed`-able.

Recommended: (1) immediately so EL9 work is unblocked, (2) as tracked remediation
before production cutover. **Do not let (1) become permanent** - it will be removed.

## CORRECTION to Phase 2

In Phase 2 I decided metadata version bounds were "release bookkeeping that lags
reality" and could be exceeded, and I overrode my own constraint solver. **That was
wrong for two components.**

SIMP modules call `simplib::assert_optional_dependency()`, which enforces bounds
declared under a SIMP-specific **`simp.optional_dependencies`** key in metadata.json
- a key my Phase 2 analysis never read, since it only parsed the standard
`dependencies` array. These bounds are enforced **at catalog compile time**:

| consumer(s) | asserted bound | our pin | outcome |
|---|---|---|---|
| aide, auditd, simp_snmpd, tlog | `simp/rsyslog >= 7.6.0 < 10.0.0` | 10.0.0 | **compile failure** |
| krb5, nfs, postfix, rsyslog, simp_snmpd, ssh, vsftpd | `simp/iptables >= 6.5.3 < 9.0.0` | 9.0.0 | **compile failure** |

11 violations across 21 assertion sites in 19 modules. Both pins demoted:

    simp-rsyslog   10.0.0 -> 9.2.0   (EL9-capable)
    simp-iptables   9.0.0 -> 8.0.4   (EL9-capable)

Exactly what the solver originally said. No EL9 support was lost.

**The refined rule:** bounds declared under `simp.optional_dependencies` AND asserted
in code are binding. Bounds that appear only in metadata are not. The other ~50
catalogued stale bounds remain safe to exceed - 37 of the 48 asserted bounds pass.

## Real findings in your code

**`additional_drives` uses `has_key()`** - removed in stdlib 9; we pin stdlib 10.0.0.
Three sites (`init.pp:46`, `init.pp:75`, `mount.pp:35`). Fix is mechanical:

    has_key($details, 'device')   ->   'device' in $details

This matters disproportionately: per your conventions `additional_drives` is a
prerequisite for every drive-guarded module you build.

Also confirmed removed from stdlib 10: `validate_re`, `is_array`, `validate_bool`.
No other custom module uses them. (`$facts.dig()` is Puppet's built-in `dig`, not
stdlib's - not affected.)

**`trlinkin-nsswitch` 2.3.0 is not Puppet 8 compatible** - `params.pp` switches on
`$facts['operatingsystem']`, hits the `default:` branch and calls
`fail("${facts['operatingsystem']} is not a supported operating system.")`. It is the
*only* thing the legacy-fact shim was covering in the SIMP module set. 2.3.0 is the
newest tag; there is no fixed release. Two-line patch, and an upstream PR candidate.

**`simp_options::tcpwrappers` confirmed fatal**, as predicted in Phase 3. Although
`simp_options` 3.0.1 dropped the parameter, `rsync/manifests/server/global.pp:45`
still reads it and tries `include ::tcpwrappers`, which no longer ships. Removing
the two hiera lines fixes it.

## Test-environment artifacts (NOT EL9 problems)

Recorded so they are not mistaken for findings:

| error | cause |
|---|---|
| `Class[Simp_grub]: expects a value for parameter 'password'` | `.gitignore` excludes `hosts/puppet.*`; the real per-host data is not in the repo |
| `lookup() did not find 'simp_options::ldap::base_dn'` | `.gitignore` excludes `simp_config_settings.yaml`, generated by `simp config` |
| `Could not find class ::elasticagent` | module lives in `bitbucket/VFDE_PLATFORM`, not in `PROD/` |
| `data/hostgroups/default.yaml: not a valid yaml hash` | file is 0 bytes (pre-existing, harmless) |

Both stubs are marked TEST-ONLY on the box and contain no production values.

## Deprecation warnings (non-fatal, will become errors)

- `cron/manifests/install.pp:28` - `ensure_packages` -> `stdlib::ensure_packages`
- `tlog/manifests/rec_session.pp:79` - `to_json` -> `stdlib::to_json`

Both are inside SIMP modules; upstream's problem, but they will break on stdlib 11.

## What this does and does not prove

**Proves:** the EL9 pin set resolves, the modules load, and a full 1409-resource
catalog compiles for your real puppet-server role on EL9 + OpenVox 8.

**Does not prove:** that applying it converges. Compilation exercises no package
installs, no service starts, no file content, no SELinux contexts, and none of the
FIPS path. That is Phase 6, and it needs `simp config` / `simp bootstrap` on this box.
