#!/bin/bash
#
# Build simp-vendored-r10k for EL9.
#
# WHY THIS EXISTS
# ---------------
# The upstream component (simp/pkg-r10k, src/assets/vendored_r10k) cannot be
# built as-is on an EL9 host:
#
#   * Gemfile pins `r10k 3.11` (gemspec requires ruby ~> 2.3) and `puppet ~> 6.2`,
#     so `bundle install` cannot resolve under Ruby 3.x and `rake pkg:rpm` dies
#     with "LoadError: cannot load such file -- rest-client".
#   * Rakefile calls ERB.new(tmpl, nil, '-'); the 3-argument form was removed in
#     Ruby 3.1.
#   * The :checkout/:gem tasks clone each gem's git repo at a version tag and
#     `gem build` it.  Several gems in the modern r10k closure either have no
#     matching tags or no usable public repo.
#
# This script keeps upstream's RPM layout EXACTLY (same spec template, same
# %{gemdir}/%{pkgname} paths, same /usr/share/simp/bin/r10k wrapper) but takes
# the gems from RubyGems as published .gem files instead of from git.
#
# WHY THESE GEMS
# --------------
# r10k 5.0.3's full closure is 28 gems.  OpenVox's own Ruby 3.2 already provides
# 16 of them -- including every gem with a native extension (json, racc,
# fiddle).  The wrapper puts /opt/puppetlabs/puppet/bin first on PATH and
# appends the vendored dir to GEM_PATH, so those 16 resolve from OpenVox at
# runtime.  Only the 12 below must be vendored, and all 12 are pure Ruby, so
# "BuildArch: noarch" in the spec remains correct.
#
# Do NOT install these into OpenVox's own GEM_HOME instead of vendoring them.
# Doing so shadows Ruby's bundled gems for every puppet/simp process on the box.
#
# Usage:  build-el9.sh [<path to vendored_r10k component>]
#         defaults to ../../../src/assets/vendored_r10k relative to this script
set -euo pipefail

R10K_VERSION=5.0.3
RELEASE=1

GEMS=(
  "r10k:${R10K_VERSION}"
  'puppet_forge:6.2.0'
  'faraday:2.14.3'
  'faraday-net_http:3.4.4'
  'faraday-follow_redirects:0.5.0'
  'net-http:0.9.1'
  'minitar:1.1.0'
  'log4r:1.1.10'
  'jwt:2.10.3'
  'gettext-setup:1.1.1'
  'cri:2.15.12'
  'colored2:4.0.3'
)

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
component=${1:-$(cd "$here/../../.." && pwd)/src/assets/vendored_r10k}
template="$component/build/simp-vendored-r10k.spec.erb"

[ -f "$template" ] || { echo "FATAL: spec template not found: $template" >&2; exit 1; }
command -v gem      >/dev/null || { echo "FATAL: gem not found" >&2; exit 1; }
command -v rpmbuild >/dev/null || { echo "FATAL: rpmbuild not found (rpm-build)" >&2; exit 1; }
command -v ruby     >/dev/null || { echo "FATAL: ruby not found" >&2; exit 1; }

work="$here/work"
rm -rf "$work"
mkdir -p "$work/gems" "$work/dist"

echo "== fetching ${#GEMS[@]} gems from RubyGems"
( cd "$work/gems"
  for spec in "${GEMS[@]}"; do
    gem fetch "${spec%%:*}" -v "${spec##*:}" >/dev/null
    echo "   ${spec}"
  done )

# Refuse to ship anything that would need compiling: the spec is BuildArch noarch.
echo "== verifying every gem is pure Ruby"
ruby -rrubygems/package -e '
  bad = []
  Dir.glob(File.join(ARGV[0], "gems", "*.gem")).sort.each do |path|
    spec = Gem::Package.new(path).spec
    bad << spec.full_name unless spec.extensions.empty?
  end
  unless bad.empty?
    warn "   FATAL: these gems ship native extensions and cannot go in a noarch RPM:"
    bad.each { |b| warn "     #{b}" }
    exit 1
  end
' "$work" || exit 1
echo "   all pure Ruby"

echo "== generating build/sources.yaml from the fetched gems"
ruby -ryaml -rrubygems/package -e '
  work, r10k_version, release = ARGV
  gems = {}
  Dir.glob(File.join(work, "gems", "*.gem")).sort.each do |path|
    s = Gem::Package.new(path).spec
    gems[s.name] = {
      "version" => s.version.to_s,
      "license" => (s.licenses.empty? ? "UNKNOWN" : s.licenses.join(" or ")),
      "url"     => (s.homepage.to_s.empty? ? "https://rubygems.org/gems/#{s.name}" : s.homepage),
      "release" => Integer(release),
    }
  end
  File.write(File.join(work, "sources.yaml"),
             { "version" => r10k_version, "gems" => gems }.to_yaml)
  puts "   #{gems.size} gems described"
