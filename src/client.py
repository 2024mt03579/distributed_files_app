#!/usr/bin/env python3
"""
client_request.py

Usage:
  python3 client_request.py SERVER1_HOST /path/to/file
  python3 client_request.py 1.2.3.4 /foo.txt

The client connects to SERVER1 on port 9001 by default and sends:
  GET /path/to/file\n

It supports server responses:
  NOTFOUND\n
  FOUND MATCH <size>\n<bytes>
  FOUND ONLY 1 <size>\n<bytes>
  FOUND ONLY 2 <size>\n<bytes>
  FOUND DIFF <size1> <size2>\n<bytes1><bytes2>

Files are written into ./client_out/
"""
import socket
import sys
import os

SERVER_PORT = 9001
TIMEOUT = 8.0
OUT_DIR = "client_out"
BUF = 8192

def read_exact(sock_file, n):
    """Read exactly n bytes from a buffered file-like object (may return fewer on EOF)."""
    remaining = n
    chunks = []
    while remaining > 0:
        chunk = sock_file.read(min(BUF, remaining))
        if not chunk:
            break
        chunks.append(chunk)
        remaining -= len(chunk)
    return b"".join(chunks)

def request_file(server_host, pathname):
    addr = (server_host, SERVER_PORT)
    print(f"Connecting to {addr} (timeout {TIMEOUT}s) ...")
    try:
        with socket.create_connection(addr, timeout=TIMEOUT) as s:
            s_file = s.makefile('rb')
            # send request
            req = f"GET {pathname}\n".encode('utf-8')
            s.sendall(req)

            header = s_file.readline().decode('utf-8', errors='ignore').strip()
            if not header:
                print("No response (empty header).")
                return

            print("Server response header:", header)

            if header == "NOTFOUND":
                print("File not found on both servers - Server_1 and Server_2")
                return

            if header.startswith("FOUND MATCH "):
                parts = header.split()
                size = int(parts[2])
                data = read_exact(s_file, size)
                os.makedirs(OUT_DIR, exist_ok=True)
                outpath = os.path.join(OUT_DIR, os.path.basename(pathname))
                with open(outpath, 'wb') as fh:
                    fh.write(data)
                print(f"File is matching on both the servers and output saved to {outpath} ({len(data)} bytes)")
                return

            if header.startswith("FOUND ONLY "):
                # FOUND ONLY <which> <size>
                parts = header.split()
                which = parts[2]
                size = int(parts[3])
                data = read_exact(s_file, size)
                os.makedirs(OUT_DIR, exist_ok=True)
                outpath = os.path.join(OUT_DIR, f"{os.path.basename(pathname)}_only_server_{which}")
                with open(outpath, 'wb') as fh:
                    fh.write(data)
                print(f"File is available (only on Server {which}) to {outpath} ({len(data)} bytes)")
                return

            if header.startswith("FOUND DIFF "):
                # FOUND DIFF <size1> <size2>
                parts = header.split()
                size1 = int(parts[2])
                size2 = int(parts[3])
                data1 = read_exact(s_file, size1)
                data2 = read_exact(s_file, size2)
                os.makedirs(OUT_DIR, exist_ok=True)
                out1 = os.path.join(OUT_DIR, f"{os.path.basename(pathname)}_server1")
                out2 = os.path.join(OUT_DIR, f"{os.path.basename(pathname)}_server2")
                with open(out1, 'wb') as fh:
                    fh.write(data1)
                with open(out2, 'wb') as fh:
                    fh.write(data2)
                print(f"Found difference in files: {out1} ({len(data1)} bytes), {out2} ({len(data2)} bytes)")
                return

            print("Unknown header from server:", header)

    except (socket.timeout, ConnectionRefusedError) as e:
        print("Connection error:", e)
    except Exception as e:
        print("Error:", e)

def ping(server_host):
    """Optional: ping SERVER1 to check reachability"""
    addr = (server_host, SERVER_PORT)
    try:
        with socket.create_connection(addr, timeout=TIMEOUT) as s:
            s_file = s.makefile('rb')
            s.sendall(b"PING\n")
            resp = s_file.readline().decode('utf-8', errors='ignore').strip()
            print("PING response:", resp)
    except Exception as e:
        print("Ping failed:", e)

if __name__ == "__main__":
    if len(sys.argv) < 3:
        print("Usage: python3 client_request.py SERVER1_HOST /path/to/file")
        print("Or: python3 client_request.py ping SERVER1_HOST")
        sys.exit(1)

    if sys.argv[1].lower() == "ping":
        ping(sys.argv[2])
        sys.exit(0)

    server = sys.argv[1]
    path = sys.argv[2]
    request_file(server, path)
