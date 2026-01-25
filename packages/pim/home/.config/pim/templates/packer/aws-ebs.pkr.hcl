# Packer Amazon EBS Builder Template
# Used for building AMIs from source AMI or importing from qcow2

packer {
  required_plugins {
    amazon = {
      version = ">= 1.0.0"
      source  = "github.com/hashicorp/amazon"
    }
  }
}

variable "ami_name" { type = string }
variable "source_ami" { type = string }
variable "region" { type = string }
variable "instance_type" { 
  type = string 
  default = "t3.micro"
}

variable "ssh_username" { type = string }
variable "ssh_timeout" { 
  type = string 
  default = "10m"
}

variable "volume_size" { 
  type = number 
  default = 20
}
variable "volume_type" { 
  type = string 
  default = "gp3"
}

variable "tags" {
  type = map(string)
  default = {}
}

variable "ami_description" {
  type = string
  default = "Built by pim packer"
}

source "amazon-ebs" "main" {
  ami_name        = var.ami_name
  ami_description = var.ami_description
  instance_type   = var.instance_type
  region          = var.region
  source_ami      = var.source_ami
  ssh_username    = var.ssh_username
  ssh_timeout     = var.ssh_timeout

  launch_block_device_mappings {
    device_name           = "/dev/xvda"
    volume_size           = var.volume_size
    volume_type           = var.volume_type
    delete_on_termination = true
  }

  tags = merge(var.tags, {
    Name       = var.ami_name
    Built_By   = "pim-packer"
    Build_Date = timestamp()
  })

  run_tags = {
    Name = "packer-builder-${var.ami_name}"
  }
}

build {
  sources = ["source.amazon-ebs.main"]

  provisioner "shell" {
    inline = [
      "sudo apt-get update",
      "sudo apt-get upgrade -y"
    ]
  }
}
