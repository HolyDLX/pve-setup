# Proxmox Setup

This repository is used to reproduce the configuration of a Proxmox host and selected hosted services.

The repository is template-driven. Machine-specific values are collected during installation and stored in local configuration files that are excluded from Git.

## Structure

```text
pve-setup/
├── .gitignore
├── config.local
├── core/
│   ├── configure.sh
│   ├── install-core.sh
│   ├── install-wifi.sh
│   ├── install-eth.sh
│   └── templates/
├── example-service/
│   ├── install.sh
│   ├── install-lxc.sh
│   ├── config.local
│   └── templates/
└── ...
```

## Core

`core/` contains configuration that belongs to the Proxmox host itself.

The intended workflow is:

```bash
./core/configure.sh
./core/install-wifi.sh
./core/install-core.sh
```

or, for an Ethernet-connected host:

```bash
./core/configure.sh
./core/install-eth.sh
./core/install-core.sh
```

`configure.sh` collects shared host-specific values and writes them to the top-level:

```text
config.local
```

This file is not committed to Git.

The network-specific installers configure the selected uplink.

`install-core.sh` then renders and installs the generic Proxmox host configuration using the values from `config.local`.

## Service Modules

Hosted services should be kept in separate modules.

A service module may contain:

```text
example-service/
├── install.sh
├── install-lxc.sh
├── config.local
└── templates/
```

The public entry point should normally be:

```bash
./example-service/install.sh
```

A service installer may:

- collect service-specific settings
- store them in a local ignored configuration file
- create and configure an LXC container
- install software inside the container
- install host-side networking or other integration
- enable required services and startup behavior

Internal helper scripts such as `install-lxc.sh` do not normally need to be invoked directly.

## Templates

Reusable configuration belongs in `templates/`.

Templates may contain placeholders such as:

```text
{{UPLINK_INTERFACE}}
{{VM_BRIDGE}}
{{SERVICE_IP}}
{{SERVICE_PORT}}
```

Installation scripts render these templates using machine-specific or service-specific configuration.

Rendered files are installed directly into their final locations on the host.

The repository therefore stores the intended configuration rather than copies of the currently installed files.

## Local Configuration

The top-level `config.local` contains settings shared by the host and service modules.

Example values may include:

```text
UPLINK_INTERFACE
HOST_ADDRESS
HOST_GATEWAY
VM_BRIDGE
VM_NETWORK
VM_GATEWAY
```

Individual service modules may also create their own `config.local` files for service-specific values.

These files should be excluded from Git.

## Secrets

Secrets must not be committed to this repository.

Examples include:

- passwords
- Wi-Fi credentials
- private keys
- API tokens
- database credentials
- application secret keys

Installers should either prompt for secrets when needed or generate them automatically.

Sensitive configuration files created during installation should remain local to the machine.

## Fresh Installation

The intended recovery or deployment workflow is:

1. Install Proxmox.
2. Copy or clone this repository onto the host.
3. Configure the host:
   ```bash
   ./core/configure.sh
   ```
4. Install the selected uplink:
   ```bash
   ./core/install-wifi.sh
   ```
   or:
   ```bash
   ./core/install-eth.sh
   ```
5. Install the common host configuration:
   ```bash
   ./core/install-core.sh
   ```
6. Install the required service modules:
   ```bash
   ./example-service/install.sh
   ```
7. Reboot and verify the installation.

The goal is for a clean Proxmox installation to be reproducible using only this repository plus the required machine-specific and secret values.

## Adding a New Service

New services should normally receive their own module:

```text
new-service/
├── install.sh
├── install-lxc.sh
├── config.local
└── templates/
```

Generic Proxmox host configuration belongs in `core`.

Service-specific configuration belongs in the corresponding service module.

Modules should rely on the shared top-level `config.local` for common host/network information instead of asking for the same values repeatedly.
