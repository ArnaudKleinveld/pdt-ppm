# Debian Bookworm distro locals

locals {
  # Boot command for Debian preseed installation
  distro_boot_command = [
    "<esc><wait>",
    "auto preseed/url=${join("", ["http://", coalesce(var.http_server_host, "{{ .HTTPIP }}"), ":", coalesce(var.http_server_port, "{{ .HTTPPort }}")])}/${var.debian_preseed_file}<wait>",
    "<enter>"
  ]
  distro_boot_wait = "6s"
}
