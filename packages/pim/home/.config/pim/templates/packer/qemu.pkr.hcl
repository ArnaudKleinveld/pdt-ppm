# Packer QEMU Builder Template
# Used for building qcow2 images from ISO

packer {
  required_plugins {
    qemu = {
      version = ">= 1.0.0"
      source  = "github.com/hashicorp/qemu"
    }
  }
}

variable "vm_name" { type = string }
variable "iso_url" { type = string }
variable "iso_checksum" { type = string }
variable "output_directory" { type = string }
variable "http_directory" { type = string }

variable "disk_size" { 
  type = string 
  default = "20G"
}
variable "memory" { 
  type = number 
  default = 2048
}
variable "cpus" { 
  type = number 
  default = 2
}

variable "ssh_username" { type = string }
variable "ssh_password" { type = string }
variable "ssh_timeout" { 
  type = string 
  default = "30m"
}

variable "boot_wait" { 
  type = string 
  default = "5s"
}
variable "boot_command" { type = list(string) }
variable "shutdown_command" { type = string }

variable "headless" { 
  type = bool 
  default = true
}
variable "accelerator" { 
  type = string 
  default = "hvf"
}
variable "format" { 
  type = string 
  default = "qcow2"
}
variable "disk_interface" { 
  type = string 
  default = "virtio"
}
variable "net_device" { 
  type = string 
  default = "virtio-net"
}

# Architecture-specific settings
variable "qemu_binary" {
  type    = string
  default = ""
}
variable "machine_type" {
  type    = string
  default = "virt"
}
variable "cpu_type" {
  type    = string
  default = "host"
}
variable "efi_boot" {
  type    = bool
  default = true
}
variable "efi_firmware_code" {
  type    = string
  default = ""
}
variable "efi_firmware_vars" {
  type    = string
  default = ""
}

# Display type: "cocoa" for macOS GUI, "none" for headless
variable "display" {
  type    = string
  default = "none"
}

source "qemu" "main" {
  vm_name          = var.vm_name
  iso_url          = var.iso_url
  iso_checksum     = var.iso_checksum
  output_directory = var.output_directory
  
  disk_size        = var.disk_size
  memory           = var.memory
  cpus             = var.cpus
  
  ssh_username     = var.ssh_username
  ssh_password     = var.ssh_password
  ssh_timeout      = var.ssh_timeout
  
  http_directory   = var.http_directory
  boot_wait        = var.boot_wait
  boot_command     = var.boot_command
  shutdown_command = var.shutdown_command
  
  headless         = var.headless
  accelerator      = var.accelerator
  format           = var.format
  disk_interface   = var.disk_interface
  net_device       = var.net_device
  
  # Architecture-specific
  qemu_binary      = var.qemu_binary
  machine_type     = var.machine_type
  
  # EFI settings (required for ARM64)
  efi_boot          = var.efi_boot
  efi_firmware_code = var.efi_firmware_code
  efi_firmware_vars = var.efi_firmware_vars
  
  # Display setting
  display          = var.display
  
  qemuargs = [
    ["-cpu", var.cpu_type]
  ]
}

build {
  sources = ["source.qemu.main"]
}
