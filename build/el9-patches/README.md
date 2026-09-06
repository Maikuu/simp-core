# EL9 build-host patches

Six patches to the build gems are required to run `rake build:auto` on an EL9
host. All are pre-existing bugs exposed either by modern Ruby or by EL8+ media
layout, not by EL9 specifically.

Apply with:

    bash build/el9-patches/apply-gem-patches.sh

Re-run after any `bundle install` — that restores the pristine gems.

| # | gem | problem | fix |
|---|---|---|---|
| 1 | `simp-build-helpers 0.1.1` | `File.exists?` removed in Ruby 3.2 (`release_mapper.rb:41`) | `File.exist?` |
| 2 | `simp-rake-helpers 6.0.1` | Psych 4 safe-loads by default; `last_rpm_build_metadata.yaml` holds `Time` and `Symbol` (`pkg.rb:213`) | `permitted_classes: [Time, Symbol]` |
| 3 | `simp-rake-helpers 6.0.1` | `FileUtils.ln` given a positional options hash; Ruby 3 requires keyword args (`tar.rb` x3) | `force: true` |
| 4 | `simp-rake-helpers 6.0.1` | `vermap.yaml` maps SIMP 6 to EL 6/7/8 only. `iso:build` silently `next`s an EL9 tree, then raises the misleading "No ISO was built!" | added `"9"` |
| 5 | `simp-rake-helpers 6.0.1` | `iso:build` only prunes the base OS when reposync is **inactive**, so any build supplying a `reposync/` dir ships the entire DVD (15 GB vs 3 GB) | prune in both branches |
| 6 | `simp-rake-helpers 6.0.1` | `prune_packages()` regenerates only ONE repo, at basepath. EL8+ media are split into per-variant repos (`BaseOS/`, `AppStream/`), each with its own `repodata/`, which is left **stale** after pruning | regenerate every dir that has a `repodata/` |

Patches 4, 5 and 6 are the most consequential. 4 is the single most important:
without it the EL9 ISO build appears to run to completion and then fails with a
message that gives no hint of the cause. It is very likely the reason no EL9
SIMP ISO exists upstream. 5 is why the first successful EL9 ISO came out at 15 GB: `prune_packages()` already excludes the
`SIMP` and `SimpRepos` trees, so reposync content was never at risk from pruning
-- upstream simply never calls prune in that branch. Pruning removed 6,923
packages and took the image from 15 GB to 3.0 GB.

6 is what made the pruned ISO unbootable. With the root repodata regenerated but
`BaseOS/repodata` and `AppStream/repodata` left advertising the deleted packages,
anaconda stops mid-install with "Some packages from local repository have
incorrect checksum". The same bug also raises "no implicit conversion of nil into
String" during the build, because EL8+ media have no `repodata/` at the ISO root
so the comps glob returns nil -- easy to dismiss as cosmetic; it is the same
defect.

## Upstream status

**1 and 2 are clean upstream bugs.** `simp-build-helpers` has not been released
since **2016** (0.1.1, 2016-09-28) and cannot work on Ruby >= 3.2 as shipped —
yet simp-core's Gemfile requires Ruby 3.2-4.0, so the two are mutually exclusive
out of the box. Note the maintainer's fork carries a `drop-simp-build-helpers`
branch, which suggests upstream already intends to remove the dependency.

**A former 7th patch has been removed.** It stripped `simp-vendored-r10k` out of
`tar:validate`'s required-RPM list, because `pkg-r10k` pins r10k 3.11 (gemspec:
ruby `~> 2.3`) and cannot build on any Ruby the current Gemfile allows.

### r10k is required, and is now built

The earlier conclusion here -- that the ISO could simply ship without SIMP's
vendored r10k because "nothing in the install path needs it" -- was **wrong**.
No RPM declares the dependency, but `simp config` deploys every Puppet module by
shelling out to r10k (`simp-cli`,
`lib/simp/cli/environment/puppet_dir_env.rb`). Without it, `simp config` dies on
that line and nothing can be deployed. Confirmed on the EL9 test install.

Build the RPMs with:

    bash build/el9-patches/vendored-r10k/build-el9.sh

See `build/el9-patches/vendored-r10k/README.md`. In particular, do **not**
work around this with `gem install r10k` into OpenVox's `GEM_HOME` -- that
shadows Ruby's bundled gems for every puppet process on the box and breaks
unrelated simp-cli code paths.


## Component re-basing for EL9

Three of the checked-out components need EL9 changes that `rake deps:checkout`
would otherwise wipe, so each has a re-runnable script:

| script | what it does |
| --- | --- |
| `vendored-r10k/build-el9.sh` | builds the `simp-vendored-r10k` RPM set (upstream cannot build on Ruby 3.x) |
| `environment-skeleton/apply-el9-hiera.sh` | writes `data/RedHat/9.yaml` (haveged, tcpwrappers, iptables backend, SSH rule) and de-pins the host templates |
| `rsync-skeleton/apply-el9-rsync.sh` | replaces `rsync/RedHat/{7,8}` with `RedHat/9` and rewrites `.rsync.facl` |

### Why the rsync change is functional, not cosmetic

`simp-rsync-skeleton` 7.1.1 ships `rsync/RedHat/7`, `rsync/RedHat/8` and
`rsync/RedHat/Global`. There is no `RedHat/9`, and EL9 clients need one:

* the `simp_rsync_environments` fact walks the tree for `.shares` files,
* `simp::server::rsync_shares` turns that into rsync shares,
* clients request a share named after their own OS **and major version** --
  `named/manifests/chroot.pp:39` builds
  `"bind_dns_..._${facts['os']['name']}_${facts['os']['release']['major']}"`,
  which is `..._RedHat_9` on EL9.

So DNS rsync on an EL9 client asks for a share that does not exist. `RedHat/7`
and `RedHat/8` are byte-identical (16 files each, just the bind skeleton), so 8
is used as the base for 9. `RedHat/Global` is kept -- it holds dhcpd, tftpboot,
apache, snmp and freeradius, and is version-independent.

`rsync/.rsync.facl` is installed by the RPM as `%config` and carries one ACL
stanza per path, so it is rewritten too: the 26 `RedHat/7` stanzas are dropped
and the 26 `RedHat/8` ones are re-pointed at `RedHat/9` (50 stanzas total,
verified against the on-disk tree).
