# EL9 stale version bounds

Components pinned in `Puppetfile.el9` whose version exceeds an upper bound declared
in some other module's `metadata.json`.

**These are not known incompatibilities.** SIMP's own CI tests each module against the
*default branch* of its dependencies (see any module's `.fixtures.yml`), so these bounds
reflect when a module was last re-released, not what it was tested against. Honouring
them would demote core components (notably `simp-simplib`) to non-EL9 versions.

## Handling

1. **RPM build** - add `:requires:` overrides in `build/rpm/dependencies.yaml` for any
   component whose generated RPM `Requires` would otherwise be unsatisfiable.
2. **Upstream** - each row is a candidate metadata.json PR to SIMP via the `github` remote.
3. **Verify** - Phase 6 acceptance runs are the real compatibility gate, not these bounds.

## Bounds exceeded (50 across 13 components)

### `puppet-augeasproviders_core` pinned at **5.0.0**

| capped by | declared bound |
|---|---|
| `herculesteam-augeasproviders_ssh` | `>= 3.2.0 < 5.0.0` |

### `puppet-augeasproviders_grub` pinned at **6.0.0**

| capped by | declared bound |
|---|---|
| `treydock-kdump` | `>= 2.3.1 <6.0.0` |

### `puppet-systemd` pinned at **9.4.0**

| capped by | declared bound |
|---|---|
| `simp-haveged` | `>= 4.0.2 < 8.0.0` |
| `voxpupuli-snmp` | `>= 2.5.1 < 9.0.0` |

### `puppetlabs-concat` pinned at **10.0.0**

| capped by | declared bound |
|---|---|
| `puppetlabs-apache` | `>= 2.2.1 < 10.0.0` |
| `puppetlabs-postgresql` | `>= 4.1.0 < 10.0.0` |
| `puppetlabs-puppet_authorization` | `>= 1.1.1 < 10.0.0` |

### `puppetlabs-hocon` pinned at **2.0.0**

| capped by | declared bound |
|---|---|
| `puppetlabs-puppet_authorization` | `>= 0.9.3 < 2.0.0` |

### `puppetlabs-stdlib` pinned at **10.0.0**

| capped by | declared bound |
|---|---|
| `puppet-kmod` | `>= 5.0.0 < 10.0.0` |
| `puppet-systemd` | `>= 9.0.0 < 10.0.0` |
| `puppetlabs-apache` | `>= 4.13.1 < 10.0.0` |
| `puppetlabs-concat` | `>= 9.0.0 < 10.0.0` |
| `puppetlabs-inifile` | `>= 4.13.0 < 10.0.0` |
| `puppetlabs-java` | `>= 4.13.1 < 10.0.0` |
| `puppetlabs-motd` | `>= 2.1.0 < 10.0.0` |
| `puppetlabs-postgresql` | `>= 9.0.0 < 10.0.0` |
| `puppetlabs-puppet_authorization` | `>= 4.6.0 < 10.0.0` |
| `puppetlabs-puppetdb` | `>= 4.13.1 < 10.0.0` |
| `simp-compliance_markup` | `>= 8.0.0 < 10.0.0` |
| `simp-haveged` | `>= 8.0.0 < 10.0.0` |
| `simp-vox_selinux` | `>= 9.0.0 < 10.0.0` |
| `treydock-kdump` | `>= 4.13.0 <10.0.0` |
| `trlinkin-nsswitch` | `>= 4.25.0 < 9.0.0` |
| `voxpupuli-chrony` | `>= 4.25.1 < 10.0.0` |
| `voxpupuli-firewalld` | `>= 4.25.0 < 10.0.0` |
| `voxpupuli-gitlab` | `>= 4.13.1 < 10.0.0` |
| `voxpupuli-snmp` | `>= 5.2.0 < 10.0.0` |
| `voxpupuli-yum` | `>= 9.0.0 < 10.0.0` |

### `simp-iptables` pinned at **9.0.0**

| capped by | declared bound |
|---|---|
| `simp-dhcp` | `>= 6.5.3 < 9.0.0` |
| `simp-freeradius` | `>= 6.5.3 < 9.0.0` |
| `simp-libreswan` | `>= 6.5.3 < 9.0.0` |
| `simp-named` | `>= 6.5.3 < 9.0.0` |
| `simp-pupmod` | `>= 6.5.3 < 9.0.0` |
| `simp-simp` | `>= 6.5.3 < 9.0.0` |
| `simp-simp_apache` | `>= 6.5.3 < 9.0.0` |
| `simp-simp_gitlab` | `>= 6.5.3 < 9.0.0` |
| `simp-stunnel` | `>= 6.5.3 < 9.0.0` |

### `simp-rsyslog` pinned at **10.0.0**

| capped by | declared bound |
|---|---|
| `simp-dhcp` | `>= 7.6.0 < 10.0.0` |
| `simp-rsync` | `>= 7.6.0 < 10.0.0` |
| `simp-simp_apache` | `>= 7.6.0 < 10.0.0` |
| `simp-simp_rsyslog` | `>= 7.6.0 < 10.0.0` |

### `simp-simp_firewalld` pinned at **3.0.0**

| capped by | declared bound |
|---|---|
| `simp-libreswan` | `>= 0.1.3 < 3.0.0` |
| `simp-simp_ds389` | `>= 0.1.3 < 3.0.0` |

### `simp-simp_options` pinned at **3.0.1**

| capped by | declared bound |
|---|---|
| `simp-dconf` | `>= 1.6.1 < 3.0.0` |
| `simp-simp` | `>= 1.6.1 < 3.0.0` |

### `simp-simplib` pinned at **7.0.1**

| capped by | declared bound |
|---|---|
| `simp-compliance_markup` | `>= 4.9.0 < 6.0.0` |
| `simp-haveged` | `>= 4.9.0 < 5.0.0` |

### `simp-ssh` pinned at **9.1.0**

| capped by | declared bound |
|---|---|
| `simp-simp` | `>= 6.11.0 < 9.0.0` |
| `simp-simp_gitlab` | `>= 6.11.0 < 9.0.0` |

### `simp-sudo` pinned at **7.0.0**

| capped by | declared bound |
|---|---|
| `simp-simp` | `>= 5.1.1 < 7.0.0` |
