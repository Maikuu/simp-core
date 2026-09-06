# EL9: `simp config` / `simp bootstrap` blockers

Findings from the first end-to-end run of `simp config` + `simp bootstrap` on a
RHEL 9.8 host installed from the SIMP EL9 ISO (test host 10.20.31.131).

The ISO itself was already proven: the system boots, SELinux is enforcing, the
LUKS-on-LVM STIG layout is intact, and the SIMP stack installs cleanly
(`openvox-server 8.15.2`, `simp 6.6.0-2`, `simp-adapter 2.3.0`,
`rubygem-simp-cli 8.0.0`, 71 `pupmod-*` RPMs with matching bare git repos in
`/usr/share/simp/git/puppet_modules`).

Everything below is what stood between that and a working puppetserver.

---

## 1. `simp bootstrap` cannot start puppetserver on any JDK >= 9  (BLOCKER)

`simp-cli`'s `java_major_version` only understands the pre-JEP-223 version
string:

```ruby
java_version = `java -version 2>&1`.lines.first
@java_major_version = java_version.strip.split('_')[0].split('.')[1].to_i
```

For Java 8 (`java version "1.8.0_181"`) that yields `8`. For **every** modern
JDK it yields `0`:

```
'openjdk version "17.0.18" 2026-01-20 LTS'
  .split('_')[0]            -> unchanged (no underscore)
  .split('.')               -> ['openjdk version "17', '0', '18" 2026-01-20 LTS']
  [1]                       -> '0'
  .to_i                     -> 0
```

`0` then satisfies the guard immediately below it:

```ruby
if java_major_version && (java_major_version < 8)
  java_args << '-XX:MaxPermSize=256m'
end
```

`-XX:MaxPermSize` was **removed in Java 9** and is fatal there:

```
Unrecognized VM option 'MaxPermSize=256m'
Error: Could not create the Java Virtual Machine.
```

The guard is self-defeating: it fires on exactly the JDKs where the flag is
fatal. EL8 shipped Java 8, so it never triggered. EL9 ships Java 17, so
puppetserver enters a systemd restart loop and bootstrap hangs in
"Waiting up to 5 minutes for puppetserver to respond" until it gives up.

**Fix** (parse both schemes):

```ruby
if (m = java_version.match(%r{version "(\d+)(?:\.(\d+))?}))
  @java_major_version = (m[1] == '1') ? m[2].to_i : m[1].to_i
end
```

Verified: parses `17`, the flag is no longer added, puppetserver starts and
reports "ready to handle requests".

This is an upstream `simp/rubygem-simp-cli` bug and affects any EL8 host that
has been moved to a newer JDK, not just EL9.

**Shipped by** `build/el9-patches/simp-cli/apply-el9-simp-cli.sh` (patch 1). It
was originally proven by hand on the test host; the patch script is what puts it
into the `rubygem-simp-cli` RPM on the ISO.

---

## 1b. `simp bootstrap` can never see a healthy puppetserver  (BLOCKER)

With the JDK fix in place puppetserver starts, reports "ready to handle
requests", listens on 8150 and answers `GET /status/v1/services` with 200 --
and `simp bootstrap` still spins until it gives up:

```
> Waiting up to 5 minutes for puppetserver to respond
ERROR: The Puppet Server did not start within 5 minutes.
```

`puppetserver_running?` swallows every exception (`rescue StandardError`) and in
the wait loop it is called with `quiet = true`, so the reason is never printed.
Calling the real method directly returns `false`; the exception it hides is:

```
EOFError: end of file reached
  net/http/response.rb:635:in `ensure in read_chunked'
```

The trigger is `HighLine.colorize_strings`, called at the top of
`simp/cli/logging.rb`. Bisecting a fresh Ruby process:

| required | result |
| --- | --- |
| nothing | `code=200 len=836` |
| `logger` | `code=200 len=836` |
| `highline` | `code=200 len=836` |
| `highline/import` | `code=200 len=836` |
| **`HighLine.colorize_strings`** | **`EOFError`** |

Deterministic: 8/8 requests fail after `colorize_strings`, 8/8 succeed without
it, reproduced repeatedly. `curl` with the same client cert always returns
200/836.

It is purely client-side. With `set_debug_output` the request bytes and the
server's response bytes are **identical** in both cases; the two runs diverge
only in how the client parses the chunked body. Where the healthy client reads
the 2-byte chunk trailer and gets `"\r\n"`, the colorized client reads `"HT"`
-- the beginning of a second response -- and then parses the rest as garbage.
`GET /status/v1/simple` fails differently but for the same reason:
`Net::HTTPBadResponse: wrong chunk size line:`.

`colorize_strings` installs `String#method_missing` (and a properly-guarded
`respond_to_missing?`) process-wide via `HighLine::StringExtensions`. It
overrides no method Net::HTTP relies on, and `respond_to?` is unaffected -- so
the precise mechanism inside highline 2.0.3 on Ruby 3.2 is not yet pinned down.
What is certain is the trigger, that it is deterministic, and that it breaks
Net::HTTP's chunked-transfer parsing for the whole process.

