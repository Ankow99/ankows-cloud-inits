# LXD Cloud-Init Reproducers & Launchers

This repository contains a collection of automated local laboratory environments for various cloud technologies. Each environment is self-contained and reproducible, utilizing LXD VMs and Cloud-Init to bootstrap complex setups like MAAS, OpenStack, Kubernetes, and more.

The core of this project is a standardized `launch.sh` script included in each directory, which automates the lifecycle of the lab: launching, configuring, log-tailing, and providing cleanup mechanisms.

## Available Labs

The following environments are available in their respective directories:

* LXD (Contains the global preseed configuration)
* Snapcraft (Automated build environment)
* MAAS (Metal as a Service)
* Juju (Bootstraps a Juju Controller on MAAS)
* Ceph (Distributed Storage Cluster)
* Landscape (Standalone, Client, & High Availability modes)
* Kubernetes ("The Hard Way" Automated)
* OpenStack (Includes Full Charmed OpenStack & DevStack modes)

## Prerequisites

To use these launchers, your host machine must meet the following requirements:

1.  OS: Linux (Ubuntu recommended)
2.  LXD: Installed and initialized using the provided preseed
3.  Dependencies:
    * `jq` (Required for parsing JSON output in the launch scripts)

```bash
sudo snap install lxd
sudo apt update
sudo apt install jq 
```

## Installation

Clone the repository to your local machine:

```bash
git clone https://github.com/Ankow99/ankows-cloud-inits.git
cd ankows-cloud-inits
```

### Setup: Important Customization

Before launching any labs, you must update the Cloud-Init files with your own credentials.

#### SSH Access
Every `cloud-config.yaml` file in this repository is currently configured to import SSH keys from a specific Launchpad ID:

```yaml
ssh_import_id: ['lp:pgdg99']
```

> You must replace `pgdg99` with your own Launchpad username. Alternatively, you can replace the `ssh_import_id` block with a standard `ssh_authorized_keys` block containing your public key.

#### Snapcraft Credentials
The Snapcraft lab automates the login process by injecting a credentials file. Inside `Snapcraft/cloud-init/cloud-config.yaml`, you will find a large base64 encoded block:

```yaml
- |
  cat <<EOF > /home/ubuntu/snapcraft-credentials
  [INSERT YOUR CREDENTIALS HERE]
```

> You must replace this content string "`[INSERT YOUR CREDENTIALS HERE]`" with your own exported Snapcraft credentials. You can generate this on your local machine by running:
`snapcraft export-login snapcraft.login`

### Setup: Initializing LXD

Critical Step: Before running any labs, you must initialize LXD with the specific network and profile configurations required by these scripts.

A preseed file is provided in the `LXD/` folder. This configures:
* lxdbr0: 10.10.10.1/24 (NAT enabled)
* mbr0: 10.0.0.1/22 (No DHCP, NAT enabled, used for non-nested MAAS/Infrastructure layers)
* Storage: 500GiB ZFS pool named `default`.
* Profiles: A custom `default` profile with standard tools (neovim, git) and a `maas` profile with specific network attachments.

To initialize LXD:

```bash
# 1. Navigate to the LXD folder
cd LXD

# 2. Feed the preseed into LXD initialization
cat lxd_preseed.yaml | sudo lxd init --preseed
```

> Note: If you already have LXD configured, check `LXD/preseed.yaml` to manually add the `mbr0` network and the `maas` profile, as the scripts rely on these specific names.

## Usage

Each lab folder contains a `launch.sh` script. This script is the entry point for the automation.

### 1. Launching a Lab
To start a generic lab (e.g., MAAS):

```bash
cd MAAS
./launch.sh
```

The script performs the following actions:
1.  Launch: Creates an LXD VM using the local `cloud-init/` configuration.
2.  Wait: loops until the VM acquires an IP address.
3.  Log Tailing: Automatically SSHs into the VM and tails `/var/log/cloud-init-output.log` so you can watch the installation progress in real-time.
4.  Dashboard: If the service has a web UI (MAAS, Horizon, Landscape), it attempts to open it in your default browser automatically.
5.  Shell: Finally, it drops you into an interactive SSH shell inside the VM.

