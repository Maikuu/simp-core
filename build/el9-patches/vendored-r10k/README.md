# simp-vendored-r10k for EL9

`build-el9.sh` produces the `simp-vendored-r10k` RPM set for EL9.

## Why this is required, not optional

`simp-cli` deploys every Puppet module by shelling out to r10k
(`lib/simp/cli/environment/puppet_dir_env.rb`):

```ruby
r10k = 'r10k'
r10k = '/usr/share/simp/bin/r10k' if File.executable?('/usr/share/simp/bin/r10k')
r10k_cmd = "#{r10k} puppetfile install -v info"
```

No RPM declares a dependency on it, which is what made it look droppable. It is
not: without r10k, `simp config` dies on that line and **nothing can be
deployed** — no modules, no `simp bootstrap`, no usable server. Verified the
hard way on the 10.20.31.131 test install.

## Why not just `gem install r10k`

Do **not** install r10k into OpenVox's own `GEM_HOME`
(`/opt/puppetlabs/puppet/lib/ruby/gems/3.2.0`). Doing so drags in gems that
shadow Ruby's bundled ones for *every* puppet and simp process on the box. When
this was tried, `net-http 0.9.1` landed on top of Ruby 3.2's bundled `net/http`
and broke unrelated simp-cli code paths.

Vendoring into a private prefix — which is exactly what upstream's spec does —
keeps the gems visible only to the r10k wrapper, which sets `GEM_PATH` itself.

## What gets built

Layout is identical to upstream's:

| | |
| --- | --- |
| gem prefix | `/usr/share/simp/ruby/simp-r10k` |
| wrapper | `/usr/share/simp/bin/r10k` |
| cache dir | `/var/simp/cache/r10k` |

14 noarch RPMs + 1 SRPM: `simp-vendored-r10k`, `-doc`, and one `-gem-<name>`
subpackage per vendored gem.

## Gem selection

r10k 5.0.3's full closure is 28 gems. OpenVox's Ruby 3.2 already provides 16 of
them — including all three with native extensions (`json`, `racc`, `fiddle`).
The wrapper puts `/opt/puppetlabs/puppet/bin` first on `PATH` and appends the
vendored prefix to `GEM_PATH`, so those resolve from OpenVox at runtime.

The 12 that are vendored are all pure Ruby, so `BuildArch: noarch` in upstream's
spec stays correct. The script enforces this: it refuses to build if any fetched
gem declares an extension.

    r10k 5.0.3                       puppet_forge 6.2.0
    faraday 2.14.3                   faraday-net_http 3.4.4
    faraday-follow_redirects 0.5.0   net-http 0.9.1
    minitar 1.1.0                    log4r 1.1.10
    jwt 2.10.3                       gettext-setup 1.1.1
    cri 2.15.12                      colored2 4.0.3

This is a smaller, simpler closure than the EL8 pin (r10k 3.14.2), which needed
the whole `gettext`/`fast_gettext`/`locale`/`text` chain.

## Why a separate script instead of `rake pkg:rpm`

The upstream component (`simp/pkg-r10k`, checked out to
`src/assets/vendored_r10k`) cannot build on an EL9 host:

1. `Gemfile` pins `r10k 3.11`, whose gemspec requires `ruby ~> 2.3`, and
   `puppet ~> 6.2`. `bundle install` cannot resolve under Ruby 3.x, so
   `rake pkg:rpm` aborts with `LoadError: cannot load such file -- rest-client`.
2. `Rakefile` calls `ERB.new(tmpl, nil, '-')`. The 3-argument form was removed
   in Ruby 3.1.
3. The `:checkout`/`:gem` tasks clone each gem's **git repo** at a version tag
   and `gem build` it. Several gems in the modern r10k closure have no matching
   tags or no usable public repo.

`build-el9.sh` reuses upstream's spec template verbatim — so the resulting RPMs
are laid out exactly as upstream's — but takes the gems from RubyGems as
published `.gem` files and renders the ERB with the Ruby 3 signature.

The durable fix is upstream: bump `pkg-r10k`'s Gemfile and Rakefile, and switch
its gem sourcing off git. Until then this script stands in.

## Usage

```bash
bash build/el9-patches/vendored-r10k/build-el9.sh
```

Needs `gem`, `ruby`, `rpmbuild` (rpm-build) and network access to rubygems.org.
Output lands in `build/el9-patches/vendored-r10k/work/dist/`.

Copy the noarch RPMs into the build's SIMP repo directory before `rake iso:build`
so they are pulled onto the ISO and installed by the kickstart.

## Related

`build/el9-patches/apply-gem-patches.sh` previously carried a patch that removed
`simp-vendored-r10k` from `tar:validate`'s required-RPM list, as a workaround for
the build failure above. That patch has been **removed** — the RPM builds now,
and r10k must be present.
