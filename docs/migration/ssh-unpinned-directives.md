# ssh: directives SIMP stops enforcing on EL9

`simp/ssh` 9.1.0 writes an `sshd_config` entry only when the parameter is not `undef`
(see `functions/add_sshd_config.pp`). These parameters had concrete defaults in 6.13.1
and are `undef` in 9.1.0, so SIMP will no longer write them.

| directive | 6.13.1 enforced | you pin it? |
|---|---|---|
| `ssh::server::conf::acceptenv` | `$ssh::server::params::acceptenv` | NO |
| `ssh::server::conf::authorizedkeysfile` | `'/etc/ssh/local_keys/%u'` | NO |
| `ssh::server::conf::banner` | `'/etc/issue.net'` | **yes** |
| `ssh::server::conf::challengeresponseauthentication` | `false` | NO |
| `ssh::server::conf::clientalivecountmax` | `0` | **yes** |
| `ssh::server::conf::clientaliveinterval` | `600` | NO |
| `ssh::server::conf::compression` | `'delayed'` | **yes** |
| `ssh::server::conf::gssapiauthentication` | `$ssh::server::params::gssapiauthentication` | NO |
| `ssh::server::conf::hostbasedauthentication` | `false` | NO |
| `ssh::server::conf::ignorerhosts` | `true` | NO |
| `ssh::server::conf::ignoreuserknownhosts` | `true` | NO |
| `ssh::server::conf::kerberosauthentication` | `false` | NO |
| `ssh::server::conf::logingracetime` | `120` | NO |
| `ssh::server::conf::maxauthtries` | `6` | NO |
| `ssh::server::conf::oath` | `simplib::lookup('simp_options::oath', { 'def` | NO |
| `ssh::server::conf::passwordauthentication` | `true` | NO |
| `ssh::server::conf::permitemptypasswords` | `false` | NO |
| `ssh::server::conf::permitrootlogin` | `false` | NO |
| `ssh::server::conf::permituserenvironment` | `false` | NO |
| `ssh::server::conf::port` | `22` | NO |
| `ssh::server::conf::printlastlog` | `false` | **yes** |
| `ssh::server::conf::protocol` | `[2]` | NO |
| `ssh::server::conf::rhostsrsaauthentication` | `$ssh::server::params::rhostsrsaauthenticatio` | NO |
| `ssh::server::conf::strictmodes` | `true` | NO |
| `ssh::server::conf::subsystem` | `'sftp /usr/libexec/openssh/sftp-server'` | NO |
| `ssh::server::conf::syslogfacility` | `'AUTHPRIV'` | NO |
| `ssh::server::conf::usepam` | `simplib::lookup('simp_options::pam', { 'defa` | NO |
| `ssh::server::conf::useprivilegeseparation` | `'sandbox'` | NO |
| `ssh::server::conf::x11forwarding` | `false` | NO |

25 of 29 are unpinned and will fall back to sshd/50-redhat.conf defaults.
