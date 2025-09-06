variable "aws_region" {
  type    = string
  default = "ap-south-1"
}

variable "vpc_id" {
  description = "Existing VPC id to launch instances into"
  type        = string
}

variable "subnet_id" {
  description = "Existing subnet id (must be a public subnet to get public IPs via associate_public_ip_address)"
  type        = string
}

variable "security_group_id" {
  description = "Existing security group id (e.g., default SG of the VPC)"
  type        = string
}

variable "key_name" {
  description = "Existing EC2 key pair name for SSH access"
  type        = string
}

variable "server1_private_ip" {
  description = "Optional: static private IP for server1 (optional)"
  type        = string
  default     = ""
}

variable "server2_private_ip" {
  description = "Optional: static private IP for server2 (optional)"
  type        = string
  default     = ""
}

variable "instance_type" {
  description = "EC2 instance type"
  type        = string
  default     = "t2.micro"
}

variable "files_dir_server1" {
  type    = string
  default = "/var/lib/server1_files"
}

variable "files_dir_server2" {
  type    = string
  default = "/var/lib/server2_files"
}