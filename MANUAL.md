# SHIELD Genesis Kit Manual

The **SHIELD Genesis Kit** deploys the SHIELD Cloud Data
Protection suite, to allow you to back up your sensitive cloud
infrastructure and application data.

# Base Parameters

- `shield_static_ip` - The static IP address of the SHIELD core.
  This must be designated as static in the chosen network's cloud
  config definition.

- `external_domain` - Optional; the DNS name set up for the shield
  server. This is used for certificate validation if present.

- `installation` - The name of the SHIELD installation, as
  reported from inside the SHIELD UI.
  Defaults to `S.H.I.E.L.D.`

## HTTP(S) Proxy Parameters

- `http_proxy` - (Optional) URL of an HTTP proxy to use for any
  outbound HTTP (non-TLS) communication.

- `https_proxy` - (Optional) URL of an HTTP proxy to use for any
  outbound HTTPS (TLS) communication.

- `no_proxy` - A list of IPs, FQDNs, partial domains, etc. to
  skip the proxy and connect to directly.  This has no effect if
  the `http_proxy` and `https_proxy` are not set.

  This is currently encoded as a comma-separated string, **not**
  a YAML list.

## Sizing and Deployment Parameters

- `shield_disk_pool` - The persistent disk pool that Vault VMs will
  use.  This pool must exist in your cloud config.  Defaults to
  `shield`.

- `shield_vm_type` - What type of VM to deploy.  This type must
  exist in your cloud config.  Defaults to `small`.

- `shield_network` - What network to deploy SHIELD into.  This
  network must be defined in your cloud config.  Defaults to
  `shield`.

- `stemcell_os` - The operating system you want to deploy SHIELD
  on.  This defaults to `ubuntu-xenial`.

- `stemcell_version` - The version of the stemcell to deploy.
  Defaults to `latest`, which is usually what you want.

- `availability_zone` - What BOSH availability zone to deploy
  SHIELD into.  The chosen network must have at least one
  subnet in this zone, and the zone itself must be defined in your
  cloud config.  Defaults to `z1`.

  **Note**: This Genesis Kit only deploys a single-instance SHIELD
  so availability zone configuration will not bring high
  availability to the deployment.

# Available Features

- `oauth` - Enables Oauth2 SHIELD authentication to a backend like
  Github or UAA.  See the _Examples_ section for more details on
  properly configuring Github and UAA providers.

- `secure` - Configure the admin user account.  By default, the admin user
  account credentials are static.  Use this feature to have a password
  generated automatically and optionally specify an alternative username with
  by setting `params.admin_username` in the environment file.  The password
  can then be rotated as needed by your company's security policy.

# Cloud Configuration

By default, SHIELD uses the following VM types/networks/disk pools from your
Cloud Config. Feel free to override them in your environment, if you would
rather they used entities already existing in your Cloud Foundry:

```
params:
  shield_network:   shield
  shield_disk_pool: shield # should be at least 1GB
  shield_vm_type:   small # VMs should have at least 1 CPU, and 1GB of memory
```

# Available Addons

- `visit` - Open up the SHIELD Web UI in your browser (only works
  on macOS, currently).

- `runtime-config` - Generate a good starting point configuration
  for deploying the SHIELD agent via BOSH as an addon.

# Examples

To use custom cloud config types:

```
---
kit:
  name:    shield
  version: 0.3.0

genesis:
  env: acme-us-east-1-prod

params:
  shield_static_ip: 10.0.0.7
  shield_network:   core-infra
  shield_disk_pool: backups
  shield_vm_type:   std.small.1c.2gb
```

To enable Github as an Oauth2 authentication provider:

```
---
kit:
  name:    shield
  version: 0.3.0
  features:
    - oauth2

genesis:
  env: acme-us-east-1-dev

params:
  shield_static_ip: 10.0.0.7
  authentication:
    - name:       Github
      identifier: github
      backend:    github
      properties:
        client_id:     <client-id>
        client_secret: <client-secret>
        mapping:
          - github: starkandwayne  # <-- github org name
            tenant: starkandwayne  # <-- shield tenant name
            rights:
              - team: Owners       # <-- github team name
                role: admin        # <-- shield role name
              - team: Engineering  #   (first match wins)
                role: engineer
              - role: operator     # = (default match)
          - github: starkandwayne
            tenant: SYSTEM
            rights:
              - team: Owners
                role: admin
```

To enable Cloud Foundry UAA as an Oauth2 authentication provider:

```
---
kit:
  name:    shield
  version: 0.3.0
  features:
    - oauth2

genesis:
  env: acme-us-east-1-dev

params:
  shield_static_ip: 10.0.0.7
  authentication:
    - name:       UAA
      identifier: uaa1
      backend:    uaa
      properties:
        client_id:       <client-id>
        client_secret:   <client-secret>
        uaa_endpoint:    https://uaa.shield.10.10.10.10.netip.cc:8443
        skip_verify_tls: true
        mapping:
          - tenant: UAA          # <-- shield tenant name
            rights:
              - scim: uaa.admin  # <-- uaa scim right
                role: admin      # <-- shield role
                                #   (first match wins)
              - scim: cloud_controller.write
                role: engineer
              - role: operator   # = (default match)
          - tenant: UAA Admins
            rights:
              - scim: uaa.admin
                role: admin
```

Note that the "SYSTEM" tenant is used to apply rights and roles to
SHIELD itself.

# Caveats

SHIELD requires mutual visibility with the hosts where its agents
execute.  It is currently impossible for a SHIELD core to properly
orchestrate a SHIELD Agent that exists behind a NAT gateway, in
another sequestered network.

# History

Version 0.3.0 was the first version to support Genesis 2.6 hooks
for addon scripts and `genesis info`.
