#!/bin/sh

DISK=""

for disk in \
  /sys/block/sd[a-z] \
  /sys/block/sd[a-z][a-z] \
  /sys/block/cciss!c[0-9]d[0-9] \
  /sys/block/cciss!c[0-9]d[0-9][0-9] \
  /sys/block/cciss!c[0-9][0-9]d[0-9] \
  /sys/block/cciss!c[0-9][0-9]d[0-9][0-9] \
  /sys/block/xvd[a-z] \
  /sys/block/xvd[a-z][a-z] \
  /sys/block/vd[a-z] \
  /sys/block/vd[a-z][a-z] \
  /sys/block/hd[a-z] \
  /sys/block/nvme[0-9]n[0-9] \
  ;
do
  [ -d "$disk" ] || continue

  # Ignore removable and virtual devices.

  if [ -f "$disk"/removable ]; then
    if read removable junk < "$disk"/removable; then
      [ "$removable" != "0" ] && continue
    fi
  fi

  if [ -f "$disk"/device/vendor -a -f "$disk"/device/model ]; then
    if read vendor junk < "$disk"/device/vendor && \
       read model junk < "$disk"/device/model; then
      [ "$vendor" != "VMware" -a "$model" = "Virtual" ] && continue
    fi
  fi

  # Found the first disk.

  # Convert cciss!c0d0 to cciss/c0d0
  DISK="`basename $disk | sed 's@!@/@g'`"
  break
done

touch /tmp/part-include

# To automatically decrypt your system, the cryptfile needs to be located in an
# unencrypted portion of the system. This is *not* secure but does allow users
# to go in later and change the password without needing to reformat their
# systems.

# For EL6
if [ ! -d /boot ]; then
  mkdir /boot
fi

grep -q simp_disk_crypt /proc/cmdline || grep -q simp_crypt_disk /proc/cmdline
encrypt=$?

if [ $encrypt -eq 0 ]; then
  cat /dev/random | LC_CTYPE=C tr -dc "[:alnum:]" | head -c 256 > /boot/disk_creds
  passphrase=`cat /boot/disk_creds`

  echo $DISK > /boot/crypt_disk
fi

# This parses out some command line options generally only used by the
# DVD, but available to PXE clients as well.

simp_opt=`awk -F "simp_opt=" '{print $2}' /proc/cmdline | cut -f1 -d' '`

if [ "$simp_opt" == "prompt" ]; then
  # This is the recommended workaround for a RedHat bug (BZ#1954408) where
  # the installation program attempts to perform automatic partitioning, even
  # when you do not specify any partitioning commands in the kickstart file.
  # https://access.redhat.com/documentation/en-us/red_hat_enterprise_linux/8/html/8.4_release_notes/known-issues#known-issue_installer-and-image-creation
  # This will cause the "Installation Destination" icon to show an "Kickstart
  # insufficient" error, which, in turn, will force the user to partition the
  # disks manually.
  echo "reqpart" > /tmp/part-include
else
  cat << EOF > /tmp/part-include
clearpart --all --initlabel --drives=${DISK}
# biosboot is required for GPT disks on legacy-BIOS machines. It is unused when
# booting UEFI, but its absence is a silent no-boot on BIOS bare metal. Matches
# the EL8 kickstart.
part biosboot --fstype=biosboot --size=1 --ondisk ${DISK} --asprimary --fsoptions=nosuid,nodev
part /boot --fstype=ext4 --size=1024 --ondisk ${DISK} --asprimary --fsoptions=nosuid,nodev
part /boot/efi --fstype=efi --size=400 --ondisk ${DISK} --asprimary
EOF