Why EL9 and not EL8: puppetserver 8 (Jetty 12) returns this endpoint
`Transfer-Encoding: chunked` with `Content-Encoding: gzip`. The old stack did
not, so the latent defect never surfaced.

**Fix** -- take the status line from the streamed response and never read the
body, which avoids the broken parser entirely:

```ruby
server_conn.start do |http|
  http.request(Net::HTTP::Get.new('/status/v1/services')) do |response|
    status = (response.code == '200')
  end
end
```

Verified: `puppetserver_running?(8150)` returns `true` and bootstrap proceeds.

A `HEAD` request also avoids the body but puppetserver answers it `403`, so it
is not usable here.

Separately, `puppetserver_running?` should not `rescue StandardError` silently
in the retry loop -- five minutes of a hidden `EOFError` is what made this cost
hours instead of minutes.

**Shipped by** `build/el9-patches/simp-cli/apply-el9-simp-cli.sh` (patch 2).

---

## 2. r10k is absent  (BLOCKER)

`simp-cli` deploys every Puppet module by shelling out to r10k
(`lib/simp/cli/environment/puppet_dir_env.rb`):

```ruby
r10k = 'r10k'
r10k = '/usr/share/simp/bin/r10k' if File.executable?('/usr/share/simp/bin/r10k')
r10k_cmd = "#{r10k} puppetfile install -v info"
```

`Puppetfile.el9` excluded `simp-vendored_r10k` on the grounds that nothing
`Requires:` it. That was wrong in effect — no RPM declares the dependency, but
`simp config` cannot deploy a single module without it, so the whole airgap
workflow stops there. The first `simp config` run died on that exact line.

r10k **5.0.3** installs and runs cleanly on OpenVox's Ruby 3.2.11. Its closure
resolves to 28 gems, of which OpenVox's Ruby already provides 16 (including the
only three with native extensions -- `json`, `racc`, `fiddle`). The 12 that must
be vendored are all pure Ruby, so `BuildArch: noarch` still holds:

    minitar 1.1.0            net-http 0.9.1           faraday-net_http 3.4.4
    faraday 2.14.3           faraday-follow_redirects 0.5.0
    puppet_forge 6.2.0       log4r 1.1.10             jwt 2.10.3
    gettext-setup 1.1.1      cri 2.15.12              colored2 4.0.3
    r10k 5.0.3

This is a much smaller and simpler closure than the EL8 pin (r10k 3.14.2), which
needed the whole `gettext`/`fast_gettext`/`locale`/`text` chain.

Two things block rebuilding the component as-is:

* `Gemfile` pins `gem 'r10k', '3.11'` (gemspec requires Ruby `~> 2.3`) and
  `gem 'puppet', '~> 6.2'`, so `bundle install` cannot resolve on a modern
  build host.
* `Rakefile` calls `ERB.new(template, nil, '-')`. The three-argument form was
  removed in Ruby 3.1; it must become `ERB.new(template, trim_mode: '-')`.

---

## 3. The ISO package keep-list is scoped for install, not for bootstrap

`9-simp_pkglist.txt` is ours -- upstream ships no pkglist for EL8, which is why
the RHEL 8 ISO carries the entire unpruned DVD. The EL9 list was derived from
the *installed system's runtime closure*, which is why it made a 2.9GB ISO but
cannot satisfy `simp bootstrap`.

Missing from the pruned repo (verified with `dnf list --available`):

