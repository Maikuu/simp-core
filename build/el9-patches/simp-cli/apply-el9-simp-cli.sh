#!/bin/bash
# EL9 patches for the rubygem_simp_cli component.
#
# src/assets/rubygem_simp_cli is a gitignored component checkout that
# `rake deps:checkout` wipes, so these live here and are re-applied rather than
# being committed into the checkout. Re-run after any deps:checkout.
#
# Usage:  bash build/el9-patches/simp-cli/apply-el9-simp-cli.sh
#
# All three are genuine upstream simp-cli defects that only bite on EL9.
# Patches 1 and 2 were first proven by hand on the EL9 test host; this script is
# what puts them on the ISO.
#
#   1. java_major_version misparses every JDK >= 9 as 0, which trips the
#      `< 8` guard and adds -XX:MaxPermSize -- removed in Java 9 and fatal.
#      EL9 ships Java 17, so puppetserver never starts.
#   2. puppetserver_running? reads the response body; HighLine.colorize_strings
#      breaks Net::HTTP chunked parsing process-wide, so bootstrap can never
#      see a healthy puppetserver.
#   3. network::eth does not exist on EL9 -- pupmod-simp-network is not shipped
#      because RHEL 9 removed network-scripts. ConfigureNetworkAction sets
#      die_on_apply_fail, so `simp config` aborts outright.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
CLI="$ROOT/src/assets/rubygem_simp_cli/lib/simp/cli"

[ -d "$CLI" ] || { echo "rubygem_simp_cli not checked out at $CLI"; exit 1; }

python3 - "$CLI" <<'PY'
import sys, os
cli = sys.argv[1]

def patch(relpath, old, new, tag, already_marker):
    path = os.path.join(cli, relpath)
    with open(path) as f:
        src = f.read()
    if already_marker in src:
        print(f"  [{tag}] already patched")
        return
    if old not in src:
        sys.exit(f"  [{tag}] FAILED: anchor not found in {relpath}\n---\n{old}\n---")
    if src.count(old) != 1:
        sys.exit(f"  [{tag}] FAILED: anchor matched {src.count(old)}x in {relpath}")
    with open(path, 'w') as f:
        f.write(src.replace(old, new))
    print(f"  [{tag}] patched {relpath}")

# ------------------------------------------------------------------ patch 1
patch(
    'commands/bootstrap.rb',
    "      @java_major_version = java_version.strip.split('_')[0].split('.')[1].to_i\n",
    """      # EL9: parse both the pre-JEP-223 ("1.8.0_181" -> 8) and the modern
      # ("17.0.18" -> 17) version schemes. The previous expression returned 0
      # for every JDK >= 9, which satisfied the `< 8` guard below and appended
      # -XX:MaxPermSize -- a flag Java 9 removed and rejects fatally, putting
      # puppetserver into a systemd restart loop.
      if (m = java_version.match(%r{version "(\\d+)(?:\\.(\\d+))?}))
        @java_major_version = (m[1] == '1') ? m[2].to_i : m[1].to_i
      end
""",
    '1/3',
    'pre-JEP-223',
)

# ------------------------------------------------------------------ patch 2
patch(
    'commands/bootstrap.rb',
    "      status = (server_conn.request(Net::HTTP::Get.new('/status/v1/services')).code == '200')\n",
    """      # EL9: take the status line from the streamed response and never read
      # the body. puppetserver 8 (Jetty 12) answers this endpoint with
      # Transfer-Encoding: chunked, and HighLine.colorize_strings -- loaded by
      # simp/cli/logging -- breaks Net::HTTP's chunked parser process-wide,
      # raising EOFError on every body read. The rescue below hides it, so
      # bootstrap just spins for five minutes and gives up.
      server_conn.start do |http|
        http.request(Net::HTTP::Get.new('/status/v1/services')) do |response|
          status = (response.code == '200')
        end
      end
""",
    '2/3',
    'never read\n      # the body',
)

# ----------------------------------------------------------------- patch 3a
# Detection helper + don't offer a choice that cannot work.
patch(
    'config/items/data/cli_network_set_up_nic.rb',
    """      @data_type   = :cli_params
    end

    def get_recommended_value
      os_value || 'yes'
    end
""",
    """      @data_type   = :cli_params

      # EL9: RHEL 9 removed the network-scripts package that network::eth
      # writes ifcfg files for, so pupmod-simp-network is not shipped. Without
      # it ConfigureNetworkAction cannot succeed, and it sets die_on_apply_fail,
      # so answering 'yes' aborts `simp config` with
      #   Unknown resource type: 'network::eth'
      # Do not offer the choice at all -- the NIC is already configured by the
      # kickstart, and the 'no' branch still collects every network value that
      # `simp config` needs to write into hieradata.
      @skip_query = true unless self.class.network_module_available?(@puppet_env_info)
    end

    # @return [Boolean] whether the Puppet `network` module is on the modulepath
    def self.network_module_available?(puppet_env_info)
      paths = (puppet_env_info || {}).fetch(:puppet_config, {})['modulepath']
      paths = paths.is_a?(String) ? paths.split(':') : Array(paths)
      paths += [Simp::Cli::SIMP_MODULES_INSTALL_PATH] if defined?(Simp::Cli::SIMP_MODULES_INSTALL_PATH)
      paths.any? { |p| File.directory?(File.join(p.to_s, 'network', 'manifests')) }
    end

    def get_recommended_value
      return 'no' unless self.class.network_module_available?(@puppet_env_info)

      os_value || 'yes'
    end
""",
    '3a/3',
    'network_module_available?',
)

# ----------------------------------------------------------------- patch 3b
# Belt and braces: an answers file can pre-set set_up_nic=yes, which bypasses
# the skip_query above. Never let that reach a `puppet apply` that must fail.
patch(
    'config/items/action/configure_network_action.rb',
    """require_relative '../data/cli_network_interface'
""",
    """require_relative '../data/cli_network_interface'
require_relative '../data/cli_network_set_up_nic'
""",
    '3b/3',
    'cli_network_set_up_nic',
)

patch(
    'config/items/action/configure_network_action.rb',
    """    def apply
      @applied_status = :failed

      dhcp      = get_item('cli::network::dhcp').value
""",
    """    def apply
      @applied_status = :failed

      # EL9: pupmod-simp-network is not shipped (RHEL 9 removed
      # network-scripts), so network::eth below would raise
      # "Unknown resource type" and, because @die_on_apply_fail is set, take
      # `simp config` down with it. A pre-set answers file can reach here even
      # though CliSetUpNIC skips its query, so refuse cleanly instead.
      unless Item::CliSetUpNIC.network_module_available?(@puppet_env_info)
        @interface = get_item('cli::network::interface').value
        warn("The 'network' Puppet module is not installed; leaving #{@interface} as configured", [:YELLOW])
        @applied_status = :unnecessary
        return
      end

      dhcp      = get_item('cli::network::dhcp').value
""",
    '3c/3',
    "The 'network' Puppet module is not installed",
)
PY

echo
echo "ruby -c on both files:"
for f in "$CLI/commands/bootstrap.rb" \
         "$CLI/config/items/data/cli_network_set_up_nic.rb" \
         "$CLI/config/items/action/configure_network_action.rb"; do
  printf '  %-46s ' "$(basename "$f")"
  ruby -c "$f" 2>&1 | tail -1
done
