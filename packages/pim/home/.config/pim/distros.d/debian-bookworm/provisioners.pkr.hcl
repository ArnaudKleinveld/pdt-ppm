# Debian Bookworm provisioners - cloud-init setup

provisioner "shell" {
  execute_command = "chmod +x {{ .Path }}; sudo env {{ .Vars }} {{ .Path }};"
  inline = [
    "apt-get update",
    "apt-get install -y cloud-init cloud-guest-utils",
    "echo 'datasource_list: [ NoCloud, ConfigDrive, None ]' > /etc/cloud/cloud.cfg.d/99_pve.cfg",
    "chmod 644 /etc/cloud/cloud.cfg.d/99_pve.cfg",
    "apt-get clean -y",
  ]
}
