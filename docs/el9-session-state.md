# EL9 port — working state

Resume point. Everything here is verified unless marked otherwise.

## Where it stands

A RHEL 9.8 SIMP ISO builds, installs, and produces a working puppetserver.
`simp bootstrap` was driven to **RC=0** on a real install, with `puppetserver`
active on 8140, 389-DS up, and a catalog compiling and applying.

**Current ISO** (rebuild #4, the one to install from):

    /build/SIMP_ISO/SIMP-6.6.0-2.el9-RedHat-9.8-x86_64.iso   on 10.20.31.130
    sha256 7cd9f245fa5f9ebe951a505e7da45d1324bf2bc57b5b44a3dac0d4f9aafee0a4
    3248455680 bytes   checkisomd5: OK

Verified on the media: 4 previously-missing packages + deps present, partition
minimums fit (127G of 158.6G), repodata matches actual counts in all repos,
14 vendored-r10k RPMs, EL9 hiera inside the environment RPM, rsync skeleton on
RedHat/9, openvoxdb present but not installed.

## Machines

| host | role | access |
| --- | --- | --- |
| 10.20.31.130 | build VM, AlmaLinux 9.8, `/build` (500G) | `ssh -i ~/.ssh/id_ed25519_simp_el9 simp@…`, passwordless sudo |
| 10.20.31.131 | test install target | user `simp`, password `4rfv%TGB4rfv%TGB`; ECDSA key `~/.ssh/id_ecdsa_simp_el9` |

**Ed25519 SSH keys do not work** on the installed hosts — FIPS restricts
PubkeyAcceptedAlgorithms to RSA/ECDSA. Use the ECDSA key.
After bootstrap, `sudo` needs a TTY (`ssh -tt`), and the `simp` user's home is
`/var/local/simp`, not `/home/simp`.

## Repos and what is committed

| path | state |
| --- | --- |
| `SIMP_RHEL9/simp-core` | **committed + pushed** — `Maikuu/simp-core` branch `6.7.0-RHEL-9.8`, HEAD `6ec44b4` |
| `SIMP_RHEL9/untested/` | **edited, NOT committed** — has_key fix, EL9 hiera, tftpboot, metadata bumps |
| `SIMP_RHEL9/control-repo/` | **edited, NOT committed** — `Puppetfile.simp` regenerated (71/71 pins resolve) |
| everything outside `SIMP_RHEL9/` | reference only — **never edit** (`PROD/`, `2.8/`, `bitbucket/`, `RHEL8 SIMP ISO/`) |

Commits do NOT carry AI-attribution trailers, per `Work/CLAUDE.md`.

## Traps that have each cost a rebuild

1. **A package in `simp_ks_base` must ALSO be in `9-simp_pkglist.txt`.**
   Otherwise the prune deletes it and the install stops with "missing packages".
   This bit twice with lvm2 and friends.

2. **`--size` on a `--grow` logvol is a MINIMUM.** Anaconda satisfies every
   minimum before growing anything. Sum them all, including the growable one,
   against the VG — or you get "new lv is too large to fit in free space".

3. **Editing a component's source does not reliably trigger a rebuild.**
   `rm -rf src/assets/<c>/dist build/SIMP/RPMS` and then *verify the RPM
   contains the change* with `rpm -qlp`. `SIMP_BUILD_PKG_require_rebuild=yes`
   is dead code (`ENV.select` returns a Hash; `Hash =~ Regexp` is always nil).

4. **Never run `deps:checkout`** — it wipes the component changes made by the
   `build/el9-patches/*` scripts. The build script sets `SIMP_BUILD_checkout=no`.

5. **`vendored_r10k`'s Rakefile must be moved aside during the build** or
   `pkg:aux` tries to build it, fails on Ruby 3.3, and its `CLEAN` list destroys
   the prebuilt RPMs. `/build/run-iso-build.sh` handles this.

6. **A green build does not mean your changes are in the ISO.** Check inside the
   RPMs, not just RC=0.

## Build

    ssh simp@10.20.31.130
    bash /build/run-iso-build.sh          # ~3 min, logs to /build/buildlogs/
    cat /build/buildlogs/status

Re-run `bash build/el9-patches/apply-gem-patches.sh` after any `bundle install`.
The dev GPG signing key expires ~2026-09-19; regenerate with
`rake pkg:key_prep[dev]`.

## Next up

1. **Install from the current ISO.** Watch, in order: boots unaided (no BLS
   hand-patch) → `simp config` gets past "Running r10k" → `simp bootstrap`
   RC=0 → iptables up with SSH still reachable.
2. **Push `untested/` and `control-repo/`** to the site git server — nothing
   reaches a node until then.
3. **A sound repoclosure check.** The attempt in this session was unsound: the
   test repo's metadata lacked arch-qualified provides
   (`libcrypto.so.3()(64bit)`), so its "unresolved deps" were an artifact.
   Do it against the finished ISO's own repodata instead.
4. **Upstream PRs** — 7 build-gem defects, plus two simp-cli bugs (the JDK
   version parse and the HighLine/Net::HTTP status check). See
   `el9-bootstrap-blockers.md`.

## Reference docs

    el9-bootstrap-blockers.md        every blocker + evidence (the main one)
    el9-build-procedure.md           reproducible build + gotchas
    el9-control-repo-migration.md    pointing the control-repo at EL9
    build/el9-patches/README.md      the 7 gem patches
