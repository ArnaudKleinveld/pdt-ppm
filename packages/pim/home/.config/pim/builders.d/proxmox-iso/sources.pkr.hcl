# proxmox-iso builder source

source "proxmox-iso" "generic" {
  proxmox_url              = "https://${var.proxmox_host}:${var.proxmox_port}/api2/json"
  node                     = var.proxmox_node
  username                 = var.proxmox_username
  password                 = var.proxmox_password
  token                    = var.proxmox_token
  insecure_skip_tls_verify = var.proxmox_skip_verify_tls

  template_name            = var.proxmox_template_name
  template_description     = var.proxmox_template_description
  vm_id                    = var.proxmox_template_vm_id

  boot_iso {
    type         = "scsi"
    iso_file     = local.proxmox_use_iso_file ? "${var.proxmox_iso_storage_pool}:iso/${var.distro_iso_file}" : null
    unmount      = true
    iso_checksum = var.distro_iso_checksum
  }

  os         = "l26"
  qemu_agent = true
  memory     = var.proxmox_memory
  cores      = var.proxmox_cores
  sockets    = var.proxmox_sockets

  scsi_controller = "virtio-scsi-pci"

  network_adapters {
    model  = "virtio"
    bridge = var.proxmox_network_bridge
  }

  disks {
    disk_size    = var.proxmox_disk_size
    storage_pool = var.proxmox_disk_storage_pool
    format       = var.proxmox_disk_format
    type         = var.proxmox_disk_type
  }

  http_directory    = "./http"
  http_bind_address = var.http_bind_address
  http_interface    = var.http_interface
  http_port_min     = var.http_server_port
  http_port_max     = var.http_server_port
  vm_interface      = var.proxmox_vm_interface

  boot         = null
  boot_command = local.distro_boot_command
  boot_wait    = local.distro_boot_wait

  ssh_handshake_attempts    = 100
  ssh_username              = var.ssh_username
  ssh_password              = var.ssh_password
  ssh_private_key_file      = var.ssh_private_key_file
  ssh_clear_authorized_keys = true
  ssh_timeout               = "45m"
  ssh_agent_auth            = var.ssh_agent_auth

  cloud_init              = true
  cloud_init_storage_pool = local.proxmox_cloud_init_storage_pool
}
