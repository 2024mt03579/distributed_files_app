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

# --- generate cluster keypair locally ---
resource "random_id" "kp" {
  byte_length = 4
}

resource "tls_private_key" "cluster" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

# write private key locally (temporary path under .terraform/tmp)
resource "local_file" "cluster_private" {
  content         = tls_private_key.cluster.private_key_pem
  filename        = "${path.module}/.terraform/tmp/cluster_id_rsa_${random_id.kp.hex}"
  file_permission = "0600"
}

resource "local_file" "cluster_public" {
  content         = tls_private_key.cluster.public_key_openssh
  filename        = "${path.module}/.terraform/tmp/cluster_id_rsa_${random_id.kp.hex}.pub"
  file_permission = "0644"
}


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
    user_name    = "ubuntu"
    server2_port = 9002
    timeout     = 5
    script_file = file("${path.module}/../src/ec2_file_servers.py")
  })

  # connection - provisioners will SSH using your console key
  connection {
    type        = "ssh"
    user        = "ubuntu"
    host        = self.public_ip
    private_key = file(var.ssh_private_key_path)
    timeout     = "2m"
  }

  # upload generated cluster private key
  provisioner "file" {
    source      = local_file.cluster_private.filename
    destination = "/home/ubuntu/cluster_id_rsa"
    when        = create
  }

  # upload generated cluster public key
  provisioner "file" {
    source      = local_file.cluster_public.filename
    destination = "/home/ubuntu/cluster_id_rsa.pub"
    when        = create
  }

  # secure keys, install authorized_keys
  provisioner "remote-exec" {
    when       = create
    inline = [
      "set -xe",
      "mkdir -p /home/ubuntu/.ssh",
      "mv /home/ubuntu/cluster_id_rsa /home/ubuntu/.ssh/id_rsa",
      "mv /home/ubuntu/cluster_id_rsa.pub /home/ubuntu/.ssh/id_rsa.pub",
      "chmod 600 /home/ubuntu/.ssh/id_rsa",
      "chmod 644 /home/ubuntu/.ssh/id_rsa.pub",
      "touch /home/ubuntu/.ssh/authorized_keys",
      "grep -qxF \"$(cat /home/ubuntu/.ssh/id_rsa.pub)\" /home/ubuntu/.ssh/authorized_keys || cat /home/ubuntu/.ssh/id_rsa.pub >> /home/ubuntu/.ssh/authorized_keys",
      "chmod 600 /home/ubuntu/.ssh/authorized_keys",
      "chown -R ubuntu:ubuntu /home/ubuntu/.ssh",
      "cat > /home/ubuntu/.ssh/config <<'SSHCFG'",
      "Host *",
      "  StrictHostKeyChecking no",
      "  UserKnownHostsFile /dev/null",
      "  LogLevel ERROR",
      "SSHCFG",
      "chmod 600 /home/ubuntu/.ssh/config",
      "chown ubuntu:ubuntu /home/ubuntu/.ssh/config"
    ]
  }
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
    app_dir      = "/opt/fileapp"
    script_path  = "/opt/fileapp/ec2_file_servers.py"
    user_name    = "ubuntu"
    server2_port = 9002
    timeout     = 5
    script_file = file("${path.module}/../src/ec2_file_servers.py")
  })

  # connection - provisioners will SSH using your console key
  connection {
    type        = "ssh"
    user        = "ubuntu"
    host        = self.public_ip
    private_key = file(var.ssh_private_key_path)
    timeout     = "2m"
  }

  # upload generated cluster private key
  provisioner "file" {
    source      = local_file.cluster_private.filename
    destination = "/home/ubuntu/cluster_id_rsa"
    when        = create
  }

  # upload generated cluster public key
  provisioner "file" {
    source      = local_file.cluster_public.filename
    destination = "/home/ubuntu/cluster_id_rsa.pub"
    when        = create
  }

  # secure keys, install authorized_keys
  provisioner "remote-exec" {
    when       = create
    inline = [
      "set -xe",
      "mkdir -p /home/ubuntu/.ssh",
      "mv /home/ubuntu/cluster_id_rsa /home/ubuntu/.ssh/id_rsa",
      "mv /home/ubuntu/cluster_id_rsa.pub /home/ubuntu/.ssh/id_rsa.pub",
      "chmod 600 /home/ubuntu/.ssh/id_rsa",
      "chmod 644 /home/ubuntu/.ssh/id_rsa.pub",
      "touch /home/ubuntu/.ssh/authorized_keys",
      "grep -qxF \"$(cat /home/ubuntu/.ssh/id_rsa.pub)\" /home/ubuntu/.ssh/authorized_keys || cat /home/ubuntu/.ssh/id_rsa.pub >> /home/ubuntu/.ssh/authorized_keys",
      "chmod 600 /home/ubuntu/.ssh/authorized_keys",
      "chown -R ubuntu:ubuntu /home/ubuntu/.ssh",
      "cat > /home/ubuntu/.ssh/config <<'SSHCFG'",
      "Host *",
      "  StrictHostKeyChecking no",
      "  UserKnownHostsFile /dev/null",
      "  LogLevel ERROR",
      "SSHCFG",
      "chmod 600 /home/ubuntu/.ssh/config",
      "chown ubuntu:ubuntu /home/ubuntu/.ssh/config"
    ]
  }

  # ensure server1 user_data uses server2 private IP (dependency)
  depends_on = [aws_instance.server2]
}

# Place after aws_instance.server1 and aws_instance.server2 resources

resource "null_resource" "install_rsync_cron_on_server2" {
  depends_on = [
    aws_instance.server1,
    aws_instance.server2,
  ]

  # Use triggers to force rerun if server1/server2 IPs change
  triggers = {
    server1_private_ip = aws_instance.server1.private_ip
    server2_public_ip  = aws_instance.server2.public_ip
  }

  connection {
    type        = "ssh"
    user        = "ubuntu"
    host        = aws_instance.server2.public_ip
    private_key = file(var.ssh_private_key_path)
    timeout     = "2m"
  }

  provisioner "remote-exec" {
    # run once at create (null_resource runs on create/destroy depending on triggers)
    inline = [
      "set -xe",
      # ensure rsync/ssh are available
      "DEBIAN_FRONTEND=noninteractive apt-get update -y || true",
      "DEBIAN_FRONTEND=noninteractive apt-get install -y rsync openssh-client || true",
      # ensure directories exist
      "mkdir -p /var/lib/server2_files /var/lib/server1_files || true",
      "chown -R ubuntu:ubuntu /var/lib/server2_files /var/lib/server1_files || true",
      # write the crontab line (use server1 private ip from Terraform interpolation)
      "crontab -l -u ubuntu 2>/dev/null || true",
      "echo '*/2 * * * * /usr/bin/rsync -az --delete -e \"ssh -i /home/ubuntu/.ssh/cluster_id_rsa -o StrictHostKeyChecking=no\" ubuntu@${aws_instance.server1.private_ip}:/var/lib/server1_files/ /var/lib/server2_files/' | crontab -u ubuntu -",
    ]
  }
}
