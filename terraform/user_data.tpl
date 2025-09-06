#!/bin/bash
set -euo pipefail
exec > /var/log/instance-userdata.log 2>&1

MODE="${mode}"                # server1 or server2
FILES_DIR="${files_dir}"
SERVER2_HOST="${server2_host:-}"

APP_DIR="/opt/fileapp"
SCRIPT_PATH="${APP_DIR}/ec2_file_servers.py"
SYSTEMD_DIR="/etc/systemd/system"

# install minimal packages
apt-get update -y
DEBIAN_FRONTEND=noninteractive apt-get install -y python3 python3-venv python3-pip git

# create dirs and set owner
mkdir -p "${APP_DIR}"
mkdir -p "${FILES_DIR}"
chown -R ubuntu:ubuntu "${APP_DIR}" "${FILES_DIR}" || true

# write the python script
cat > "${SCRIPT_PATH}" <<'PYCODE'
#!/usr/bin/env python3
# (Minimalized script: same as previously provided ec2_file_servers.py)
# The script content below must be the actual Python content.
# For brevity in this template I'll place the same functional script.
import argparse, os, socket, threading, hashlib, logging, sys, signal
from pathlib import Path

def getenv(name, default=None):
    return os.environ.get(name, default)

def safe_path_join(base_dir: str, requested_path: str) -> str:
    rp = requested_path.lstrip('/')
    if '..' in rp.split('/'):
        raise ValueError('Invalid pathname')
    candidate = os.path.normpath(os.path.join(base_dir, rp))
    base_dir_abs = os.path.abspath(base_dir)
    candidate_abs = os.path.abspath(candidate)
    if not candidate_abs.startswith(base_dir_abs + os.sep) and candidate_abs != base_dir_abs:
        raise ValueError('Path escapes base directory')
    return candidate_abs

def read_exact(sock_file, nbytes: int) -> bytes:
    remaining = nbytes
    chunks = []
    while remaining > 0:
        chunk = sock_file.read(remaining)
        if not chunk:
            break
        chunks.append(chunk)
        remaining -= len(chunk)
    return b''.join(chunks)

def run_server2(host: str, port: int, files_dir: str, timeout: int):
    os.makedirs(files_dir, exist_ok=True)
    logger = logging.getLogger('server2')
    logger.info('Starting SERVER2 on %s:%d serving %s', host, port, files_dir)
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.bind((host, port))
    s.listen(8)
    def handle_conn(conn, addr):
        logger.info('conn from %s', addr)
        conn.settimeout(timeout)
        f = conn.makefile('rb')
        try:
            line = f.readline().decode('utf-8', errors='ignore').strip()
            if not line:
                return
            if line.upper() == 'PING':
                conn.sendall(b'PONG\\n')
                return
            parts = line.split(None, 1)
            if len(parts) != 2 or parts[0].upper() != 'GET':
                conn.sendall(b'ERR BadRequest\\n')
                return
            pathname = parts[1]
            try:
                localpath = safe_path_join(files_dir, pathname)
            except ValueError:
                conn.sendall(b'ERR InvalidPath\\n')
                return
            if not os.path.isfile(localpath):
                conn.sendall(b'NOTFOUND\\n')
                return
            size = os.path.getsize(localpath)
            conn.sendall(f'OK {size}\\n'.encode('utf-8'))
            with open(localpath, 'rb') as fh:
                while True:
                    chunk = fh.read(8192)
                    if not chunk:
                        break
                    conn.sendall(chunk)
        except socket.timeout:
            logger.warning('connection timed out from %s', addr)
        except Exception as e:
            logger.exception('error handling conn: %s', e)
        finally:
            try:
                f.close()
            except:
                pass
            conn.close()
    try:
        while True:
            conn, addr = s.accept()
            threading.Thread(target=handle_conn, args=(conn, addr), daemon=True).start()
    except KeyboardInterrupt:
        logger.info('shutting down server2')
    finally:
        s.close()

