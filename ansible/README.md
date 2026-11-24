# Ansible roles

- `snreg_server`: the systemd path of spec §8 (server package, optional local PostgreSQL, `init`,
  service). Set `snreg_server_package` to the `.deb` or `.rpm`.
- `snreg_agent`: existing fleets that aren't imaged from the zero-touch ISO. Set
  `snreg_agent_packages`, `snreg_server_url`, `snreg_server_cert_sha256` and
  `snreg_enrollment_token` (keep it in Ansible Vault).

`site.yml` runs both on the `snreg_server` and `snreg_agents` groups. `test.sh` is the smoke test.
