# proxmox-iso builder variables
##### Required Variables #####

variable "proxmox_host" {
  type        = string
  description = "The Proxmox host or IP address."
}

variable "proxmox_node" {
  type        = string
  description = "Which node in the Proxmox cluster to start the virtual machine on during creation."
}

variable "proxmox_password" {
  type        = string
  description = "Password for the user."
  sensitive   = true
  default     = null
}

variable "proxmox_token" {
  type        = string
  description = "The Proxmox API token."
  sensitive   = true
  default     = null
}

variable "proxmox_username" {
  type        = string
  description = "Username when authenticating to Proxmox, including the realm."
  sensitive   = true
}

##### Optional Variables #####

variable "proxmox_cloud_init_storage_pool" {
  type        = string
  description = "Name of the Proxmox storage pool to store the Cloud-Init CDROM on. If not given, the storage pool of the boot device will be used (disk_storage_pool)."
  default     = null
}

variable "proxmox_cores" {
  type        = number
  description = "How many CPU cores to give the virtual machine."
  default     = 1
}

variable "proxmox_disk_storage_pool" {
  type        = string
  description = "Storage pool for the boot disk and cloud-init image."
  default     = "local-lvm"

  validation {
    condition     = var.proxmox_disk_storage_pool != null
    error_message = "The disk storage pool must not be null."
  }
}

variable "proxmox_disk_size" {
  type        = string
  description = "The size of the OS disk, including a size suffix. The suffix must be 'K', 'M', or 'G'."
  default     = "4G"

  validation {
    condition     = can(regex("^\\d+[GMK]$", var.proxmox_disk_size))
    error_message = "The disk size is not valid. It must be a number with a size suffix (K, M, G)."
  }
}

variable "proxmox_disk_format" {
  type        = string
  description = "The format of the file backing the disk."
  default     = "raw"

  validation {
    condition     = contains(["raw", "cow", "qcow", "qed", "qcow2", "vmdk", "cloop"], var.proxmox_disk_format)
    error_message = "The storage pool type must be either 'raw', 'cow', 'qcow', 'qed', 'qcow2', 'vmdk', or 'cloop'."
  }
}

variable "proxmox_disk_type" {
  type        = string
  description = "The type of disk device to add."
  default     = "scsi"

  validation {
    condition     = contains(["ide", "sata", "scsi", "virtio"], var.proxmox_disk_type)
    error_message = "The storage pool type must be either 'ide', 'sata', 'scsi', or 'virtio'."
  }
}

variable "proxmox_iso_storage_pool" {
  type        = string
  description = "Proxmox storage pool onto which to find or upload the ISO file."
  default     = "local"
}

variable "proxmox_memory" {
  type        = number
  description = "How much memory, in megabytes, to give the virtual machine."
  default     = 1024
}

variable "proxmox_network_bridge" {
  type        = string
  description = "The Proxmox network bridge to use for the network interface."
  default     = "vmbr0"
}

variable "proxmox_port" {
  type        = number
  description = "The Proxmox port."
  default     = 8006
}

variable "proxmox_skip_verify_tls" {
  type        = bool
  description = "Skip validating the Proxmox certificate."
  default     = false
}

variable "proxmox_sockets" {
  type        = number
  description = "How many CPU sockets to give the virtual machine."
  default     = 1
}

variable "proxmox_template_name" {
  type        = string
  description = "The VM template name."
  default     = "packer-template"
}

variable "proxmox_template_description" {
  type        = string
  description = "Description of the VM template."
  default     = "Packer-generated template"
}

variable "proxmox_template_vm_id" {
  type        = number
  description = "The ID used to reference the virtual machine. This will also be the ID of the final template. If not given, the next free ID on the node will be used."
  default     = null
}

variable "proxmox_vm_interface" {
  type        = string
  description = "Name of the network interface that Packer gets the VMs IP from."
  default     = null
}