# In EL8 (8.2) the partitioning fails if --encrypted  is used and the size=1.
# The size was set to equal the sum of all the logical partitions (20G) to prevent this.
# You can probably use a smaller size but we have not, at this time, determined how
# small the initial size of the partion can to be to prevent the error.

  if [ $encrypt -eq 0 ]; then
    # --pbkdf=pbkdf2 is REQUIRED on EL9.
    #
    # EL9's cryptsetup defaults LUKS2 keyslots to Argon2id, which is not a
    # FIPS-approved KDF. `fips-mode-setup --enable` (run later in %post)
    # detects this and refuses:
    #
    #   The following encrypted devices use Argon2 PBKDF: /dev/sdaN(luks-...)
    #   Aborting fips-mode-setup because of that.
    #
    # The result is a half-enabled system: the kernel gets fips=1 from the
    # boot loader, but /etc/system-fips is never written and the crypto
    # policy stays DEFAULT. Forcing pbkdf2 at format time keeps the keyslot
    # FIPS-compatible so fips-mode-setup completes.
    echo "part pv.01 --size=20480 --grow --ondisk ${DISK} --encrypted --pbkdf=pbkdf2 --passphrase=${passphrase}" >> /tmp/part-include
  else
    echo "part pv.01 --size=1 --grow --ondisk ${DISK}" >> /tmp/part-include
  fi
fi

if [ "$simp_opt" != "prompt" ]; then
  cat << EOF >> /tmp/part-include
volgroup VolGroup00 pv.01
# Site sizing, derived from the EL8 ISO and then adjusted against measured usage
# on a bootstrapped EL9 puppetserver. Upstream SIMP ships far smaller values
# (swap 1G, / 10G, /tmp 2G, /home 1G, /var/log 4G, audit 1G).
#
#   /               60G  - /opt/puppetlabs lives here (there is no separate /opt).
#                          40G is ample today (2.4G used) but PuppetDB keeps its
#                          PostgreSQL data under /opt/puppetlabs/server/data, so
#                          the headroom is for that.
#   /var/log        20G  - logs are what actually fill unexpectedly.
#   /var/log/audit   5G  - deliberately NOT larger. auditd.conf caps the
#                          directory at max_log_file(24M) * num_logs(5) = 120M
#                          with max_log_file_action=rotate, so 5G is ~40x the
#                          hard ceiling and leaves room to raise retention 30x.
#   /tmp            15G  - see the /var/tmp note below.
#   /home           15G
#   swap             8G
#   /var         --grow  - ~35G on a 160GB disk. Stays small on a puppetserver
#                          because simp::yum::repo::local_*::enable_repo are
#                          false there; the yum mirror is a separate host.
#
# NOTE: /var/tmp is NOT a logical volume. simp::mountpoints::tmp mounts TmpVol a
# second time at /var/tmp after install, so /tmp and /var/tmp share this 15G.
#
# IMPORTANT: on a --grow volume, --size is the MINIMUM, not "the remainder".
# Anaconda must be able to satisfy the sum of every --size before it grows
# anything, so /var's floor is deliberately small (4G). With /var at 40960 the
# minimums summed to 163G against ~158.6G of VG on a 160GB disk and the install
# died with:
#     "new lv is too large to fit in free space"
#
# Sum of minimums: 8 + 60 + 15 + 15 + 4 + 20 + 5 = 127G, so this fits any disk
# of roughly 130GB or more. /var then grows into whatever is left -- about 35G
# on a 160GB disk, more on larger ones.
logvol swap --fstype=swap --name=SwapVol --vgname=VolGroup00 --size=8192
logvol / --fstype=ext4 --name=RootVol --vgname=VolGroup00 --size=61440 --fsoptions=iversion
logvol /tmp --fstype=ext4 --name=TmpVol --vgname=VolGroup00 --size=15360 --fsoptions=nosuid,noexec,nodev
logvol /home --fstype=ext4 --name=HomeVol --vgname=VolGroup00 --size=15360 --fsoptions=nosuid,noexec,nodev,iversion
logvol /var --fstype=ext4 --name=VarVol --vgname=VolGroup00 --size=4096 --grow
logvol /var/log --fstype=ext4 --name=VarLogVol --vgname=VolGroup00 --size=20480 --fsoptions=nosuid,noexec,nodev
logvol /var/log/audit --fstype=ext4 --name=VarLogAuditVol --vgname=VolGroup00 --size=5120 --fsoptions=nosuid,noexec,nodev
EOF
fi
