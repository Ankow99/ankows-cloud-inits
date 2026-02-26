# Ankow's LXD Cloud-Init Reproducers & Launchers

This repository contains a collection of automated local laboratory environments for various cloud technologies. Each environment is self-contained and reproducible, utilising LXD VMs and Cloud-Init to bootstrap complex setups like MAAS, OpenStack, Kubernetes, and more.

The core of this project is a standardised `launch.sh` script included in each directory, which automates the lifecycle of the lab: launching, configuring, log-tailing, and providing cleanup mechanisms.

## Available Labs

The following environments are available in their respective directories:

* LXD (Contains the global preseed configuration)
* Snapcraft (Automated build environment)
* MAAS (Metal as a Service)
* Juju (Bootstraps a Juju Controller on MAAS)
* Ceph (Distributed Storage Cluster)
* Landscape (Standalone, Client, & High Availability modes)
* Kubernetes (Charmed, Micro K8s, and "The Hard Way" Automated)
* OpenStack (Includes Full Charmed OpenStack & DevStack modes)

## Prerequisites

To use these launchers, your host machine must meet the following requirements:

1.  OS: Ubuntu (made and tested in 24.04)
2.  Resources: Not all labs require high amounts of RAM & CPU, but they were made for a 64 GB and 22 CPU workstation.
3.  LXD: Installed and initialised using the provided preseed (necessary network bridges and profiles)
4.  Dependencies: `lxd` and `jq` (Required for parsing JSON output in the launch scripts)

```bash
sudo apt update
sudo apt install jq
sudo snap install lxd
```

## Installation

Clone the repository to your local machine:

```bash
git clone https://github.com/Ankow99/ankows-cloud-inits.git
cd ankows-cloud-inits
```

### Setup: Important Customisation

Before launching any labs, you must update the Cloud-Init files with your own credentials.

#### SSH Access
Every `cloud-config.yaml` file in this repository is currently configured to import SSH keys from a specific Launchpad ID:

```yaml
ssh_import_id: ['lp:pgdg99']
ssh_authorized_keys: [ssh-ed25519 AAAAC3....]
```
> You must replace `pgdg99` with your own Launchpad username. The block `ssh_authorized_keys` block is a redundant SSH auth method in case the connection with Launchpad fails; replace with your own public key.

#### Host's LXD Certificate Generation & Authorisation
Non-nested virtualisation labs use the host's LXD as their VM host. This means you need to create an X.509 certificate, add it to the LXD trusted list, and then inject the `.crt` and `.key` files content into the non-nested lab Cloud-Inits.

1. Generate an X.509 certificate and key pair, save these:
```bash
openssl req -x509 -newkey rsa:4096 -keyout maas-client.key -out maas-client.crt -nodes -days 3650 -subj "/CN=maas-client"
```

2. On your host machine, add to the LXD's trusted list the generated certificate:
```bash
lxc config trust add maas-client.crt --name maas-client
```

3. Copy the `.crt` and `.key` contents into the non-nested cloud-inits:
```yaml
- path: /root/lxd-host.crt
  owner: root:root
  permissions: '0644'
  content: |
    -----BEGIN CERTIFICATE-----
    [PASTE CERTIFICATE CONTENT HERE]
    -----END CERTIFICATE-----

- path: /root/lxd-host.key
  owner: root:root
  permissions: '0600'
  content: |
    -----BEGIN PRIVATE KEY-----
    [PASTE PRIVATE KEY CONTENT HERE]
    -----END PRIVATE KEY-----
```

#### Snapcraft Credentials
The Snapcraft lab automates the login process by injecting a credentials file. Inside `Snapcraft/cloud-init/cloud-config.yaml`, you will find a large encoded block:

```yaml
- |
  cat <<EOF > /home/ubuntu/snapcraft-credentials
  [INSERT YOUR CREDENTIALS HERE]
```
> You must replace `[INSERT YOUR CREDENTIALS HERE]` with your own Snapcraft credentials. You can see how to generate them [here](https://documentation.ubuntu.com/snapcraft/stable/how-to/publishing/authenticate/).

#### Ubuntu Pro Token
The Landscape Client lab automates the Ubuntu Pro attach. Inside `Landscape/cloud-init/cloud-config-client.yaml`, you will find a token:

```yaml
- pro attach <pro-token>
```

> You must replace `<pro-token>` with your own Landscape token.

### Setup: Initialising LXD

Critical Step: Before running any labs, you must initialise LXD with the specific network and profile configurations required by these scripts.

A preseed file is provided in the `LXD/` folder. This configures:
* LXD listening on `[::]:8443`.
* lxdbr0: `10.10.10.1/24` (NAT enabled)
* mbr0: `10.0.0.1/22` (No DHCP, NAT enabled, used for non-nested MAAS/Infrastructure layers)
* Storage: `500 GiB` ZFS pool named `default`. (Labs use much less, but some can use up to `250 GiB` at a time)
* Profiles: A custom `default` profile with standard tools (neovim, git) and a `maas` profile with specific network attachments.

To initialise LXD:

```bash
# 1. Navigate to the LXD folder
cd LXD

# 2. Feed the preseed into LXD initialisation
cat lxd_preseed.yaml | sudo lxd init --preseed
```

> Note: If you already have LXD configured, check `LXD/preseed.yaml` to manually add the `mbr0` network and the `maas` profile, as the scripts rely on these specific names. Configure LXD to listen to `[::]:8443`, or replace the power address IPs in each cloud-init when adding LXD as a MAAS VM Host.

---

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
| `--snap` | MAAS & Juju | Installs MAAS using *Snap* package instead of the default *Deb/Apt* package. |
| `--nn` | MAAS-based deployments | No-Nest: Switches to a specialised Cloud-Init config for improved topology without nested virtualisation. It flattens the topology so no VMs are spawned inside the main VM. |
| `--dev` | OpenStack | Deploys DevStack (Medium load) instead of Charmed OpenStack (Heavy load). |
| `--ha` | Landscape | Deploys a production-grade **High Availability** Charmed Landscape cluster using Juju (Heavy load). |
| `--client` | Landscape | Deploys a lightweight Landscape Client VM configured to register with the Landscape Server. |
| `--micro` | Kubernetes | Deploys a lightweight single-node version of Kubernetes designed for local development and testing.|
| `--thw` | Kubernetes | Deploys a Kubernetes cluster without using Kubeadm or Snap. It manually manages certificates, etcd, and CNI networking. |

Example:
```bash
./launch.sh --snap
```

### 3. Cleaning Up

The cleanup process depends on whether you are running a standard Nested lab or a non-nested lab.

![Nested vs Non-Nested Topology](MAAS/nested-vs-non-nested.png)

#### Standard Labs (Default)
Unless the '`--nn`' flag is specified, most labs use nested virtualisation. This means the lab runs inside a single "parent" LXD VM. Any nodes created by MAAS or Juju exist *inside* that parent VM.
* Cleanup: Simply delete the parent VM. LXD handles the rest.
    ```bash
    lxc delete -f <vm_name>
    ```
* Cleanup: Some labs; even without being non-nested, automatically create IP routes to communicate with the nested VMs; the `launch.sh` script dynamically generates a `destroy-<vm-name>.sh` script, which automatically removes those. You must run this to cleanly remove the created routes and instance.
    ```bash
    ./destroy-<vm-name>.sh
    ```

#### Non-nested Labs (`--nn`)
If you run a lab with the `--nn` flag (any MAAS-based lab), the lab creates a dedicated LXD Project on your host machine and spawns instances directly on your host (isolated by that project).
* Cleanup: Because resources are spread across a project on your host, the `launch.sh` script dynamically generates a `destroy-<vm-name>.sh` script. You must run this to cleanly remove the project and instances.
    ```bash
    ./destroy-<vm-name>.sh
    ```

---

## Infrastructure Labs: Juju & MAAS

These labs are designed to build the *foundation* of a cloud. Can be deployed either using nested virtualisation or not.

* MAAS: Deploys a Region+Rack controller.
* Juju: Deploys a MAAS environment, *and then* bootstraps a Juju Controller onto it.
    * Result: You get a shell with `juju` pre-configured and connected to the local MAAS cloud, ready for you to `juju deploy` whatever you wish.
    * Resources: 12 vCPUs, 28GB RAM by default.

---

## Heavyweight Labs: Charmed OpenStack, DevStack, Charmed Kubernetes, Kubernetes "The Hard Way", Charmed Ceph & HA Landscape

These labs are significantly more complex than the others. They utilise *Nested Virtualisation* (unless specified not to) to spawn multiple nodes *inside* the main LXD VM to simulate real-world distributed architectures. When deployed as a non-nested lab, the architecture and requirements are the same, but instead of residing in a single VM with the necessary allocated VMs, they directly use the host's LXD resources.

### -  Charmed OpenStack
A full-scale private cloud deployment using Juju.

* Resources: 20 vCPUs, 50GB RAM.
* Topology (4 Nodes + 1 Juju Controller):
    * `controller`: Juju Controller
    * `node1` - `node4`: Hyperconverged Compute & Storage Nodes (hosting Nova, Neutron, Ceph OSDs, Vault, MySQL, etc.)

### -  DevStack (--dev)
A set of scripts and utilities to quickly deploy a single-node OpenStack cloud from git source trees.

* Resources: 15 vCPUs, 40GB RAM.

### -  Charmed Kubernetes

WIP - As of right now, these labs only create an empty Juju model.

### -  Kubernetes "The Hard Way" (--thw)
This lab automates the manual bootstrap process of a Kubernetes cluster without using Kubeadm or Snap. It manually manages certificates, etcd, and CNI networking.

* Resources: 8 vCPUs, 18GB RAM.
* Topology (3 Nested VMs):
    * `server`: Control Plane + etcd
    * `node-0`: Worker Node
    * `node-1`: Worker Node

### -  Charmed Ceph
A software-defined storage cluster simulating real hardware disks via LXD volumes.

* Resources: 17 vCPUs, 46GB RAM.
* Topology (6 Nodes + 1 Juju Controller):
    * `controller`: Juju Controller
    * `mon1` - `mon3`: Ceph Monitor Nodes
    * `osd1` - `osd3`: Ceph OSD Nodes (Each node has 3 physical disks attached: `/dev/sdb`, `/dev/sdc`, `/dev/sdd`)

### -  Highly Available Landscape (--ha)
A production-grade, highly available systems management server.

* Resources: 15 vCPUs, 38GB RAM.
* Topology (3 Nodes + 1 Client + 1 Juju Controller):
    * `controller`: Juju Controller
    * `node1` - `node3`: Service Nodes (HAProxy, PostgreSQL, RabbitMQ, Landscape Server)
    * `client`: A simulation client that auto-registers to the server.
    * 
---

#### The Juju Status Watcher
When running these heavy labs, the `launch.sh` script enters a juju status + cloud-init output watch mode:

1.  Phase 1 (Log Tail): It tails standard cloud-init logs while MAAS and the Juju Controller are bootstrapping.
2.  Phase 2 (Juju Watch): Once the Juju model is initialised, the script automatically switches views. It clears the screen and displays a live-refreshing `juju status --color` + cloud-init logs dashboard.
    * This allows you to watch the topology (HAProxy, DBs, RabbitMQ, Nova, etc.) turn "Green" (Active/Idle) in real-time.
3.  Completion: Once all units are active, it opens the dashboards (Horizon/Landscape + MAAS) and drops you into the shell.

---

## Lightweight Labs: Landscape Server, Landscape Client & Micro K8s

These labs do not make use of the MAAS + Juju infrastructure that the rest of the labs use.

### -  Landscape Server
A standalone deb Landscape server installation (on-prem).

* Resources: 2 vCPUs, 6GB RAM.

### -  Landscape Client (--client)
Automatically sets up a Landscape client and connects it to a Landscape Server.

* Resources: 2 vCPUs, 6GB RAM.

> You must add the Landscape Server IP inside the cloud-init for it to work. (`LANDSCAPE_SERVER_IP=<ip>`)

### -  Micro K8s (--micro)
A lightweight single-node version of Kubernetes designed for local development and testing.

* Resources: 4 vCPUs, 8GB RAM.

---

## Special Lab: Snapcraft

The Snapcraft lab is a dedicated build environment.

* Purpose: Provides a clean `ubuntu:24.04` environment pre-installed with `snapcraft --classic`, `git`, and build tools.
* Credentials: The cloud-init configuration automatically injects `snapcraft-credentials` into `/home/ubuntu/` and exports `SNAPCRAFT_STORE_CREDENTIALS` in the `.bashrc`. This allows you to push snaps to the store immediately without manual login.

---

## Example Scenarios

Running OpenStack:
```bash
# Full non-nested charmed OpenStack (Heavy)
cd OpenStack
./launch.sh --nn

# Full charmed OpenStack (Heavy - Worse)
cd OpenStack
./launch.sh

# DevStack (Medium)
./launch.sh --dev
```

Running Landscape:
```bash
# Standalone server (Lightweight - installs via Apt)
cd Landscape
./launch.sh

# High availability cluster (Heavy - installs via Juju)
./launch.sh --ha

# Non-nested high availability cluster (Heavy - installs via Juju)
./launch.sh --nn

# Client simulation (Connects to the server above)
./launch.sh --client
```

---

## Directory Structure

```text
.
├── Ceph/
│   ├── cloud-init/
│   │   ├── cloud-config.yaml           # Charmed Ceph (Default)
│   │   └── cloud-config-nn.yaml        # Non-nested charmed Ceph --nn
│   └── launch.sh
├── Juju/
│   ├── cloud-init/
│   │   ├── cloud-config.yaml           # Juju with deb MAAS (Default)
│   │   ├── cloud-config-nn.yaml        # Non-nested Juju with deb MAAS --nn
│   │   ├── cloud-config-snap.yaml      # Juju with snap MAAS --snap
│   │   └── cloud-config-snap-nn.yaml   # Non-nested Juju with snap MAAS --nn + --snap
│   └── launch.sh
├── Kubernetes/
│   ├── cloud-init/
│   │   ├── cloud-config.yaml           # Charmed Kubernetes (Default) (WIP)
│   │   ├── cloud-config-nn.yaml        # Non-nested charmed Kubernetes --nn (WIP)
│   │   ├── cloud-config-micro.yaml     # Micro K8s --micro
│   │   └── cloud-config-thw.yaml       # Automation of "K8s The Hard Way" --thw
│   └── launch.sh
├── Landscape/
│   ├── cloud-init/
│   │   ├── cloud-config-server.yaml    # Standalone deb install (Default)
│   │   ├── cloud-config-ha.yaml        # HA charmed Landscape --ha
│   │   ├── cloud-config-ha-nn.yaml     # Non-nested HA charmed Landscape --nn
│   │   └── cloud-config-client.yaml    # Landscape client --client
│   └── launch.sh
├── MAAS/
│   ├── cloud-init/
│   │   ├── cloud-config.yaml           # Deb MAAS (Default)
│   │   ├── cloud-config-nn.yaml        # Non-nested deb MAAS --nn
│   │   ├── cloud-config-snap.yaml      # Snap MAAS --snap
│   │   └── cloud-config-snap-nn.yaml   # Non-nested snap MAAS --nn + --snap
│   └── launch.sh
├── OpenStack/
│   ├── cloud-init/
│   │   ├── cloud-config.yaml           # Charmed OpenStack (Default)
│   │   ├── cloud-config-nn.yaml        # Non-nested charmed OpenStack --nn
│   │   └── cloud-config-devstack.yaml  # DevStack --dev
│   └── launch.sh
├── Snapcraft/
│   ├── cloud-init/
│   │   └── cloud-config.yaml           # Pre-seeded credentials
│   └── launch.sh
└── LXD/
    ├── cloud-config.yaml               # Default cloud-config.yaml
    └── lxd_preseed.yaml                # LXD Preseed file
```