def fetch_from_server2(host: str, port: int, pathname: str, timeout: int, logger):
    try:
        with socket.create_connection((host, port), timeout=timeout) as s:
            s_file = s.makefile('rb')
            s.sendall(f'GET {pathname}\\n'.encode('utf-8'))
            header = s_file.readline().decode('utf-8', errors='ignore').strip()
            if not header:
                logger.debug('empty header from server2')
                return False, None
            if header == 'NOTFOUND':
                return False, None
            if header.startswith('OK '):
                try:
                    size = int(header.split()[1])
                except:
                    logger.warning('bad OK header from server2: %s', header)
                    return False, None
                data = read_exact(s_file, size)
                if len(data) != size:
                    logger.warning('server2 returned %d bytes but header said %d', len(data), size)
                return True, data
            if header == 'PONG':
                return True, b'PONG'
            logger.warning('unknown header from server2: %s', header)
            return False, None
    except Exception as e:
        logger.warning('error contacting server2 %s:%d -> %s', host, port, e)
        return False, None

def run_server1(host: str, port: int, files_dir: str, server2_host: str, server2_port: int, timeout: int):
    os.makedirs(files_dir, exist_ok=True)
    logger = logging.getLogger('server1')
    logger.info('Starting SERVER1 on %s:%d serving %s and contacting SERVER2 at %s:%d', host, port, files_dir, server2_host, server2_port)
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.bind((host, port))
    s.listen(8)
    def handle_client(conn, addr):
        logger.info('client conn %s', addr)
        conn.settimeout(timeout + 2)
        f = conn.makefile('rb')
        try:
            line = f.readline().decode('utf-8', errors='ignore').strip()
            if not line:
                return
            if line.upper() == 'PING':
                conn.sendall(b'PONG\\n')
                return
            parts = line.split(None, 1)
            if len(parts) != 2 or parts[0].upper() != 'GET':
                conn.sendall(b'ERR BadRequest\\n')
                return
            pathname = parts[1]
            try:
                localpath = safe_path_join(files_dir, pathname)
            except ValueError:
                conn.sendall(b'ERR InvalidPath\\n')
                return
            found1 = os.path.isfile(localpath)
            data1 = None
            if found1:
                with open(localpath, 'rb') as fh:
                    data1 = fh.read()
            found2, data2 = fetch_from_server2(server2_host, server2_port, pathname, timeout, logger)
            if not found1 and not found2:
                conn.sendall(b'NOTFOUND\\n')
                return
            if found1 and not found2:
                conn.sendall(f'FOUND ONLY 1 {len(data1)}\\n'.encode('utf-8'))
                conn.sendall(data1)
                return
            if found2 and not found1:
                conn.sendall(f'FOUND ONLY 2 {len(data2)}\\n'.encode('utf-8'))
                conn.sendall(data2)
                return
            h1 = hashlib.sha256(data1).hexdigest()
            h2 = hashlib.sha256(data2).hexdigest()
            if h1 == h2 and len(data1) == len(data2):
                conn.sendall(f'FOUND MATCH {len(data1)}\\n'.encode('utf-8'))
                conn.sendall(data1)
            else:
                conn.sendall(f'FOUND DIFF {len(data1)} {len(data2)}\\n'.encode('utf-8'))
                conn.sendall(data1)
                conn.sendall(data2)
        except socket.timeout:
            logger.warning('client connection timed out %s', addr)
        except Exception as e:
            logger.exception('error handling client: %s', e)
        finally:
            try:
                f.close()
            except:
                pass
            conn.close()
    try:
        while True:
            conn, addr = s.accept()
            threading.Thread(target=handle_client, args=(conn, addr), daemon=True).start()
    except KeyboardInterrupt:
        logger.info('shutting down server1')
    finally:
        s.close()

def setup_logging(log_file: str = None):
    level = logging.INFO
    handlers = [logging.StreamHandler(sys.stdout)]
    if log_file:
        handlers.append(logging.FileHandler(log_file))
    logging.basicConfig(level=level, handlers=handlers, format='%(asctime)s %(levelname)s [%(name)s] %(message)s')

