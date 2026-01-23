# Debian Bookworm distro variables

# Distro ISO variables
variable "distro_iso_checksum" {
  type        = string
  description = "Checksum of the ISO file."
}

variable "distro_iso_file" {
  type        = string
  description = "Filename of the ISO file to boot from."
}

variable "distro_iso_url" {
  type        = string
  description = "URL to an ISO file to upload to Proxmox, and then boot from."
}

# Preseed variables
variable "debian_preseed_country" {
  type        = string
  description = "Set the country"
  default     = "US"
}

variable "debian_preseed_file" {
  type        = string
  description = "The name of the preseed file"
  default     = "debian-preseed.cfg"
}

variable "debian_preseed_keyboard_keymap" {
  type        = string
  description = "Set the keyboard VConsole keymap"
  default     = "us"
}

variable "debian_preseed_language" {
  type        = string
  description = "Set the language"
  default     = "en"
}

variable "debian_preseed_locale" {
  type        = string
  description = "Set the system locale"
  default     = "en_US.UTF-8"
}

variable "debian_preseed_mirror_http_hostname" {
  type        = string
  description = "Set the debian package repository mirror"
  default     = "deb.debian.org"
}

variable "debian_preseed_pkgsel_include" {
  type        = list(string)
  description = "Set the list of packages to install"
  default     = []
}

variable "debian_preseed_timezone" {
  type        = string
  description = "Set the timezone"
  default     = "UTC"
}

# HTTP server variables for packer
variable "http_server_host" {
  type        = string
  description = "Overrides packers {{ .HTTPIP }} setting in the boot commands. Useful when running packer in WSL2."
  default     = null
}

variable "http_server_port" {
  type        = number
  description = "The port to serve the http_directory on. Overrides packers {{ .HTTPPort }} setting in the boot commands."
  default     = null
}

variable "http_bind_address" {
  type        = string
  description = "This is the bind address for the HTTP server. Defaults to 0.0.0.0 so that it will work with any network interface."
  default     = null
}

variable "http_interface" {
  type        = string
  description = "Name of the network interface that Packer gets HTTPIP from."
  default     = null
}

# SSH variables
variable "ssh_agent_auth" {
  type        = bool
  description = "Whether to use an existing ssh-agent to pass in the SSH private key passphrase."
  default     = false
}

variable "ssh_password" {
  type        = string
  description = "A plaintext password to use to authenticate with SSH."
  default     = null
}

variable "ssh_private_key_file" {
  type        = string
  description = "Path to private key file for SSH authentication."
  default     = null
}

variable "ssh_public_key" {
  type        = string
  description = "Public key data for SSH authentication. If set, password authentication will be disabled."
  default     = null
}

variable "ssh_username" {
  type        = string
  description = "The username to connect to SSH with."
  default     = null
}

variable "ssh_encrypted_password" {
  type        = string
  description = "The encrypted password for the user (for preseed)."
  default     = null
}
