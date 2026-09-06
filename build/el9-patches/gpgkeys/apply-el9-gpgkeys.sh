#!/bin/bash
# Publish the build's signing public key into the gpgkeys asset.
#
# src/assets is gitignored and `rake deps:checkout` wipes it, so this has to be
# re-applied rather than committed. Run after deps:checkout, before pkg:aux.
#
# Usage:  bash build/el9-patches/gpgkeys/apply-el9-gpgkeys.sh [<key name>]
#         key name defaults to $SIMP_SIGNING_KEY, else 'prod'
#
# WHY THIS IS NEEDED
#
# When the build signs with a key other than 'dev', pkg:key_prep deliberately
# does the opposite of the dev flow: instead of copying the public key to the
# ISO root, it DELETES RPM-GPG-KEY-SIMP* from there. Upstream assumes the
# production public key is already shipped as part of the gpgkeys asset.
#
# Nothing else puts it there, so without this step:
#
#   * pkg:checksig imports public keys from src/assets/gpgkeys/GPGKEYS and from
#     the DVD root only (non-recursive) -- it will not find the key, every RPM
#     fails verification, and the build aborts with
#         ERROR: Untrusted RPMs found in the repository
#   * even if it built, installed nodes could not verify the packages: %post
#     copies RPM-GPG-KEY-SIMP* out of the ISO into /var/www/yum/SIMP/GPGKEYS
#     and imports them, and the key would simply not be present.
#
# Putting it in the gpgkeys asset satisfies both: checksig reads that directory,
# and the asset becomes SimpRepos/GPGKEYS on the ISO.
#
# The key is copied out of the signing keydir rather than committed, so no
# site-specific material lands in the repository.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"

KEY="${1:-${SIMP_SIGNING_KEY:-prod}}"
KEYDIR="${SIMP_PKG_build_keys_dir:-$ROOT/.dev_gpgkeys}/$KEY"
DEST="$ROOT/src/assets/gpgkeys/GPGKEYS"

if [ "$KEY" = 'dev' ]; then
  echo "  key is 'dev' -- key_prep copies it to the ISO root itself; nothing to do"
  exit 0
fi

[ -d "$KEYDIR" ] || { echo "signing key dir not found: $KEYDIR" >&2; exit 1; }
[ -d "$DEST" ]   || { echo "gpgkeys asset not checked out: $DEST" >&2; exit 1; }

found=0
for pub in "$KEYDIR"/RPM-GPG-KEY-*; do
  [ -e "$pub" ] || continue
  # public keys only -- never copy private material
  grep -q 'BEGIN PGP PUBLIC KEY BLOCK' "$pub" || {
    echo "  skipping $(basename "$pub"): not an ASCII-armored public key"
    continue
  }
  found=$((found + 1))
  base="$(basename "$pub")"
  if cmp -s "$pub" "$DEST/$base"; then
    echo "  already published: $base"
  else
    install -m 0640 "$pub" "$DEST/$base"
    echo "  published: $base"
  fi
done

[ "$found" -gt 0 ] || { echo "no RPM-GPG-KEY-* public key in $KEYDIR" >&2; exit 1; }

echo "  --- gpgkeys asset now holds ---"
ls "$DEST" | sed 's/^/    /'