### 2. Script Arguments
The scripts support flags to alter the deployment type.

| Flag | Applicable Lab | Description |
| :--- | :--- | :--- |
| `[NAME]` | All | The launchers accept an optional positional argument to set the VM name (e.g., `./launch.sh my-build`). |
| `--snap` | MAAS-based | Installs the software (e.g., MAAS) using **Snap** packages instead of the default Deb/Apt packages. |
| `--nn` | MAAS *(Planned for others)* | No-Nest: Switches to a specialized Cloud-Init config for improved topology without nested virtualization. It flattens the topology so no VMs are spawned inside the main VM. |
| `--dev` | OpenStack | Deploys DevStack (Medium load) instead of Charmed OpenStack (Heavy load). |
| `--ha` | Landscape | Deploys a production-grade **High Availability** Charmed Landscape cluster using Juju (Heavy load). |
| `--client` | Landscape | Deploys a lightweight Landscape Client VM configured to register with the Landscape Server. |

Example:
```bash
./launch.sh --snap
```

### 3. Cleaning Up

The cleanup process depends on whether you are running a standard Nested lab or a Non-Nested lab.

#### Standard Labs (Default)
Most labs use Nested Virtualization. This means the lab runs inside a single "Parent" LXD VM. Any nodes created by MAAS or Juju exist *inside* that parent VM.
* Cleanup: Simply delete the parent VM. LXD handles the rest.
    ```bash
    lxc delete -f <vm_name>
    ```

#### No-Nest Labs (`--nn`)
If you run a lab with the `--nn` flag (currently available for MAAS), the lab creates a dedicated LXD Project on your host machine and spawns instances directly on your host (isolated by that project).
* Cleanup: Because resources are spread across a project on your host, the `launch.sh` script dynamically generates a `destroy-<name>.sh` script. You must run this to cleanly remove the project and instances.
    ```bash
    ./destroy-maas.sh
    ```

## Infrastructure Labs: Juju & MAAS

These labs are designed to build the *foundation* of a cloud.

* MAAS: Deploys a Region+Rack controller.
* Juju: Deploys a MAAS environment, *and then* bootstraps a Juju Controller onto it.
    * Result: You get a shell with `juju` pre-configured and connected to the local MAAS cloud, ready for you to `juju deploy` whatever you wish.
    * Resources: ~12 vCPUs, 28GB RAM (Due to nested nodes).

## Heavyweight Labs: OpenStack, Ceph & Landscape HA

These labs are significantly more complex than the others. They utilize *Nested Virtualization* to spawn multiple nodes *inside* the main LXD VM to simulate real-world distributed architectures.

### Kubernetes ("The Hard Way")
This lab automates the manual bootstrap process of a Kubernetes cluster without using Kubeadm or Snap. It manually manages certificates, etcd, and CNI networking.

* Resources: ~8 vCPUs, 16GB RAM.
* Topology (3 Nested VMs):
    * `server`: Control Plane + etcd
    * `node-0`: Worker Node
    * `node-1`: Worker Node

### OpenStack (Charmed)
A full-scale private cloud deployment using Juju.

* Resources: ~20 vCPUs, 50GB RAM.
* Topology (5 Nested VMs):
    * `controller`: Juju Controller
    * `node1` - `node4`: Hyperconverged Compute & Storage Nodes (hosting Nova, Neutron, Ceph OSDs, Vault, MySQL, etc.)

### Ceph Distributed Storage
A software-defined storage cluster simulating real hardware disks via LXD volumes.

* Resources: ~17 vCPUs, 46GB RAM.
* Topology (7 Nested VMs):
    * `controller`: Juju Controller
    * `mon1` - `mon3`: Ceph Monitor Nodes
    * `osd1` - `osd3`: Ceph OSD Nodes (Each node has 3 physical disks attached: `/dev/sdb`, `/dev/sdc`, `/dev/sdd`)

