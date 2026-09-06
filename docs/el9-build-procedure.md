# Building the SIMP EL9 ISO — reproducible procedure

Produces `SIMP-6.6.0-2.el9-RedHat-9.8-x86_64.iso` (~3.0 GB) from a RHEL 9.8
Binary DVD. Branch: `6.7.0-RHEL-9.8`.

## Build host

Must be **Linux x86_64** — the pipeline is rpmbuild/mock based. The reference host
is the AlmaLinux 9.8 VM at `10.20.31.130` (`/build`, a dedicated 500 GB XFS disk).

    sudo dnf install -y epel-release
    sudo dnf config-manager --set-enabled crb
    sudo dnf install -y rpm-build rpmdevtools rpm-devel rpm-sign yum-utils \
      ruby-devel util-linux openssl augeas-libs createrepo_c git gnupg2 \
      libicu-devel libxml2-devel libxslt-devel which genisoimage isomd5sum \
      xorriso mock gcc gcc-c++ libyaml-devel libffi-devel sqlite-devel

    # Ruby 3.3 — EL9 ships 3.0, but the Gemfile requires >= 3.2
    sudo dnf module reset -y ruby && sudo dnf module enable -y ruby:3.3
    sudo dnf install -y ruby ruby-devel rubygem-bundler
    sudo gem install bundler          # EL9's bundler 2.5.22 has a Ruby 3.3 URI bug

## Environment variables (all required)

| var | value | why |
|---|---|---|
| `SIMP_RPM_dist` | `.el9` | RPM 6 rejects the empty `%dist` derived on non-RPM hosts |
| `SIMP_BUILD_distro` | `RedHat,9,x86_64` | the host self-detects as `AlmaLinux/9`; the tree is `RedHat/9` |
| `LANG` | `en_US.UTF-8` | else `metadata_lint` dies with an encoding error |

## Steps

    cd /build/simp-core
    rm -f Gemfile.lock                      # lockfiles are host-specific and gitignored
    bundle config set --local path vendor/bundle
    bundle install

    # REQUIRED: six pre-existing gem bugs block EL9. Re-run after any bundle install.
    bash build/el9-patches/apply-gem-patches.sh

    export SIMP_RPM_dist=.el9 SIMP_BUILD_distro=RedHat,9,x86_64 LANG=en_US.UTF-8
    bundle exec rake 'deps:checkout[el9]'

    # REQUIRED: four simp-cli defects that only bite on EL9 (blockers 1, 1b, 11).
    # MUST run after deps:checkout -- it wipes src/assets -- and before pkg:aux,
    # which is what packages the gem into rubygem-simp-cli.
    bash build/el9-patches/simp-cli/apply-el9-simp-cli.sh

    # REQUIRED: $facts['environment'] is empty on Puppet 8 (blocker 13).
    # MUST run after deps:checkout -- it wipes src/puppet/modules -- and before
    # pkg:modules, which is what packages them into RPMs.
    bash build/el9-patches/modules/apply-el9-module-patches.sh

    bundle exec rake 'pkg:key_prep[dev]'    # dev signing key; expires in 14 days
    bundle exec rake pkg:modules
    bundle exec rake pkg:aux

### External packages

Only `openvox-server` and `openvox-agent` are absent from the RHEL 9.8 DVD.
Everything else the kickstart needs resolves from BaseOS/AppStream.

    R=build/distributions/RedHat/9/x86_64/yum_data/reposync/puppet
    mkdir -p "$R" && cd "$R"
    dnf download --disablerepo='*' --enablerepo=openvox8 openvox-server openvox-agent
    curl -sSLo RPM-GPG-KEY-openvox https://yum.voxpupuli.org/GPG-KEY-openvox.pub
    createrepo_c .

### Build the ISO

    export SIMP_BUILD_prompt=no SIMP_BUILD_checkout=no SIMP_BUILD_docs=no
    export SIMP_BUILD_staging_dir=/build/SIMP_ISO_STAGING
    export SIMP_PKGLIST_FILE=$PWD/build/distributions/RedHat/9/x86_64/DVD/9-simp_pkglist.txt
    bundle exec rake "build:auto[/build/rhel-9.8-x86_64-dvd.iso,6.7,/build/SIMP_ISO,false,dev]"

**Known:** `build:auto` raises `no implicit conversion of nil into String` in its
wrapper *after* `iso:build` succeeds. Running `iso:build` directly works and is how
the current ISO was produced:

    T=build/distributions/RedHat/9/x86_64/DVD_Overlay/SIMP-6.6.0-2.el9-RedHat-9-x86_64.tar.gz
    bundle exec rake "iso:build[$T,/build/SIMP_ISO_STAGING,true]"

