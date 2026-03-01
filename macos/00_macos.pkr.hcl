packer {
  required_plugins {
    ipsw = {
      version = ">= 0.1.9"
      source = "github.com/torarnv/ipsw"
    }
    tart = {
      version = ">= 1.20.0"
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

variable "ansible_requirements" {
  type = string
  default = null
  description = "Path to requirements.yml for Ansible Galaxy"
}

variable "ansible_extra_arguments" {
  type = list(string)
  default = []
  description = "Additional arguments to pass to Ansible"
}

# Debugging

variable "from_image" {
  type = string
  default = null
  description = "Continue from existing image"
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
  skip = var.from_image != null
  os = "macOS"
  version = var.version
  device = "VirtualMac2,1"
}

locals {
  ipsw = data.ipsw.macos
  ipsw_valid = length(local.ipsw) > 0
  ipsw_url = local.ipsw_valid ? local.ipsw.url : null
  version_number = (local.ipsw_valid ? (local.ipsw.version_components.minor < 10 ?
      (local.ipsw.version_components.major + (local.ipsw.version_components.minor / 10)) : null)
      : convert(var.version, number))

  vm_name = (local.ipsw_valid ?
    "macos:${local.ipsw.version}${var.skip_setup ? "+created" : ""}" :
    "${var.from_image}+${var.skip_setup ? "provisioned" : "installed"}"
  )

  skip_provisioning = var.skip_provisioning || (var.from_image == null && var.skip_setup)

  # Workaround for https://github.com/hashicorp/packer/issues/13299
  template_vars = {
    vm_name = local.vm_name
    username = var.username
    password = var.password
    disable_sip = var.disable_sip
    pause_after_setup = var.pause_after_setup
    skip_provisioning = var.skip_provisioning
    ansible_playbook = var.ansible_playbook
  }

  boot_commands = yamldecode(
    templatefile("01_boot.pkrtpl.yml", local.template_vars)
  )
}

source "tart-cli" "unattended-setup" {
  vm_name = local.vm_name

  # Either from IPSW or existing base image
  from_ipsw = local.ipsw_url
  vm_base_name = var.from_image

  cpu_count = var.cpu_count
  memory_gb = var.memory_size
  disk_size_gb = var.disk_size

  run_extra_args = var.no_audio ? [ "--no-audio" ] : []

  # Ventura and below default to non-HighDPI resolution,
  # so give it less pixels to improve boot command OCR.
  display = local.version_number < 14 ? "512x384" : "1024x768"
  headless = var.headless

  # Workaround for VZErrorDomain Code=2 "Failed to lock auxiliary storage.",
  # where a VM is not usable (for OS installation) immediately after creation.
  create_grace_time = "30s"

  # Initial setup
  recovery = !var.skip_setup
  boot_command = var.skip_setup ? null : local.boot_commands.setup_macos
  boot_key_interval = "10ms"
  http_content = {
    "/setup.sh" = "${join("\n",
      [for k, v in local.template_vars : format("%s=%s ",
        upper(k), v != null ? try(convert(v, string), "") : "")]
    )}\n\n${file("02_setup.sh")}"
  }

  # Provisioning
  communicator = local.skip_provisioning ? "none" : "ssh"
  ssh_username = var.username
  ssh_password = var.password
  ssh_timeout  = "10m"
}

build {
  name = local.vm_name

  source "source.tart-cli.unattended-setup" {}

  # Basic provisioning via shell script
  provisioner "shell" {
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
      playbook_file = var.ansible_playbook
      galaxy_file = var.ansible_requirements
      user = var.username
      host_alias = local.vm_name
      ansible_env_vars = [
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
