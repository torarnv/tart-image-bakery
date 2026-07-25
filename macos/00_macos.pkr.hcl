packer {
  required_plugins {
    ipsw = {
      version = ">= 0.1.9"
      source = "github.com/torarnv/ipsw"
    }
    tart = {
      version = ">= 1.21.0"
      source  = "github.com/cirruslabs/tart"
    }
    ansible = {
      version = "~> 1"
      source = "github.com/hashicorp/ansible"
    }
  }
}

# -------------- Configuration --------------

variable "version" {
  type = string
  default = null
  description = "macOS version"
  validation {
    condition = var.version != null
    error_message = <<-EOF
    Please provide a version. When used alone it will search for the most recent
    IPSW file matching the version expression. If used with from_image, the given
    version must match the image.
    EOF
  }
}

# VM

variable "cpu_count" {
  type = number
  default = 4
  description = "CPU count"
}

variable "memory_size" {
  type = number
  default = 8
  description = "Memory size in GB"
}

variable "disk_size" {
  type = number
  default = 50
  description = "Disk size in GB"
}

variable "recovery_partition" {
  type = string
  default = null
  description = <<-EOF
  Behavior with respect to the macOS recovery partition:
    - "delete": allows disk resize, decreases image size, prevents softwareupdate
    - "keep": prevents disk resize, increases image size, allows softwareupdate
    - "relocate": allows disk resize, increases image size, allows softwareupdate
  Defaults to the plugin default if not specified.
  EOF

  validation {
    condition = var.recovery_partition == null || contains(["delete", "keep", "relocate"], var.recovery_partition)
    error_message = "Value of recovery_partition must be one of: delete, keep, or relocate."
  }
}

variable "no_audio" {
  type = bool
  default = true
}

# Installation / provisioning

variable "username" {
  type = string
  default = "admin"
}

variable "password" {
  type = string
  default = "admin"
  sensitive = true
  validation {
    condition = length(var.password) >= 4
    error_message = "Password must have a length of four characters or more."
  }
}

variable "disable_sip" {
  type = bool
  default = false
  description = "Disable System Integrity Protection (SIP)"
}

# Provisioning

variable "provisioning_script" {
  type = string
  default = null
  description = "Path to provisioning script. The default does minimal provisioning."
}

variable "ansible_playbook" {
  type = string
  default = null
  description = "Path to Ansible playbook"
}

variable "ansible_extra_arguments" {
  type = list(string)
  default = []
  description = "Additional arguments to pass to Ansible"
}

# Debugging

variable "from_ipsw" {
  type = string
  default = null
  description = "Install from IPSW"
}

variable "from_image" {
  type = string
  default = null
  description = "Continue from existing image"
}

variable "vm_name" {
  type = string
  default = null
  description = "VM name. If not set, the name is derived automatically."
}

variable "skip_setup" {
  type = bool
  default = false
  description = "For IPSW, just creates VM. For base image, only provisions."
}

variable "skip_provisioning" {
  type = bool
  default = false
  description = "Skips provisioning"
}

variable "pause_after_setup" {
  type = bool
  default = false
  description = "Pauses in RecoveryOS after running setup"
}

variable "headless" {
  type = bool
  default = true
  description = "Whether to show the graphics interface of the VM"
}

# -------------- Build --------------

data "ipsw" "macos" {
  skip = var.from_image != null || var.from_ipsw != null
  os = "macOS"
  version = var.version
  device = "VirtualMac2,1"
}

locals {
  ipsw = data.ipsw.macos
  ipsw_valid = length(local.ipsw) > 0
  ipsw_url = var.from_ipsw != null ? var.from_ipsw : (local.ipsw_valid ? local.ipsw.url : null)

  version = local.ipsw_valid ? local.ipsw.version : var.version
  version_number = (local.ipsw_valid ? (local.ipsw.version_components.minor < 10 ?
      (local.ipsw.version_components.major + (local.ipsw.version_components.minor / 10)) : null)
      : convert(var.version, number))

  vm_name = var.vm_name != null ? var.vm_name : (local.ipsw_url != null ?
    "macos:${local.version}${var.skip_setup ? "+created" : ""}" :
    "${var.from_image}+${var.skip_setup ? "provisioned" : "installed"}"
  )

  use_builtin_guest_provisioning = local.version_number >= 27
  audio_args = var.no_audio ? ["--no-audio"] : []

  skip_provisioning = var.skip_provisioning || (var.from_image == null && var.skip_setup)

  ansible_requirements = var.ansible_playbook != null ? format("%s/requirements%s",
    dirname(abspath(var.ansible_playbook)),
    regex("\\.[^.]+$", basename(var.ansible_playbook))
  ) : null

  # Workaround for https://github.com/hashicorp/packer/issues/13299
  template_vars = {
    vm_name = local.vm_name
    username = var.username
    password = var.password
    disable_sip = var.disable_sip
    pause_after_setup = var.pause_after_setup
    skip_provisioning = var.skip_provisioning
    ansible_playbook = var.ansible_playbook
    version_number = local.version_number
  }

  boot_commands = yamldecode(
    templatefile("01_boot.pkrtpl.yml", local.template_vars)
  )
}

