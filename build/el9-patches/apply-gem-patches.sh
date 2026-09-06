#!/bin/bash
# EL9 build-host gem patches.
#
# simp-rake-helpers 6.0.1 and simp-build-helpers 0.1.1 predate Ruby 3.2/Psych 4.
# The EL9 build host runs Ruby 3.3 (the Gemfile requires >= 3.2), so `rake
# build:auto` fails without these. Re-run after any `bundle install`, which
# restores the pristine gems.
#
# Usage:  bash build/el9-patches/apply-gem-patches.sh
#
# NOTE: an earlier revision carried a 7th patch that stripped
# 'simp-vendored-r10k' out of tar:validate's required-RPM list, because
# pkg-r10k could not build on Ruby 3.x. That is no longer needed -- the RPM is
# now built by build/el9-patches/vendored-r10k/build-el9.sh, and r10k is NOT
# optional: simp config shells out to it to deploy every module.
set -euo pipefail

GEMS="$(bundle show simp-rake-helpers 2>/dev/null | xargs dirname)"
SRH="$GEMS/simp-rake-helpers-6.0.1"
SBH="$GEMS/simp-build-helpers-0.1.1"
[ -d "$SRH" ] || { echo "simp-rake-helpers not found under $GEMS"; exit 1; }

# ---------------------------------------------------------------- patch 1
# Ruby 3.2 removed File.exists?. Only one call site.
F="$SBH/lib/simp/build/release_mapper.rb"
if grep -q 'File\.exists?(' "$F" 2>/dev/null; then
  sed -i 's/File\.exists?(/File.exist?(/' "$F"
  echo "  [1/7] release_mapper.rb: File.exists? -> File.exist?"
else
  echo "  [1/7] release_mapper.rb: already patched"
fi

# ---------------------------------------------------------------- patch 2
# Psych 4 safe-loads by default. last_rpm_build_metadata.yaml contains Time and
# Symbol values, so the bare YAML.load_file raises Psych::DisallowedClass.
F="$SRH/lib/simp/rake/build/pkg.rb"
if grep -q 'metadata = YAML.load_file(mf)$' "$F"; then
  sed -i 's|metadata = YAML.load_file(mf)$|metadata = YAML.load_file(mf, permitted_classes: [Time, Symbol])|' "$F"
  echo "  [2/7] pkg.rb: YAML.load_file gains permitted_classes"
else
  echo "  [2/7] pkg.rb: already patched"
fi

# ---------------------------------------------------------------- patch 3
# Ruby 3 requires keyword args for FileUtils.ln; these pass a positional hash.
F="$SRH/lib/simp/rake/build/tar.rb"
if grep -q ', { :force => true })' "$F"; then
  python3 - "$F" <<'PY2'
import sys
p=sys.argv[1]; s=open(p).read()
open(p,'w').write(s.replace(', { :force => true })', ', force: true)'))
PY2
  echo "  [3/7] tar.rb: FileUtils.ln positional hash -> keyword arg (3 sites)"
else
  echo "  [3/7] tar.rb: already patched"
fi

# ---------------------------------------------------------------- patch 4
# vermap.yaml maps SIMP major versions to supported base-OS majors. SIMP 6 is
# mapped to EL 6/7/8 only, so iso:build SILENTLY skips an EL9 tree ("next") and
# then reports the misleading "Error: No ISO was built!".
F="$SRH/lib/simp/rake/build/vermap.yaml"
if grep -q '^"6": \["6","7","8"\]$' "$F"; then
  sed -i 's/^"6": \["6","7","8"\]$/"6": ["6","7","8","9"]/' "$F"
  echo "  [4/7] vermap.yaml: SIMP 6 now maps to EL9"
else
  echo "  [4/7] vermap.yaml: already patched"
fi

