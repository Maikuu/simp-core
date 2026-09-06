#!/bin/bash
#
# Install the full ISO/RPM build toolchain: rpmbuild tooling, ruby-devel and
# compilers, ISO-creation tools, fonts, an SSH server for CI, and helpers.
#
# Used by: ISO build images (SIMP_EL*_Build.dockerfile)
#
set -euo pipefail

dnf install -y epel-release ||:
dnf config-manager --set-enabled crb
dnf install -y rpm-build rpmdevtools rpm-devel rpm-sign yum-utils
dnf install -y ruby-devel
dnf install -y util-linux openssl augeas-libs createrepo_c git gnupg2 libicu-devel libxml2 libxml2-devel libxslt libxslt-devel which procps-ng
# ISO tooling. genisoimage is in EPEL and is REQUIRED: it ships /usr/bin/isoinfo,
# which simp-rake-helpers checks for in build:auto. xorriso provides mkisofs but
# NOT isoinfo, so it is not a substitute.
dnf install -y genisoimage isomd5sum xorriso
# mock: isolated RPM builds (build/README.md documents a per-distro mock.cfg)
dnf install -y mock
dnf install -y python3 fontconfig libjpeg-devel zlib-devel openssl-devel
dnf install -y libyaml libyaml-devel autoconf gcc gcc-c++ glibc-devel readline-devel libffi-devel automake libtool bison sqlite-devel pinentry

# Helper packages
dnf install -y rubygems vim-enhanced jq

# SSH for CI testing; initscripts not available on EL10
if [ -d /etc/ssh ]; then /bin/cp -a /etc/ssh /root; fi
dnf install -y openssh-server
if [ -d /root/ssh ]; then /bin/cp -a /root/ssh /etc && /bin/rm -rf /root/ssh; fi
