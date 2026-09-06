# Phase 2 - EL9 component pin set

Branch: `6.7.0-RHEL-9.8` | Base: upstream `master` @ `7f1409b` | Target: RHEL 9.8 / OpenVox 8

## What changed

`Puppetfile.el9` replaces the EL8-era `Puppetfile.pinned` (SIMP 6.6.0-2).
`Puppetfile.tracking` now symlinks to it, so all `rake deps:*` tasks default to EL9.

| | before | after |
|---|---|---|
| EL9-capable modules | 71 / 98 | **92 / 98** |
| EL10-capable modules | 65 / 98 | **70 / 98** |
| simp-core dep bounds violated | 56 / 68 | **0 / 67** |

99 of 108 components moved. Representative jumps:

| component | EL8 pin | EL9 pin |
|---|---|---|
| `simp-simp` | 4.16.6 | **9.0.1** |
| `simp-pupmod` | 8.3.1 | **12.3.0** |
| `simp-simplib` | 4.10.4 | **7.0.1** |
| `simp-ssh` | 6.13.1 | **9.1.0** |
| `simp-iptables` | 6.6.0 | **9.0.0** |
| `simp-simp_firewalld` | 0.3.1 | **3.0.0** |
| `puppetlabs-apache` | v6.5.1 | **v13.1.0** |
| `puppetlabs-stdlib` | v7.1.0 | **v10.0.0** |
| `puppet-systemd` | v3.10.0 | **v9.4.0** |

## Selection policy

Newest tag declaring EL9 support. Where no tag declares EL9, newest tag, annotated inline.

**Metadata upper bounds are not treated as binding.** SIMP's CI tests each module against
the *default branch* of its dependencies (see any `.fixtures.yml`), so those bounds record
when a module was last re-released, not what it was tested against. Enforcing them would
demote `simp-simplib` to a pre-EL9 version to satisfy a 2024-era bound in `simp-haveged`.
See [el9-stale-version-bounds.md](el9-stale-version-bounds.md) - 50 bounds across 13 components.

## Two components pinned by commit, not tag

`simp-adapter` and `rubygem-simp-cli` carry OpenVox/EL9 support only on master; their newest
tags (2.1.1, and 7.0.0 from **2021**) predate OpenVox. Both are load-bearing for the EL9
install path - `simp-adapter` builds `/usr/share/simp/git/puppet_modules`, which the airgap
r10k deployment reads, and `simp-cli` provides `simp config` / `simp bootstrap`.

| component | pin | why |
|---|---|---|
| `simp-adapter` | `a08a14fc76` | *"Ruby 4.0/OpenVox support ... EL8-10"* - untagged |
| `rubygem-simp-cli` | `6ada8ef33f` | *"Support Ruby 4.0 and OpenVox"* - untagged |

Re-pin to tags once upstream cuts releases.

## Six components still without EL9 in metadata

`hocon` 2.0.0, `puppet_authorization` 1.0.0, `puppetdb` 8.1.0, `locales` 5.0.0,
`translate` 2.2.0, `ruby_task_helper` 1.0.0.

All are newest-available. The first three are simp-core dependencies but carry no
OS-specific code (HOCON parsing, auth.conf management, PuppetDB 8 which OpenVox 8
requires). The last three are not simp-core dependencies; `translate` is deprecated
upstream (absorbed into stdlib) and is a removal candidate.

## Upstream bugs found (PR candidates via the `github` remote)

1. `metadata.json` still declared `onyxpoint/gpasswd` after commit `dfc2829` renamed the
   Puppetfile entry to `simp-gpasswd`.
2. `metadata.json` still declared `simp/ntpd` after commit `ab2db7d` removed it from the
   super-release.
3. `metadata.json` declared `puppet-nsswitch`; the Puppetfile ships `trlinkin-nsswitch`.
4. `build/Dockerfiles/scripts/el9/10_dev_packages.sh` installs `genisoimage` with `||:`,
   silently swallowing failure - it was retired from EPEL 9, so it is simply absent.
   `mock` is never installed despite `build/README.md` documenting per-distro `mock.cfg`.

## Build-host notes (macOS)

- `SIMP_RPM_dist` must be set or `rake` will not even list tasks: RPM 6 rejects the empty
  `%dist` that `simp-rake-helpers` derives on non-RPM hosts. Use `SIMP_RPM_dist=.el9`.
- `LANG` must be set (`en_US.UTF-8`) or `rake metadata_lint` dies with
  `Encoding::InvalidByteSequenceError`.
- `~/.rpmmacros` containing a bodyless `%dist` makes every `rpm` call emit errors to stderr
  (non-fatal).

## Verification

```
rake spec              9 examples, 0 failures   (validates all 4 Puppetfiles)
rake check:syntax:yaml 20 files, 0 errors
rake metadata_lint     pass
rake deps:checkout     107/108 pinned exactly, 1 branch-tracked (simp-doc), 0 mismatched
```

## Not yet done

Phase 3 - reconciling the API churn behind these version jumps against the hiera in
`PROD/data/`. The pin set resolves; nothing here proves a catalog compiles.