rm -f "$SRH"/lib/simp/rake/build/*.orig "$SBH"/lib/simp/build/*.orig 2>/dev/null || true

# ---------------------------------------------------------------- patch 5
# iso:build only prunes the base OS when reposync is NOT active. Any build that
# supplies a reposync/ directory therefore ships the ENTIRE base OS DVD (15GB vs
# 3GB for EL9). prune_packages() already excludes the SIMP and SimpRepos trees,
# so reposync content is safe -- run the prune in both branches.
F="$SRH/lib/simp/rake/build/iso.rb"
if grep -q "^            else$" "$F" && ! grep -q "Run it in both cases" "$F"; then
  python3 - "$F" <<'PY2'
import sys
p=sys.argv[1]; s=open(p).read()
old = """                cp_r(src, target, :verbose => verbose)
              end
            else
              # Prune unwanted packages"""
new = """                cp_r(src, target, :verbose => verbose)
              end
            end

            # Prune unwanted packages in BOTH branches. prune_packages()
            # excludes SIMP and SimpRepos, so reposync content is untouched.
            # Run it in both cases.
            if true
              # Prune unwanted packages"""
if old in s:
    open(p,'w').write(s.replace(old, new, 1))
PY2
  echo "  [5/7] iso.rb: prune now runs with reposync active"
else
  echo "  [5/7] iso.rb: already patched"
fi

rm -f "$SRH"/lib/simp/rake/build/*.orig "$SBH"/lib/simp/build/*.orig 2>/dev/null || true

# ---------------------------------------------------------------- patch 6
# prune_packages() regenerates only ONE repo, at basepath ('.' or 'Server').
# That was right for EL6/EL7 media, but EL8+ splits the DVD into per-variant
# repos (BaseOS/, AppStream/), each with its own repodata/. After pruning, the
# per-variant repodata is left STALE -- still advertising every package that was
# just deleted -- and anaconda aborts the install with
#     Some packages from local repository have incorrect checksum
# It also crashes on EL8+ media: there is no repodata/ at the ISO root, so the
# comps glob returns nil and cp(nil, ...) raises
#     no implicit conversion of nil into String
# (which is easy to dismiss as cosmetic -- it is not, it is the same bug).
#
# Regenerate every directory that actually has a repodata/.
F="$SRH/lib/simp/rake/build/iso.rb"
if grep -q "basepath = '\.'" "$F"; then
  python3 - "$F" <<'PY6'
import sys
p = sys.argv[1]
s = open(p).read()
start_marker = "            # Recreate the now-pruned repos\n"
end_marker   = "              rm('simp_comps.xml')\n            end\n"
i = s.index(start_marker)
j = s.index(end_marker, i) + len(end_marker)
new = """            # Recreate the now-pruned repos.
            #
            # EL8+ splits the media into per-variant repos (BaseOS, AppStream),
            # each with its own repodata/. The original code regenerated only a
            # single repo at basepath ('.' or 'Server') -- correct for EL6/EL7,
            # but on EL8+ it leaves the per-variant repodata STALE, still
            # advertising every package that was just deleted. Anaconda then
            # fails with "Some packages from local repository have incorrect
            # checksum". It also crashed on EL8+ media: there is no repodata/ at
            # the ISO root, so the comps glob returned nil and cp(nil, ...)
            # raised "no implicit conversion of nil into String".
            #
            # Regenerate every repo that actually has a repodata/ directory.
            repo_dirs = Dir.glob('*/repodata').map { |x| File.dirname(x) }
            repo_dirs << '.' if File.directory?('repodata')
            if (File.basename(from_dir) =~ %r{^RHEL}) && !Dir.glob('Server/*.rpm').empty?
              repo_dirs << 'Server'
            end
            repo_dirs = repo_dirs.uniq.reject { |d| exclude_dirs.include?(File.basename(d)) }

            repo_dirs.each do |repo_dir|
              Dir.chdir(repo_dir) do
                comps = Dir.glob('repodata/*comps*.xml').first
                if comps
                  cp(comps, 'simp_comps.xml')
                  sh %(#{mkrepo} -g simp_comps.xml .)
                  rm('simp_comps.xml')
                else
                  sh %(#{mkrepo} .)
                end
              end
            end
"""
open(p, 'w').write(s[:i] + new + s[j:])
PY6
  echo "  [6/7] iso.rb: regenerate per-variant repodata (BaseOS/AppStream)"
else
  echo "  [6/7] iso.rb: already patched"
fi

rm -f "$SRH"/lib/simp/rake/build/*.orig "$SBH"/lib/simp/build/*.orig 2>/dev/null || true

# ---------------------------------------------------------------- patch 7
# build_rakefile_rpm() builds each asset by shelling out to `rake pkg:rpm` in
# the component directory. When the first attempt fails it runs, inside an
# UNBUNDLED environment:
#
#     bundle config set with 'development' && bundle install
#
# ...and then re-runs plain `rake` -- ignoring the bundle it just installed.
# Plain rake resolves gems from the user/system store, so it activates the
# NEWEST simp-rake-helpers available rather than the one the component pinned.
#
# src/assets/utils pins `simp-rake-helpers (~> 5.24.0)` and its Rakefile does
# `require 'simp/rake/ci'`. That file exists in 5.24.0 but was REMOVED in 6.0.1,
# so with 6.0.1 present as a user gem the build dies with:
#
#     LoadError: cannot load such file -- simp/rake/ci
#     Error in .../src/assets/utils running SIMP_BUILD_version=... rake pkg:rpm
#
# Verified directly: `rake pkg:rpm` fails in that directory, `bundle exec rake
# pkg:rpm` succeeds. Use the bundle that was just installed.
F="$SRH/lib/simp/rake/build/pkg.rb"
if grep -q 'output = `#{cmd} 2>&1`' "$F"; then
  python3 - "$F" <<'PY7'
import io, sys
p = sys.argv[1]
s = io.open(p, encoding='utf-8').read()
old = """              output = `#{cmd} 2>&1`

              unless $CHILD_STATUS.success?
                raise("Error in #{dir} running #{cmd}\\n#{output}")
              end
"""
new = """              # Run under the bundle that was just installed above, rather
              # than plain `rake`, which would resolve gems from the user store
              # and ignore the component's own pins.
              bundled_cmd = cmd.sub(%r{(\\A|\\s)rake\\s}, '\\\\1bundle exec rake ')

              output = `#{bundled_cmd} 2>&1`

              unless $CHILD_STATUS.success?
                raise("Error in #{dir} running #{bundled_cmd}\\n#{output}")
              end
"""
assert s.count(old) == 1, 'anchor matched %d' % s.count(old)
io.open(p, 'w', encoding='utf-8').write(s.replace(old, new, 1))
PY7
  echo "  [7/7] pkg.rb: asset rebuild now uses the component's own bundle"
else
  echo "  [7/7] pkg.rb: already patched"
fi

echo "Done. All seven are upstream bug candidates -- see build/el9-patches/README.md"
