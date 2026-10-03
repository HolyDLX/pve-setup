# Proxmox Setup

Template-driven setup repository for reproducible Proxmox VE host configuration and optional service modules.

The repository separates shared host configuration, core system setup, networking, reusable templates, and independent service modules.

Machine-specific configuration is stored in local `config.local` files and is not committed.

## Repository Structure

```text
.
├── config.local
├── core
│   ├── add_additional_wifi.sh
│   ├── config.local
│   ├── configure.sh
│   ├── install-core.sh
│   ├── install-eth.sh
│   ├── install-wifi.sh
│   ├── update.sh
│   └── templates
│       ├── 10-vmbr0.template
│       ├── getty-tty1-override.conf
│       └── pve-dashboard.template
├── example-service
│   ├── config.local
│   ├── install.sh
│   └── templates
└── README.md
```

## Configuration

The root-level `config.local` contains machine-specific values shared across modules.

Example:

```bash
UPLINK_INTERFACE="wlp0s20f3"
HOST_ADDRESS="192.168.1.50/24"
HOST_GATEWAY="192.168.1.1"

VM_BRIDGE="vmbr0"
VM_NETWORK="10.10.10.0/24"
VM_GATEWAY="10.10.10.1"
```

Create or update it with:

```bash
./core/configure.sh
```

Modules may maintain their own local configuration, for example:

```text
core/config.local
example-service/config.local
```

These files contain settings that belong only to that module.

All local configuration files should be ignored by Git:

```gitignore
**/config.local
```

## Fresh Installation

After installing Proxmox VE, copy this repository to the host.

For example:

```text
/root/pve-setup
```

If the repository was copied through a filesystem that does not preserve executable permissions:

```bash
chmod +x core/*.sh
```

Then configure the host:

```bash
cd /root/pve-setup
./core/configure.sh
```

Choose the appropriate uplink installer:

```bash
./core/install-wifi.sh
```

or:

```bash
./core/install-eth.sh
```

Finally install the core configuration:

```bash
./core/install-core.sh
```

Reboot afterwards to apply the persistent network configuration.

## Networking

The setup uses a physical uplink for host management and a separate internal bridge for guests.

Conceptually:

```text
Physical network
       │
       ▼
Host uplink
       │
       │ NAT
       ▼
Internal bridge
       │
       ├── VM
       ├── LXC
       └── VM
```

The physical uplink receives the host's LAN address.

The internal bridge uses a separate private subnet and provides networking for virtual machines and containers.

This arrangement also works with Wi-Fi uplinks, where normal Layer-2 bridging of guest MAC addresses is generally unsuitable.

## Wi-Fi Bootstrap

A fresh Proxmox installation may not contain the tools required for Wi-Fi operation.

`core/install-wifi.sh` can temporarily use a wired connection to install the required dependencies before configuring the permanent Wi-Fi uplink.

Temporary bootstrap values are stored in:

```text
core/config.local
```

and reused as defaults during later runs.

This allows repeated setup attempts without re-entering the same temporary networking information.

## Multiple Wi-Fi Networks

Additional known Wi-Fi networks can be configured with:

```bash
./core/add_additional_wifi.sh
```

Each known SSID can use its own IP configuration.

For example:

```text
Network A
    static address

Network B
    DHCP
```

The system can then connect automatically to whichever configured network is available.

Network selection is handled by the Wi-Fi subsystem, while the corresponding IP configuration is applied when the connection changes.

## Core Installation

`core/install-core.sh` installs the persistent host configuration.

Its responsibilities include:

- installing the internal guest bridge
- applying template-based system configuration
- installing the tty1 status dashboard
- configuring the dashboard service
- establishing the intended host network layout

The physical uplink and internal bridge must use different addresses and subnets.

## Updating Core Templates

Changes to core templates can be applied without repeating the full installation:

```bash
./core/update.sh
```

This re-renders and installs the current templates while leaving bootstrap and first-install logic untouched.

## tty1 Dashboard

The first virtual terminal displays a live host status dashboard.

Depending on the configured uplink, it can show information such as:

- hostname
- Web UI address
- uplink interface
- interface state
- current IP address
- current Wi-Fi SSID
- memory usage
- disk usage
- guest status

A normal login console remains available on another virtual terminal.

## Templates

Templates are stored inside each module's `templates/` directory.

They may contain placeholders such as:

```text
{{UPLINK_INTERFACE}}
{{VM_BRIDGE}}
{{VM_NETWORK}}
{{VM_GATEWAY}}
```

Installation and update scripts render these using the appropriate local configuration.

The repository templates are the source of truth.

Generated host-specific files are not copied back into the repository.

## Service Modules

Additional services should be implemented as independent modules.

A typical module may contain:

```text
example-service/
├── config.local
├── install.sh
├── install-lxc.sh
└── templates/
```

Service-specific networking, configuration, and installation logic should remain inside the corresponding module.

The core setup should not depend on any individual service module.

## Secrets

Secrets should not be committed.

Examples include:

- Wi-Fi credentials
- generated application secrets
- database passwords
- service credentials

Secrets should remain in generated host configuration, protected local files, or other appropriate secret storage.

## Design Principles

- `core/` contains general host configuration only.
- Service-specific behavior belongs in independent modules.
- Templates describe the intended system configuration.
- Machine-specific settings live in ignored `config.local` files.
- Secrets are not committed.
- Installation scripts automate first-time setup.
- Update scripts reapply templates without repeating bootstrap work.
- The repository should remain usable from a clean Proxmox VE installation.