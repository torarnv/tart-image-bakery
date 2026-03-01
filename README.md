# 🥧 Tart Image Bakery

Automated macOS virtual machines for Tart using HashiCorp Packer,
with provisioning via shell script or Ansible.

![image-bakery](https://github.com/user-attachments/assets/2d1a941f-bc59-40ec-9f25-c2297581c88f)

> [!IMPORTANT]
> This project bypasses Setup Assistant for unattended installation, which may have unexpected
> side effects. For development and testing only ⚠️
>
> Please make sure you read and accept the [license agreement](https://www.apple.com/legal/sla/)
> of the macOS version you're installing.

## Features

- **Automatic IPSW download handling**: Specify version to download the correct IPSW file
- **Fully unattended installation**: Automated macOS setup without Setup Assistant interaction
- **System Integrity Protection (SIP) management**: Optional automated SIP disabling during setup
- **Customizable resources**: Configure CPU count, memory size, and disk size
- **Minimal provisioning**: Default minimal provisioning for base images
  - Passwordless `sudo` enabled
  - Screensaver, sleep, and lock screen disabled
  - SSH and VNC services enabled
  - Python installed (when Ansible is used)
- **Optional Ansible provisioning**: Bring your own Ansible playboooks

## Installation

```bash
brew install hashicorp/tap/packer
brew install cirruslabs/cli/tart
brew install ansible # Optional
packer init macos
```

## Usage

### Basic VM creation

```bash
packer build -var version=26 macos
```

### Custom VM configuration

```bash
packer build \
  -var version=26 \
  -var cpu_count=8 \
  -var memory_size=16 \
  -var disk_size=100 \
  -var username=developer \
  -var password=hunter2 \
  macos
```

### Disable SIP

```bash
packer build \
  -var version=26 \
  -var disable_sip=true \
  macos
```

### Pre-release VM creation

```bash
packer build -var version=26-0 macos
```

### With Ansible provisioning

```bash
packer build \
  -var version=26 \
  -var ansible_playbook=playbook.yml \
  macos
```

### Override provisioning script

```bash
packer build \
  -var version=26 \
  -var provisioning_script=/path/to/custom-setup.sh \
  macos
```