## Verifying the result

    checkisomd5 <iso>                    # expect "It is OK to use this media"
    isoinfo -R -f -i <iso> | grep -E 'isolinux.bin|efiboot.img|BOOTX64.EFI'
    mount -o loop,ro <iso> /mnt && grep '^default' /mnt/isolinux/isolinux.cfg

Current build -- carries the four simp-cli fixes, the chkconfig/initscripts
kickstart fix (blocker 12) and the `$environment` module fix (blocker 13):

| | |
|---|---|
| built | 2026-09-06 01:02 |
| size | 3231877120 bytes |
| sha256 | `6ba1c3927d6715ce461caaf89518a0f14db81d1b7ba4ae0c43ab55b0a30f45ee` |
| `checkisomd5` | "It is OK to use this media." |
| repos | BaseOS 636, AppStream 259, SimpRepos/SIMP 127, SimpRepos/puppet 4 |
| boot | `default simp` |

Verified by mounting the ISO and checking the shipped artifacts directly (not
`dist/`): the four simp-cli fixes in `rubygem-simp-cli`, `chkconfig` and
`initscripts` in the kickstart's `%packages`, and zero remaining
`$facts['environment']` occurrences across the `clamav`, `dhcp`, `freeradius`
and `simp_apache` RPMs.

The previous ISO has been installed end to end: `simp config` and
`simp bootstrap` both completed without hand-patching, which is what surfaced
blockers 12 and 13. Those two fixes are in this ISO but have only been proven
by patching the running node, not yet by a fresh install from this media.
The likeliest next failures are in `auto.cfg`'s `%post`: FIPS enablement (EL9 uses
`crypto-policies-scripts`/`fips-mode-setup`, and `fipscheck` no longer exists) and
`simp_filesystem.repo` generation.


---

## Gotchas that will cost you a rebuild

### 1. Changing a component's source does NOT reliably trigger a rebuild

`require_rebuild?` decides whether to rebuild each component. It does not always
notice edited sources: after changing `src/assets/environment` and
`src/assets/rsync_data`, the build produced RPMs whose *tarballs* contained the
new files but whose *RPMs* did not, and the copy that reached the ISO had a
different md5 again from the one in `dist/`.

The documented escape hatch does not work either:

```ruby
always_require_rebuild = ENV.select { |x| x =~ %r{SIMP_BUILD_PKG_require_rebuild}i }
if !always_require_rebuild.empty? && (always_require_rebuild =~ %r{\A(yes|always)\Z}i)
```

`ENV.select` returns a **Hash**, and `Hash =~ Regexp` is always nil, so the
guard can never fire — `SIMP_BUILD_PKG_require_rebuild=yes` is a no-op.

**Always delete the component's `dist/` after editing its source:**

```bash
rm -rf src/assets/<component>/dist build/SIMP/RPMS build/SIMP/SRPMS
```

Then verify the RPM actually contains the change before building the ISO:

```bash
rpm -qlp src/assets/environment/dist/*.noarch.rpm | grep RedHat/9.yaml
rpm -qlp src/assets/rsync_data/dist/*.noarch.rpm | grep -oE 'rsync/RedHat/[A-Za-z0-9]+' | sort -u
```

A component with no bundle yet (`rsync_data` had none) needs
`bundle config set with development && bundle install` in its own directory
first, since `pkg:rpm` there runs under the component's Gemfile.

### 2. vendored_r10k must be hidden from `pkg:aux`

`pkg:aux` globs `src/assets/*` and builds everything it finds. `vendored_r10k`'s
upstream Rakefile cannot run on Ruby 3.3, and its `CLEAN` list includes `dist`,
so letting it run destroys the prebuilt RPMs and fails the build.

`build()` only builds a directory that has a `metadata.json` **or** a `Rakefile`;
with neither it prints a warning and moves on, leaving `dist/` intact. So the
build script moves the Rakefile aside for the duration:

```bash
mv src/assets/vendored_r10k/Rakefile src/assets/vendored_r10k/Rakefile.el9-held
# ... build ...
mv src/assets/vendored_r10k/Rakefile.el9-held src/assets/vendored_r10k/Rakefile
```

Expected, harmless output during the run:

```
Warning: '.../src/assets/vendored_r10k' could not be built (not a pupmod & no Rakefile!)
```

### 3. `build:auto` now works end to end

The note that `build:auto` raises `no implicit conversion of nil into String`
after `iso:build` succeeds is **fixed** by gem patch 6 (per-variant repodata).
`build:auto` completes with RC=0 and there is no longer any need to run
`iso:build` by hand.