' "$work" "$R10K_VERSION" "$RELEASE"

echo "== rendering the spec from upstream template (Ruby 3 ERB signature)"
ruby -ryaml -rerb -e '
  work, template, changelog_path = ARGV
  deps      = YAML.load_file(File.join(work, "sources.yaml"))
  changelog = File.exist?(changelog_path) ? File.read(changelog_path) : "* EL9 build\n"
  # Upstream uses ERB.new(str, nil, "-"); that 3-arg form was removed in Ruby 3.1.
  File.write(File.join(work, "simp-vendored-r10k.spec"),
             ERB.new(File.read(template), trim_mode: "-").result(binding))
' "$work" "$template" "$component/CHANGELOG"

echo "== building the RPMs"
top="$work/RPMBUILD"
mkdir -p "$top"/{BUILD,BUILDROOT,RPMS,SOURCES,SPECS,SRPMS}
cp "$work"/gems/*.gem "$top/SOURCES/"

# The spec's %prep does %setup -q against this tarball.
staging="$work/simp-vendored-r10k-${R10K_VERSION}"
mkdir -p "$staging/docs"
if [ -d "$component/docs" ]; then cp -r "$component/docs/." "$staging/docs/"; fi
[ -n "$(ls -A "$staging/docs" 2>/dev/null)" ] || echo "See https://github.com/simp/pkg-r10k" > "$staging/docs/README"
tar -C "$work" -czf "$top/SOURCES/simp-vendored-r10k-${R10K_VERSION}-${RELEASE}$(rpm -q --eval '%{?dist}').tar.gz" \
    "simp-vendored-r10k-${R10K_VERSION}"

rpmbuild -D "_topdir $top" \
         -D '__brp_mangle_shebangs /usr/bin/true' \
         -ba "$work/simp-vendored-r10k.spec"

cp "$top"/RPMS/*/*.rpm "$top"/SRPMS/*.rpm "$work/dist/" 2>/dev/null || true
echo
echo "== built $(ls "$work"/dist/*.rpm 2>/dev/null | wc -l) RPMs in $work/dist"
ls -1 "$work"/dist/*.rpm 2>/dev/null | sed 's|.*/|   |'

# ---------------------------------------------------------------------------
# Publish into the component's dist/ so the normal simp-core pipeline
# (pkg:aux -> tar:build -> iso:build) collects these onto the ISO.
#
# tar:build looks for each required package under build/SIMP/RPMS and, when it
# cannot find one, points at "dist/logs/last_rpm_build_metadata.yaml" -- that
# file is how a component advertises what it produced. Upstream's Rakefile
# writes it via Simp::RPM::create_rpm_build_metadata; this reproduces the same
# structure without needing simp-rake-helpers loaded.
# ---------------------------------------------------------------------------
echo
echo "== publishing to $component/dist"
mkdir -p "$component/dist/logs"
cp -f "$work"/dist/*.rpm "$component/dist/"

ruby -ryaml -e '
  component = ARGV[0]
  dist      = File.join(component, "dist")

  def rpm_meta(path)
    fmt = "%{NAME}|%{VERSION}|%{RELEASE}|%{ARCH}"
    name, version, release, arch = `rpm -qp --qf "#{fmt}" #{path} 2>/dev/null`.split("|")
    dist_tag = release[/\.el\d+$/]
    {
      :has_dist_tag => !dist_tag.nil?,
      :dist         => dist_tag.to_s,
      :basename     => name,
      :version      => version,
      :release      => release,
      :arch         => arch,
      :full_version => "#{version}-#{release}",
      :name         => "#{name}-#{version}-#{release}",
      :rpm_name     => File.basename(path),
    }
  end

  def entries(paths)
    paths.sort.each_with_object({}) do |path, acc|
      acc[File.basename(path)] = {
        "metadata"  => rpm_meta(path),
        "size"      => File.size(path),
        "timestamp" => File.mtime(path),
        "path"      => File.expand_path(path),
      }
    end
  end

  all   = Dir.glob(File.join(dist, "*.rpm"))
  srpms = all.select { |f| f.end_with?(".src.rpm") }
  rpms  = all - srpms

  git_hash = Dir.chdir(component) { `git rev-parse HEAD 2>/dev/null`.strip }
  git_hash = "unknown" if git_hash.empty?

  File.write(File.join(dist, "logs", "last_rpm_build_metadata.yaml"),
             { "git_hash" => git_hash,
               "srpms"    => entries(srpms),
               "rpms"     => entries(rpms) }.to_yaml)
' "$component"

echo "   dist/ now holds $(ls "$component"/dist/*.rpm 2>/dev/null | wc -l) RPMs"
echo "   wrote $component/dist/logs/last_rpm_build_metadata.yaml"
echo
echo "NOTE: simp-vendored-r10k must also be listed in the kickstart package set"
echo "      (ks/dvd/include/simp_ks_base) or it ships on the ISO without being installed."