def parse_args():
    import argparse
    p = argparse.ArgumentParser(description='Simple EC2 file server cluster (server1/server2)')
    p.add_argument('--mode', choices=['server1', 'server2'], required=True)
    p.add_argument('--host', default=os.environ.get('HOST','0.0.0.0'))
    p.add_argument('--port', type=int, default=None)
    p.add_argument('--files-dir', default=os.environ.get('FILES_DIR', '/var/lib/server_files'))
    p.add_argument('--server2-host', default=os.environ.get('SERVER2_HOST', None))
    p.add_argument('--server2-port', type=int, default=int(os.environ.get('SERVER2_PORT','9002')))
    p.add_argument('--log-file', default=os.environ.get('LOG_FILE', None))
    p.add_argument('--timeout', type=int, default=int(os.environ.get('TIMEOUT_SEC','5')))
    return p.parse_args()

def main():
    args = parse_args()
    if args.mode == 'server1':
        default_port = 9001
    else:
        default_port = 9002
    host = args.host
    port = args.port if args.port is not None else default_port
    files_dir = args.files_dir
    setup_logging(args.log_file)
    logger = logging.getLogger('main')
    import signal, threading
    stop_event = threading.Event()
    def _signal_handler(signum, frame):
        logger.info('received signal %s, shutting down', signum)
        stop_event.set()
        sys.exit(0)
    signal.signal(signal.SIGTERM, _signal_handler)
    signal.signal(signal.SIGINT, _signal_handler)
    if args.mode == 'server2':
        run_server2(host, port, files_dir, args.timeout)
    else:
        server2_host = args.server2_host
        if not server2_host:
            logger.error('server2 host must be provided via --server2-host or SERVER2_HOST env var')
            sys.exit(2)
        run_server1(host, port, files_dir, server2_host, args.server2_port, args.timeout)

if __name__ == '__main__':
    main()
PYCODE

chmod +x "${SCRIPT_PATH}" || true
chown ubuntu:ubuntu "${SCRIPT_PATH}" || true

# create simple systemd unit
if [ "${MODE}" = "server2" ]; then
  cat > /etc/systemd/system/server2.service <<'SVC2'
[Unit]
Description=File Replica Server (SERVER2)
After=network.target
Wants=network-online.target

[Service]
Type=simple
User=ubuntu
WorkingDirectory=/opt/fileapp
ExecStart=/usr/bin/python3 /opt/fileapp/ec2_file_servers.py --mode server2 --files-dir ${FILES_DIR}
Restart=on-failure
RestartSec=5
Environment=FILES_DIR=${FILES_DIR}

# Basic sandboxing
NoNewPrivileges=yes
ProtectSystem=full
ProtectHome=yes
PrivateTmp=yes
ReadWritePaths=${FILES_DIR} /opt/fileapp
RemoveIPC=yes

[Install]
WantedBy=multi-user.target
SVC2

else
  cat > /etc/systemd/system/server1.service <<'SVC1'
[Unit]
Description=Mediator File Server (SERVER1)
After=network.target
Wants=network-online.target

[Service]
Type=simple
User=ubuntu
WorkingDirectory=/opt/fileapp
ExecStart=/usr/bin/python3 /opt/fileapp/ec2_file_servers.py --mode server1 --files-dir ${FILES_DIR} --server2-host ${SERVER2_HOST}
Restart=on-failure
RestartSec=5
Environment=FILES_DIR=${FILES_DIR}
Environment=SERVER2_HOST=${SERVER2_HOST}

NoNewPrivileges=yes
ProtectSystem=full
ProtectHome=yes
PrivateTmp=yes
ReadWritePaths=${FILES_DIR} /opt/fileapp
RemoveIPC=yes

[Install]
WantedBy=multi-user.target
SVC1
fi

# enable and start
systemctl daemon-reload
if [ "${MODE}" = "server2" ]; then
  systemctl enable --now server2
else
  systemctl enable --now server1
fi

# drop a quick README into files_dir
cat > "${FILES_DIR}/README.txt" <<EOF
This directory is served by the ec2_file_servers.py service (mode=${MODE}).
Place files here to test:
 - on server1: ${FILES_DIR}
EOF

echo "userdata finished"