| package | status on RHEL 9 |
| --- | --- |
| `389-ds-base` | on the DVD, pruned away |
| `postfix` | on the DVD, pruned away |
| `postgresql-server` | on the DVD, pruned away |
| `policycoreutils-python-utils` (`semanage`) | on the DVD, pruned away |
| `openldap-servers` | **removed from RHEL 8+** — SIMP uses 389-DS (`simp_ds389`) |
| `haveged` | **EPEL only on EL9** — `rng-tools` is the EL9 path |
| `clamav`, `incron` | **EPEL only** |
| `iptables-services` | renamed — EL9 ships `iptables-nft-services` |
| `puppetdb` | OpenVox renames this to `openvoxdb` |

This is the same class of bug as the earlier `lvm2` miss (anaconda's
*install-time* needs were not in a list built from *runtime* state), one phase
later: bootstrap-time needs are not in it either.

The exact set is being measured empirically rather than guessed -- the full
unpruned RHEL 9.8 DVD is served over HTTP to the test host and the package delta
across a real `simp bootstrap` is captured.

---

## 4. FIPS is only half-enabled: LUKS Argon2 vs `fips-mode-setup`

`/var/log/anaconda/ks-post.log`:

```
The following encrypted devices use Argon2 PBKDF: /dev/sda3(luks-...)
Aborting fips-mode-setup because of that.
```

EL9's cryptsetup defaults LUKS2 keyslots to **Argon2id**, which is not a
FIPS-approved KDF, so `fips-mode-setup --enable` refuses. The result is a
system that looks FIPS-enabled but is not:

* `/proc/sys/crypto/fips_enabled` = `1` (the kernel got `fips=1` from grub)
* `/etc/system-fips` — **absent**
* `update-crypto-policies --show` — `DEFAULT`, not `FIPS`

**Fixed** in `ks/diskdetect.sh` by forcing the KDF at format time:

```
part pv.01 ... --encrypted --pbkdf=pbkdf2 --passphrase=...
```

---

## 4b. `simp bootstrap` forces FIPS on past the Argon2 safety check

**Correction:** an earlier revision of this section claimed the Argon2 keyslot
left the system unbootable. That was an inference from the host going dark after
its post-bootstrap reboot, and it was WRONG -- the machine booted fine; it was
unreachable for a network reason (see the firewalld note below). What follows is
what was actually observed and is still worth fixing; the "unbootable" claim was
not.

`pupmod-simp-fips` (init.pp) runs

```puppet
exec { 'dracut_rebuild':
  command     => "command fips-mode-setup ${_fips_mode_setup_opt} || dracut -f --regenerate-all",
  refreshonly => true,
  ...
}
```

On a disk whose LUKS keyslot uses Argon2, `fips-mode-setup --enable` **aborts**:

```
The following encrypted devices use Argon2 PBKDF: /dev/sda3(luks-...)
Aborting fips-mode-setup because of that.
```

That abort is a safety check -- it exists to stop you putting the machine into a
state where it cannot unlock its own root volume. Because the command exits
non-zero, the `||` fires and `dracut -f --regenerate-all` rebuilds every
initramfs regardless, while the crypto policy has already moved to `FIPS`
(observed: `update-crypto-policies --show` went `DEFAULT` -> `FIPS` across
bootstrap).

Observed on the test host: `simp bootstrap` completed RC=0 and the box rebooted,
autorelabelled and rebooted again **without trouble** -- it boots and unlocks its
root volume normally. So on EL9 the Argon2 keyslot does not prevent boot.

What it does do is defeat the safety check: the machine ends up running with a
`FIPS` crypto policy that `fips-mode-setup` explicitly refused to grant, and with
every initramfs regenerated by the fallback branch. That is a compliance and
reproducibility problem, not a boot problem.

### Prevention

The `--pbkdf=pbkdf2` change in `ks/diskdetect.sh` (section 4) makes
`fips-mode-setup --enable` succeed on its own terms, so the `||` fallback never
runs and FIPS is genuinely, checkably enabled rather than forced.

### If you do need to convert an existing disk

```
cryptsetup luksConvertKey --pbkdf pbkdf2 --key-file /etc/.cryptcreds /dev/sda3
```

(`/boot/disk_creds` holds the same passphrase on the unencrypted /boot.)

### Also worth fixing upstream

`pupmod-simp-fips` 2.0.2 declares

```puppet
package { 'dracut-fips': ensure => $fips_package_status }   # 'installed' on EL8+
```

