#!/bin/bash
set -euo pipefail
exec > /var/log/instance-userdata.log 2>&1

# Terraform substitutes these exact lowercase tokens:
mode="${mode}"
files_dir="${files_dir}"
server2_host="${server2_host}"
app_dir="${app_dir}"
script_path="${script_path}"
user_name="${user_name}"
server2_port="${server2_port}"
timeout="${timeout}"

# Install minimal runtime (Ubuntu)
apt-get update -y
DEBIAN_FRONTEND=noninteractive apt-get install -y python3

# Create app and files dirs and set ownership
mkdir -p "${app_dir}"
mkdir -p "${files_dir}"
chown -R "${user_name}:${user_name}" "${app_dir}" "${files_dir}" || true
chmod 755 "${app_dir}" "${files_dir}" || true

# Redirecting the repo/src/ec2_file_servers.py to the ec2 /tmp/ec2_file_servers.py
cat > /tmp/ec2_file_servers.py <<'PYCODE'
${script_file}
PYCODE

# Copy script from the Terraform provisioned file
cp /tmp/ec2_file_servers.py "${script_path}"
chmod +x "${script_path}"
chown "${user_name}:${user_name}" "${script_path}"

# Make script executable (cloud-init runs as root; ownership updated later)
chmod +x "${script_path}" || true

# Create systemd unit using lowercase variables
if [ "${mode}" = "server2" ]; then
  cat > /etc/systemd/system/server2.service <<'SVC'
[Unit]
Description=File Replica Server (SERVER2)
After=network.target
Wants=network-online.target

[Service]
Type=simple
User=${user_name}
WorkingDirectory=${app_dir}
ExecStart=/usr/bin/python3 ${script_path} --mode server2 --files-dir ${files_dir} --timeout ${timeout}
Restart=on-failure
RestartSec=5
Environment=FILES_DIR=${files_dir}

NoNewPrivileges=yes
ProtectSystem=full
ProtectHome=yes
PrivateTmp=yes
ReadWritePaths=${files_dir} ${app_dir}
RemoveIPC=yes

[Install]
WantedBy=multi-user.target
SVC
else
  cat > /etc/systemd/system/server1.service <<'SVC'
[Unit]
Description=Mediator File Server (SERVER1)
After=network.target
Wants=network-online-target

[Service]
Type=simple
User=${user_name}
WorkingDirectory=${app_dir}
ExecStart=/usr/bin/python3 ${script_path} --mode server1 --files-dir ${files_dir} --server2-host ${server2_host} --server2-port ${server2_port} --timeout ${timeout}
Restart=on-failure
RestartSec=5
Environment=FILES_DIR=${files_dir}
Environment=SERVER2_HOST=${server2_host}

NoNewPrivileges=yes
ProtectSystem=full
ProtectHome=yes
PrivateTmp=yes
ReadWritePaths=${files_dir} ${app_dir}
RemoveIPC=yes

[Install]
WantedBy=multi-user.target
SVC
fi

# Reload and start the appropriate service
systemctl daemon-reload
if [ "${mode}" = "server2" ]; then
  systemctl enable --now server2
else
  systemctl enable --now server1
fi

cat > "${files_dir}/README.txt" <<EOF
This directory is served by the ec2_file_servers.py service (mode=${mode}).
Place files here to test.
EOF

echo "userdata complete"