### Landscape HA
A production-grade, highly available systems management server.

* Resources: ~15 vCPUs, 38GB RAM.
* Topology (5 Nested VMs):
    * `controller`: Juju Controller
    * `node1` - `node3`: Service Nodes (HAProxy, PostgreSQL, RabbitMQ, Landscape Server)
    * `client`: A simulation client that auto-registers to the server.

### The Juju Status Watcher
When running these heavy labs, the `launch.sh` script enters an Interactive Watch Mode:

1.  Phase 1 (Log Tail): It tails standard cloud-init logs while MAAS and the Juju Controller are bootstrapping.
2.  Phase 2 (Juju Watch): Once the Juju model is initialized, the script automatically switches views. It clears the screen and displays a live-refreshing `juju status --color` dashboard.
    * This allows you to watch the topology (HAProxy, DBs, RabbitMQ, Nova, etc.) turn "Green" (Active/Idle) in real-time.
3.  Completion: Once all units are active, it opens the dashboards (Horizon/Landscape + MAAS) and drops you into the shell.

### Example Scenarios

Running OpenStack:
```bash
# Full Charmed OpenStack (Heavy)
cd OpenStack
./launch.sh

# DevStack (Medium)
./launch.sh --dev
```

Running Landscape:
```bash
# Standalone Server (Lightweight - installs via Apt)
cd Landscape
./launch.sh

# High Availability Cluster (Heavy - installs via Juju)
./launch.sh --ha

# Client Simulation (Connects to the server above)
./launch.sh --client
```

## Special Lab: Snapcraft

The Snapcraft lab is a dedicated build environment.

* Purpose: Provides a clean `ubuntu:24.04` environment pre-installed with `snapcraft --classic`, `git`, and build tools.
* Credentials: The cloud-init configuration automatically injects `snapcraft-credentials` into `/home/ubuntu/` and exports `SNAPCRAFT_STORE_CREDENTIALS` in the `.bashrc`. This allows you to push snaps to the store immediately without manual login.

## Directory Structure

```text
.
├── Ceph/
│   ├── cloud-init/
│   │   └── cloud-config.yaml           # Charmed Ceph (OSD, Mon, FS)
│   └── launch.sh
├── Juju/
│   ├── cloud-init/
│   │   ├── cloud-config.yaml           # Default (deb MAAS)
│   │   └── cloud-config-snap.yaml      # Snap MAAS
│   └── launch.sh
├── Kubernetes/
│   ├── cloud-init/
│   │   └── cloud-config.yaml           # Automation of "K8s The Hard Way"
│   └── launch.sh
├── Landscape/
│   ├── cloud-init/
│   │   ├── cloud-config-server.yaml    # Default (Standalone)
│   │   ├── cloud-config-ha.yaml        # Used with --ha
│   │   └── cloud-config-client.yaml    # Used with --client
│   └── launch.sh
├── MAAS/
│   ├── cloud-init/
│   │   ├── cloud-config.yaml           # Default (Deb install)
│   │   ├── cloud-config-nn.yaml        # Non-nested MAAS --nn
│   │   └── cloud-config-snap.yaml      # Used with --snap
│   │   └── cloud-config-snap-nn.yaml   # Non-nested Snap MAAS --nn + --snap (Currently not working)
│   └── launch.sh
├── OpenStack/
│   ├── cloud-init/
│   │   ├── cloud-config.yaml           # Charmed OpenStack
│   │   └── cloud-config-devstack.yaml  # DevStack
│   └── launch.sh
├── Snapcraft/
│   ├── cloud-init/
│   │   └── cloud-config.yaml           # Pre-seeded credentials
│   └── launch.sh
└── LXD/
    ├── cloud-config.yaml               # Default cloud-config.yaml
    └── lxd_preseed.yaml                # LXD Preseed file
```