source "tart-cli" "defaults" {
  vm_name = local.vm_name

  cpu_count = var.cpu_count
  memory_gb = var.memory_size
  disk_size_gb = var.disk_size
  recovery_partition = var.recovery_partition

  # Ventura and below default to non-HighDPI resolution,
  # so give it less pixels to improve boot command OCR.
  display = local.version_number < 14 ? "512x384" : "1024x768"
  headless = var.headless

  # Workaround for VZErrorDomain Code=2 "Failed to lock auxiliary storage.",
  # where a VM is not usable (for OS installation) immediately after creation.
  create_grace_time = "30s"

  # Provisioning
  ssh_username = var.username
  ssh_password = var.password
  ssh_timeout  = "10m"
}

build {
  name = local.vm_name

  # Use VZMacGuestProvisioningOptions on macOS 27+
  dynamic "source" {
    for_each = (
      local.use_builtin_guest_provisioning && !var.skip_setup
        ? ["guest-provisioning"] : []
    )
    labels = ["tart-cli.defaults"]

    content {
      name = source.value

      from_ipsw = local.ipsw_url
      vm_base_name = var.from_image

      run_extra_args = concat(
        local.audio_args,
        ["--provisioning-opts=${join(",", [
          "fullName=${var.username}",
          "username=${var.username}",
          "password=${var.password}",
          "logsInAutomatically=true",
          "enablesRemoteLogin=true",
        ])}"]
      )

      communicator = "ssh"
    }
  }

  provisioner "shell" {
    only = [ "tart-cli.guest-provisioning" ]
    # Make sure Setup Assistant has fully completed
    inline = [ "until pgrep -x Dock >/dev/null; do sleep 1; done" ]
  }

  # Full setup on macOS < 27, or VNC and SIP on macOS 27
  source "source.tart-cli.defaults" {
    name = "unattended-setup"

    from_ipsw = !local.use_builtin_guest_provisioning ? local.ipsw_url : null
    vm_base_name = !local.use_builtin_guest_provisioning ? var.from_image : null

    recovery = !var.skip_setup
    run_extra_args = local.audio_args

    boot_command = var.skip_setup ? null : local.boot_commands.setup_macos
    boot_key_interval = "10ms"
    http_content = {
      "/setup.sh" = "${join("\n",
        [for k, v in local.template_vars : format("%s=%s ",
          upper(k), v != null ? try(convert(v, string), "") : "")]
      )}\n\n${file("02_setup.sh")}"
    }

    communicator = local.skip_provisioning ? "none" : "ssh"
  }

  # Basic provisioning via shell script
  provisioner "shell" {
    only = [ "tart-cli.unattended-setup" ]
    script = var.provisioning_script != null ? var.provisioning_script : "${path.root}/03_provision.sh"
    environment_vars = [
      for k, v in local.template_vars : format("PKR_VAR_%s=%s",
        k, v != null ? try(convert(v, string), "") : "")
    ]
  }

  # Advanced provisioning via Ansible
  dynamic "provisioner" {
    labels = ["ansible"]
    for_each = var.ansible_playbook != null && !local.skip_provisioning ? [1] : []
    content {
      only = [ "tart-cli.unattended-setup" ]
      playbook_file = var.ansible_playbook
      galaxy_file = fileexists(local.ansible_requirements) ? local.ansible_requirements : null
      user = var.username
      host_alias = local.vm_name
      ansible_env_vars = [
        "ANSIBLE_CONFIG=${dirname(abspath(var.ansible_playbook))}/ansible.cfg",
        "ANSIBLE_PYTHON_INTERPRETER=/usr/bin/python3",
        "ANSIBLE_SSH_TRANSFER_METHOD=piped"
      ]
      extra_arguments = concat([
          "--extra-vars", "\"${join(" ",
            [for k, v in local.template_vars : format("packer_%s=%s ",
                 k, v != null ? try(convert(v, string), "") : "")]
          )}\""
        ],
        var.ansible_extra_arguments
      )
    }
  }
}
