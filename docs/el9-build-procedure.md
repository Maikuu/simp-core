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

    # REQUIRED: EL9 hiera + rsync tree for the environment skeleton -- iptables
    # backend, haveged/tcpwrappers off, SSH opened, RedHat/9 rsync shares, and
    # pupmod::openvox_rpm_path so the master never fetches the vendor release
    # RPM (blockers 8, 9, 10, 14). These write into src/assets/environment and
    # src/assets/rsync_data, so they MUST run before pkg:aux.
    bash build/el9-patches/environment-skeleton/apply-el9-hiera.sh
    bash build/el9-patches/rsync-skeleton/apply-el9-rsync.sh

    # REQUIRED when signing with a key other than 'dev': publish the signing
    # public key into the gpgkeys asset. src/assets is gitignored and wiped by
    # deps:checkout, so this is re-applied rather than committed.
    bash build/el9-patches/gpgkeys/apply-el9-gpgkeys.sh prod

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

Current build:

| | |
|---|---|
| built | 2026-09-06 12:21 |
| size | 3231885312 bytes |
| sha256 | `6a3bffd82b469f3d134d9a926fbee59967876cae44f8a4663e643b050985d0d5` |
| signed by | `N3bula SIMP EL9 Release` -- 4096-bit RSA, no expiry, Key ID `2c6548ddc9f64972` |
| `checkisomd5` | "It is OK to use this media." |
| boot | `default simp` |

Verified on a node installed from this media, with **nothing hand-patched**:

| check | result |
|---|---|
| signing key | `N3bula SIMP EL9 Release` imported; **no** `SIMP Development` key |
| package signature | `RSA/SHA256 ... Key ID 2c6548ddc9f64972`; `rpm -K` -> `digests signatures OK` |
| LUKS keyslot PBKDF | `pbkdf2` |
| `fips-mode-setup --check` | "FIPS mode is enabled." -- no inconsistent state |
| `simp config` + `simp bootstrap` | **0 errors** |
| two consecutive `puppet agent -t` | **0 errors, 0 changes** |
| firewall | `iptables` enabled+active, 21 rules, SSH accept; `service iptables status` exits 0 |
| puppetserver | enabled + active; `openvox-server` + `openvox-agent` |
| offline | `openvox8-release` absent; **0** repos pointing at the internet |

Blockers 1, 1b, 4, 4b, 11, 12, 12b, 13 and 14 are closed and proven from the
media rather than by patching a running node.

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

Which `dist/` goes with which patch script:

| patched by | remove |
|---|---|
| `simp-cli/apply-el9-simp-cli.sh` | `src/assets/rubygem_simp_cli/dist` |
| `environment-skeleton/apply-el9-hiera.sh` | `src/assets/environment/dist` |
| `rsync-skeleton/apply-el9-rsync.sh` | `src/assets/rsync_data/dist` |
| `modules/apply-el9-module-patches.sh` | `src/puppet/modules/{clamav,dhcp,freeradius,simp_apache,iptables}/dist` |
| `gpgkeys/apply-el9-gpgkeys.sh` | `src/assets/gpgkeys/dist` |

## Signing with a long-term key instead of `dev`

`build:auto`'s 5th argument is the signing key name. `dev` generates a
**14-day** throwaway (`Expire-Date: 2w`, hardcoded in
`simp-rake-helpers/lib/simp/local_gpg_signing_key.rb`) and copies its public key
to the ISO root -- fine for testing, wrong for production media.

For a long-term key, create `<build_keys_dir>/<name>/` as a GPG homedir holding
the secret key, an exported `RPM-GPG-KEY-*`, a `gengpgkey` file carrying at
least `Name-Email:` (that is what the signer matches on), and the passphrase in
either `gengpgkey`'s `Passphrase:` line or a sibling `password` file.
`build_keys_dir` defaults to `.dev_gpgkeys` and is gitignored, so the key never
reaches the repository -- **and therefore is not backed up by it**.

Then build with that name:

    bundle exec rake "build:auto[<iso>,6.7,/build/SIMP_ISO,false,prod]"

Three things bite when switching away from `dev`:

1. **Existing RPMs are still signed by the old key** and `pkg:checksig` rejects
   them (`ERROR: Untrusted RPMs found in the repository`). Force a re-sign
   first, and note the default `rpm_dir` is `build/SIMP/*RPMS`, which is *not*
   where the distribution RPMs live:

       bundle exec rake "pkg:signrpms[prod,/build/simp-core/build/distributions/RedHat/9/x86_64/SIMP/*RPMS,true]"

2. **`key_prep` deletes `RPM-GPG-KEY-SIMP*` from the ISO root** for a non-dev
   key instead of copying it there, and `checksig` only globs the DVD root
   non-recursively. The public key must go in the gpgkeys asset --
   `gpgkeys/apply-el9-gpgkeys.sh` does this. That directory also becomes
   `SimpRepos/GPGKEYS` on the ISO, which `%post` copies to
   `/var/www/yum/SIMP/GPGKEYS` and imports, so one placement satisfies both.

3. **Check the right signature field.** On EL9's rpm, `%{SIGPGP:pgpsig}` reads
   `(none)` on a perfectly signed package -- the signature lives in
   `%{RSAHEADER:pgpsig}`. Verify with:

       rpm -qp --qf '%{RSAHEADER:pgpsig}\n' <rpm>

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