**`dracut-fips` does not exist on RHEL 9** -- FIPS was folded into the base
`dracut` package (`/usr/lib/dracut/modules.d/01fips/`). Verified against the
RHEL 9.8 DVD. The module's own metadata claims `RedHat ['8','9','10']` support,
so this is an EL9 gap in a module that advertises EL9.

---

## 4c. Disk layout: site sizing, and the missing biosboot partition

Upstream SIMP's EL9 kickstart ships much smaller volumes than this site runs.
Compared against the site's EL8 kickstart
(`VFDE_PLATFORM/ks_config/diskdetect.sh`):

| volume | upstream EL9 | site EL8 | **shipped here** |
| --- | --- | --- | --- |
| swap | 1G | 8G | **8G** |
| `/` | 10G | 40G | **40G** |
| `/tmp` | 2G | 15G | **15G** |
| `/home` | 1G | 15G | **15G** |
| `/var/log` | 4G | 15G | **20G** |
| `/var/log/audit` | 1G | 15G | **20G** |
| `/var` | 1G +grow | 40G +grow | **40G +grow** |

`/var/log` and `/var/log/audit` are raised above the EL8 values because EL9's
auditd rule set is heavier and a full audit volume can halt a STIG-configured
host.

Fixed volumes total **118G**, so this layout needs roughly a **125GB minimum
disk**; `/var` takes the remainder (~40G on a 160GB disk). The upstream defaults
total only ~24G, so anything sized against those will not fit this scheme.

**`/var/tmp` is deliberately not a logical volume.** `simp::mountpoints::tmp`
mounts `TmpVol` a second time at `/var/tmp` after install -- both fstab entries
point at `/dev/mapper/VolGroup00-TmpVol` -- so `/tmp` and `/var/tmp` share one
volume and sizing `/tmp` sizes both.

### biosboot was missing

The EL9 tree had no `biosboot` partition; the site's EL8 kickstart has one.
Without it a GPT disk on a legacy-BIOS machine will not boot, and it fails
silently rather than erroring. Restored to match EL8:

```
part biosboot --fstype=biosboot --size=1 --ondisk ${DISK} --asprimary --fsoptions=nosuid,nodev
```

It is unused when booting UEFI, which is how the test VM boots, so this had not
surfaced.

Verified with `ksvalidator -v RHEL9`, which also confirms `--pbkdf=pbkdf2`
(section 4) is valid RHEL9 kickstart syntax.

---

## 5. Ed25519 SSH keys cannot authenticate

Unrelated to bootstrap but worth knowing before locking yourself out:

```
sshd: userauth_pubkey: signature algorithm ssh-ed25519 not in PubkeyAcceptedAlgorithms
```

The FIPS-constrained algorithm list admits only RSA (`rsa-sha2-*`) and ECDSA.
Use an ECDSA or RSA key on these hosts.

Also: the ISO creates the local admin user with home `/var/local/simp`, which is
labelled `var_t`. sshd will not read `authorized_keys` there until the context
is fixed:

```
semanage fcontext -a -t ssh_home_t '/var/local/simp/\.ssh(/.*)?'
restorecon -R /var/local/simp/.ssh
```

(`semanage` is itself missing from the pruned repo — see §3 — so `chcon -R -t
ssh_home_t` is the stopgap.)

---

## 6. Minor: RPM GPG key import fails during `%post`

```
error: /var/www/yum/SIMP/GPGKEYS/RPM-GPG-KEY-redhat-release: import read failed(2).
```

`errno 2` is ENOENT, but the file is present and correct afterwards (and is
byte-identical to `/var/www/yum/RedHat/9.8/x86_64/RPM-GPG-KEY-redhat-release`),
so this is an ordering problem in `%post` — the import runs before the key is
copied into place. `rpm -qa gpg-pubkey` on the installed system shows only the
two SIMP keys; the Red Hat release key never gets imported.

Not fatal today because the repo definitions point `gpgkey=` at a valid file and
dnf imports on demand, but it should be ordered correctly.

---

## 7. Puppet 8 legacy facts must be re-enabled  (BLOCKER)

Once bootstrap could talk to puppetserver, catalog compilation failed:

```
Puppet Evaluation Error: Error while evaluating a Function Call,
   is not a supported operating system.
  (file: .../modules/nsswitch/manifests/params.pp, line: 211)
```

