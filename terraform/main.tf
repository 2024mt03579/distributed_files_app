# Use Canonical's SSM public parameter for Ubuntu 24.04 (Noble).
# This ensures the AMI is the current canonical image for the region.
# Parameter path used: /aws/service/canonical/ubuntu/server/24.04/stable/current/amd64/hvm/ebs-gp3/ami-id
data "aws_ssm_parameter" "ubuntu_2404_amd64" {
  name = "/aws/service/canonical/ubuntu/server/24.04/stable/current/amd64/hvm/ebs-gp3/ami-id"
}

# Optional DNS name for instances (tagging)
locals {
  server1_name = "server1-file-mediator"
  server2_name = "server2-file-replica"
  sg_ids = [var.security_group_id]
}

# We cannot pass dynamic vars into the above single template resource easily per-instance,
# so instead we'll build user_data inline for each instance using the templatefile() function.

# Server2 (replica)
resource "aws_instance" "server2" {
  ami                    = data.aws_ssm_parameter.ubuntu_2404_amd64.value
  instance_type          = var.instance_type
  subnet_id              = var.subnet_id
  vpc_security_group_ids = local.sg_ids
  key_name               = var.key_name
  associate_public_ip_address = true

  private_ip = var.server2_private_ip != "" ? var.server2_private_ip : null

  tags = {
    Name = local.server2_name
  }

  user_data = templatefile("${path.module}/user_data.tpl", {
    mode        = "server2"
    files_dir   = var.files_dir_server2
    server2_host = ""      # not used for server2
    app_dir      = "/opt/fileapp"
    script_path  = "/opt/fileapp/ec2_file_servers.py"
  })
}

# Server1 (mediator)
resource "aws_instance" "server1" {
  ami                    = data.aws_ssm_parameter.ubuntu_2404_amd64.value
  instance_type          = var.instance_type
  subnet_id              = var.subnet_id
  vpc_security_group_ids = local.sg_ids
  key_name               = var.key_name
  associate_public_ip_address = true

  private_ip = var.server1_private_ip != "" ? var.server1_private_ip : null

  tags = {
    Name = local.server1_name
  }

  # Server1 needs to know Server2 private IP to contact it. We prefer private IP
  # (for in-VPC traffic) — if server2.private_ip is not available until apply, we use interpolation.
  user_data = templatefile("${path.module}/user_data.tpl", {
    mode        = "server1"
    files_dir   = var.files_dir_server1
    server2_host = aws_instance.server2.private_ip
  })

  # ensure server1 user_data uses server2 private IP (dependency)
  depends_on = [aws_instance.server2]
}
