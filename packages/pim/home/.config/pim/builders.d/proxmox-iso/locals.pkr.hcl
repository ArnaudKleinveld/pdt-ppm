# proxmox-iso builder locals

locals {
  # Timestamp for unique naming
  timestamp = regex_replace(timestamp(), "[- TZ:]", "")

  # Use local ISO file if provided
  proxmox_use_iso_file = var.distro_iso_file != null ? true : false

  # Useful when behind NAT or port forwarding scenarios
  http_url = join("", ["http://", coalesce(var.http_server_host, "{{ .HTTPIP }}"), ":", coalesce(var.http_server_port, "{{ .HTTPPort }}")])

  # Set the cloud init drive storage to the local disk storage if not provided
  proxmox_cloud_init_storage_pool = coalesce(var.proxmox_cloud_init_storage_pool, var.proxmox_disk_storage_pool)
}