Note the **empty** OS name. `trlinkin-nsswitch 2.3.0` does
`case $facts['operatingsystem']` (params.pp:6) -- a legacy top-level fact.
Puppet 8 stopped providing legacy facts by default
(`include_legacy_facts = false`), so the case matched nothing and fell through
to `default: { fail(...) }`. The module's own metadata lists `RedHat ['6','7','8','9']`,
so this is not an EL9 support gap in the module -- it is a Puppet 8 fact change.

Of the 71 deployed modules, **`nsswitch` is the only one** that references legacy
top-level facts, so the blast radius is small.

**Fix applied:**

```
puppet config set include_legacy_facts true --section main
```

The alternative is to carry a patched `nsswitch` using `$facts['os']['name']`.
Re-enabling the facts is the lower-risk choice for now and is the documented
Puppet 8 compatibility path; revisit when the module layer is modernised.

This needs to be set by the ISO (kickstart or `simp config`), not by hand.

---

## 8. `simp_options::tcpwrappers` must be false on EL9  (BLOCKER)

Next compilation failure:

```
Could not find class ::tcpwrappers for puppet.svilla.dev
  (file: .../modules/rsync/manifests/server/global.pp, line: 45)
```

`tcp_wrappers`/`libwrap` were removed in RHEL 8, so `pupmod-simp-tcpwrappers` is
deliberately not in the EL9 pin set (and `build/rpm/dependencies.yaml` carries
`:ignores: pupmod-simp-tcpwrappers` for nfs, rsyslog, simp_snmpd, vsftpd and
ssh). Dropping the RPM dependency is not enough: the Puppet code still does
`include 'tcpwrappers'`, guarded by a hiera toggle.

Every consumer reads the same global and defaults it to **false**:

```puppet
Boolean $tcpwrappers = simplib::lookup('simp_options::tcpwrappers',
                                       { default_value => false })
```

but the default `simp` scenario turns it on --
`data/scenarios/simp.yaml:38: simp_options::tcpwrappers: true` -- and
`simp config` copies that into the generated `data/hosts/<fqdn>.yaml`.
(`simp_lite` and `remote_access` already set it false.)

Four deployed modules reference it: `rsync`, `rsyslog`, `ssh`, `stunnel`.

**Fix applied** -- in the host's hiera:

```yaml
simp_options::tcpwrappers: false   # EL9: tcp_wrappers/libwrap removed from RHEL 8+
```

The durable fix belongs upstream: the `simp` scenario data should select false
on EL8+, or `simp config` should emit false when the target OS is EL8+.

---

## 9. `simp_options::haveged` must be false on EL9  (BLOCKER, and it can lock you out)

The default `simp` scenario sets `simp_options::haveged: true`, and `simp config`
copies that into the generated `data/hosts/<fqdn>.yaml`. **haveged is not in RHEL 9.**
Verified against the RHEL 9.8 DVD (BaseOS + AppStream):

| package | on the RHEL 9.8 DVD |
| --- | --- |
| `haveged` | **absent** (dropped after EL7; RHEL 9 relies on the kernel CRNG and ships `rng-tools`) |
| `clamav`, `clamav-update` | **absent** (EPEL only) |
| `incron` | **absent** (EPEL only) |
| `tcp_wrappers`, `tcp_wrappers-libs` | **absent** (removed in RHEL 8) |
| `iptables-services` | **absent** — renamed `iptables-nft-services` |
| `rng-tools` | present |
| `389-ds-base`, `postfix`, `postgresql-server` | present |
| `policycoreutils-python-utils` (`semanage`) | present |
| `audit` | present |

haveged is reached from code that always runs — `pupmod/manifests/init.pp:268`
does `include 'haveged'` when the catalyst is set, and `pupmod` is what
configures the puppetserver. `Package['haveged']` then cannot be satisfied and
the puppet run aborts.

`clamav` is safe by default (`simp::server` defaults `simp_options::clamav` to
false) and `simp_options::firewall` already selects firewalld
(`iptables::use_firewalld: true` in the scenario), so those two need no change.

### This failure mode locks you out of the box

With `simp_options::firewall: true`, a run that dies partway can leave firewalld
active with only *some* rules applied. Observed on the test host: after the
aborted run, **port 8140 was open and port 22 was filtered** — puppetserver
reachable, SSH not. ICMP was dropped too, so the host looked dead.

Recovery requires console access:

```
puppet agent --disable "manual recovery"
firewall-cmd --add-service=ssh
firewall-cmd --runtime-to-permanent
```

