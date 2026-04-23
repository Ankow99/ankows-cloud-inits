# se-polymerase 🧬

Polymerase is a zero-state, Terraform-free reproducer repository designed exclusively for Support Engineering. It houses the "DNA", parameterised Jinja2 `cloud-config.yaml` templates for complex OpenStack, Kubernetes, and MAAS + Juju support deployments.

At the core of the project is `synth`, a standalone LXD orchestrator that acts as the active enzyme. Instead of relying on Terraform, `synth` reads the reproducer's payload, prompts for required variables on the fly, provisions isolated LXD projects and networks, tracks the deployment in real time by tailing the logs, and generates a bespoke teardown script.

### Key Features
* Parses Jinja `cloud-config.yaml` payloads to dynamically calculate hardware requirements and generate interactive CLI prompts.
* Supports nested LXD architectures or bare-metal LXD daemons.
* Provisions `ipv4.nat` bridges, calculates CIDR gateways, and validates DHCP settings to prevent collisions.
* Auto-injects local or Launchpad SSH keys and establishes a multiplexed SSH tunnel for dashboard port-forwarding.
* Tails `cloud-init` logs and seamlessly transitions to a live juju status watch-loop.
* Generates a project-specific teardown script to destroy the LXD project, un-trust certificates, and remove dynamic networks.

---

## Prerequisites

Ensure the following dependencies are installed on the host machine:
* `lxd`
* `jq`
* `openssl`
* `python3`

---

## Usage

Clone the repository to your local machine:

```bash
git clone https://github.com/Ankow99/se-polymerase.git
cd se-polymerase
```

```bash
./synth [OPTIONS] <CLOUD_INIT_FILE> [DEPLOY_ID]
```

### Arguments
| Argument | Description |
| :--- | :--- |
| `CLOUD_INIT_FILE` | (Required) Path to the `cloud-config.yaml` template. |
| `DEPLOY_ID` | (Optional) Custom alphanumeric deployment ID (max 8 characters). Defaults to a random 8-character hex string. |

### Options
| Flag | Description |
| :--- | :--- |
| `-h, --help` | Show the help menu. |
| `-a, --accept-defaults` | Bypass interactive CLI prompts and auto-accept all template defaults. |
| `-n, --nested` | Deploy using a nested LXD architecture. |
| `-d, --deb` | Force DEB packages for MAAS instead of the default snap. |
| `--lp <id>` | Import SSH public keys from a Launchpad account. |

### Examples

Deploy interactively with a custom ID:
```bash
./synth ./sunbeam/cloud-init.yaml 00426900
```

Deploy an automated nested cluster using Launchpad keys:
```bash
./synth -a -n --lp pgdg99 ./openstack/cloud-init.yaml
```

---

## Building Payloads

`synth` parses standard Jinja comments to generate the CLI wizard. Format your `cloud-init.yaml` variables using the following standards:

### Standard Variables
Add a `# PROMPT: <Text>` comment after a Jinja variable to trigger the interactive UI.
```jinja
{% set custom_sys_user = "ubuntu" %}                # PROMPT:System User
{% set custom_juju_channel = "3.6/stable" %}        # PROMPT:Juju Channel
```

### Hardware Allocation
Use the suffixes `_cpu`, `_ram`, `_disk`, and `_ha` to enable `synth` to automatically calculate host resource capacity.
```jinja
{% set custom_juju_ha = 1 %}                        # PROMPT:Number of Juju Controllers
{% set custom_juju_cpu = "3" %}                     # PROMPT:Juju Controller CPU cores
{% set custom_juju_ram = "6GiB" %}                  # PROMPT:Juju Controller RAM
{% set custom_juju_disk = "30GiB" %}                # PROMPT:Juju Controller Root Disk
```

### Dynamic Networking
Use the `[BRIDGE:dhcp=<true/false>,cidr=<var_name>]` tag to instruct synth to provision an isolated LXD network.
```jinja
{% set custom_maas_bridge = "mbr0" %}               # PROMPT:MAAS Bridge Name [BRIDGE:dhcp=false,cidr=maas_cidr]
{% set custom_maas_cidr = "10.10.0.0/22" %}
```

### Juju Trigger
Define the string that signals the end of normal `cloud-init-output.log` tailing and the start of the Juju deployment so it switches to a Juju status watch:
```jinja
{% set custom_juju_trigger = "-------- Bootstrapping Juju Controller... --------" %}
```

---

## Cleanup

`synth` generates a `destroy-<project_name>.sh` file in the same directory as the payload. 

Execute this script to wipe the LXD project, remove the associated dynamic networks, and close background SSH multiplex sockets.

```bash
./destroy-maas-00436900.sh
```