Fix applied in `build/el9-patches/environment-skeleton/apply-el9-hiera.sh`,
which writes the per-OS hiera file `data/RedHat/9.yaml`:

```yaml
simp_options::haveged: false
simp_options::tcpwrappers: false
```

and removes both keys from the `data/hosts/*.yaml` templates, because the
per-node layer outranks per-OS and `simp config` copies those templates verbatim.

---

## 10. Firewall backend: iptables on EL9 needs three keys, not one

Site decision for this build: **iptables, not firewalld.** The `simp` scenario
ships `iptables::use_firewalld: true`, so it has to be overridden.

Flipping that one key is not enough on RHEL 9. `pupmod-simp-iptables 8.0.4` has
no `RedHat-9` data tier, so RHEL 9 falls through to `data/os/RedHat.yaml`:

```yaml
---
# EL8+
iptables::install::ipv4_package: iptables-services
iptables::install::ipv6_package: iptables-services
```

**`iptables-services` does not exist on RHEL 9** -- it was renamed
`iptables-nft-services` (verified against the RHEL 9.8 DVD). The module's
metadata claims `RedHat ['8','9','10']`, so this is another module that
advertises EL9 while its data still assumes EL8 -- same shape as the
`dracut-fips` gap in section 4b.

The rename alone would *appear* to work, because `iptables-nft-services` carries
`Provides: iptables-services`, so dnf resolves it. But Puppet verifies a package
by **resource name** (`rpm -q iptables-services`), which never matches the
installed `iptables-nft-services` -- so `stdlib::ensure_packages` would attempt
the install on every run and never converge. Naming the real package keeps it
idempotent.

`iptables-nft-services` ships `iptables.service` and `ip6tables.service`, which
is what `iptables::service` manages, so nothing else in the module changes.

Applied in `data/RedHat/9.yaml`:

```yaml
iptables::use_firewalld: false
iptables::install::ipv4_package: iptables-nft-services
iptables::install::ipv6_package: iptables-nft-services
```

`iptables::use_firewalld: true` also had to be removed from the
`data/hosts/*.yaml` templates -- the per-node layer outranks per-OS, and
`simp config` copies those templates verbatim, so leaving it there would defeat
the override. `simp_options::firewall: true` is deliberately kept: that enables
firewall management at all; `use_firewalld` only selects the backend.

Note that on RHEL 9 this is `iptables-nft` -- the legacy iptables syntax over an
nftables backend; the xtables kernel path is gone. SIMP's semantics and
`iptables::listen::tcp_stateful` are unaffected.

### Two packages RHEL 9 does not install that SIMP's iptables path needs

Both are on the RHEL 9.8 DVD; neither is installed by default, and neither was
in the keep-list until this was traced:

| package | provides | symptom without it |
| --- | --- | --- |
| `chkconfig` | `/sbin/chkconfig` | `Error: /Stage[main]/Iptables::Service/Service[iptables]: Provider redhat is not functional on this host` |
| `initscripts` | `/etc/init.d/functions` | `Could not start Service[iptables]: '/sbin/service iptables start' returned 1: /etc/init.d/iptables: line 22: /etc/init.d/functions: No such file or directory` |

RHEL 9 installs `initscripts-service` (which supplies `/sbin/service`) but not
`initscripts` (which supplies the shell function library). SIMP's
`iptables::service` writes its own SysV script at `/etc/init.d/iptables` and
declares the service with `provider => 'redhat'`, so it needs both.

### SIMP does not open SSH -- you must, or the first run locks you out

`iptables::rules::base` allows loopback, ESTABLISHED/RELATED and ICMP echo, then
ends the chain with LOG + DROP. **Nothing in the SIMP module set opens port 22** --
`pupmod-simp-ssh` has no firewall integration at all.

On the default (firewalld) path this is masked. On the iptables path, the first
real `puppet agent -t` writes a ruleset with no SSH accept and starts the
service -- locking out every remote session. Observed exactly that here: the
generated `/etc/sysconfig/iptables` opened 80, 443, 8140, 8141 and 8730, and
nothing else.

The site's EL8 production hiera solves this with its own
`profile::iptables::internal`, which does `iptables::listen::all` trusting the
node's own subnet. A freshly bootstrapped ISO server has no control-repo yet, so
it needs a rule of its own. The SIMP-native way to declare one from hiera alone,
with no profile module, is the `iptables::ports` hash:

```yaml
iptables::ports:
  22:
    proto: tcp
```

which becomes `iptables::listen::tcp_stateful { 'port_22': dports => [22] }` and
inherits `trusted_nets` from `simp_options::trusted_nets` -- i.e. whatever was
answered during `simp config`. Verified in the compiled catalog:

```
-m state --state NEW -m tcp -p tcp -s 10.20.0.0/16 -m multiport --dports 22 -j ACCEPT
```

**Any EL9 image that ships `use_firewalld: false` must also ship this**, or every
fresh install firewalls itself off on its first puppet run.

### Result

With the trio, the two packages and the SSH rule in place, a real `puppet agent -t`
converges: `iptables` active **and enabled**, `firewalld` stopped and disabled,
SSH preserved throughout.

### Why this came up

After the post-bootstrap reboot the test host answered nothing -- no SSH, no
ICMP, not even the puppetserver port that had been reachable earlier. The host
was up and healthy at the console the whole time; SIMP's firewalld zone
(`99_simp`, `target: DROP`) was dropping everything. Every allow rule SIMP
writes is a rich rule bound to an ipset:

```
rule family="ipv4" source ipset="simp-69Pwcu..." service name="simp_tcp_allow_puppetca" accept
```

so if those ipsets are not restored before the zone activates at boot, nothing
matches and the DROP target takes everything. Not confirmed -- firewalld was
stopped before it could be checked -- but worth knowing that the shipped
firewalld default can lock a machine out on first reboot.

---

## 11. `network::eth` does not exist on EL9  (BLOCKER)

`simp config` dies partway through the questionnaire:

```
>> Applying: Configure a network interface...
[FACTER_ipaddress=XXX puppet apply --modulepath=... -e "network::eth{'ens18':
  bootproto => 'none', onboot => true, ipaddr => '10.20.31.132', ... }"]
  failed with exit status 1:
  Error: Evaluation Error: Error while evaluating a Resource Statement,
  Unknown resource type: 'network::eth' (line: 1, column: 1) on node puppet.mnt.dev
 Failed
Configuration of ens18 network interface failed
```

`pupmod-simp-network` is not in the EL9 pin set -- RHEL 9 removed the
`network-scripts` package whose `ifcfg-*` files `network::eth` writes. Confirmed
absent from the pin set, from `src/puppet/modules`, and from the built RPM set.

`ConfigureNetworkAction` sets `@die_on_apply_fail = true`, so this is fatal
rather than a warning.

**This is not a defaults problem.** `CliSetUpNIC` recommends `'yes'`, but the
step fails identically whether the answer is accepted or typed by hand -- the
resource type simply does not exist. Telling the operator to answer `'no'` is a
workaround, not a fix.

**Fix** (`build/el9-patches/simp-cli/apply-el9-simp-cli.sh`, patch 3):

* `CliSetUpNIC` gains `network_module_available?`, which tests the modulepath
  (plus `SIMP_MODULES_INSTALL_PATH`) for `network/manifests`. When the module is
  absent it sets `@skip_query = true` and recommends `'no'`, so the question is
  never asked and the trap cannot be walked into.
* `ConfigureNetworkAction#apply` makes the same check and returns
  `:unnecessary` -- a non-error status that bypasses the `die_on_apply_fail`
  raise -- because an answers file can pre-assign `set_up_nic: yes` and reach
  the action even when the query is skipped.

Nothing is lost by skipping it. The `false` branch of the `network_setup`
scenario still collects hostname, IP, netmask, gateway and DNS into hieradata;
it just does not try to re-apply them to a NIC the kickstart already configured.

On EL8, where the module is present, behaviour is unchanged.

---

## `simp config` notes

`simp config` runs fully non-interactively with `-f -D`, but two things are not
obvious:

* An interrupted earlier run leaves `/root/.simp/.simp_conf.yaml`, and the
  resume prompt is asked **before** `-D` takes effect — the run dies with
  "Input terminated!". Remove that file first.
* `simp_grub::password` accepts a plaintext password only when *prompted*. When
  supplied as a command-line `KEY=VALUE`, the value is pre-assigned and the
  validator requires a pre-computed hash matching `^grub\.pbkdf2.*` — generate
  it with `grub2-mkpasswd-pbkdf2`.

`simp bootstrap` also prompts to remove an existing ssldir; pass `-r`.
