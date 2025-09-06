#!/usr/bin/env python3

import os, socket, threading, hashlib, sys

def safe_path_join(base_dir, requested_path):
    rp = requested_path.lstrip('/')
    if '..' in rp.split('/'):
        raise ValueError('Invalid pathname')
    candidate = os.path.normpath(os.path.join(base_dir, rp))
    base = os.path.abspath(base_dir)
    cand = os.path.abspath(candidate)
    if not cand.startswith(base + os.sep) and cand != base:
        raise ValueError('Path escapes base')
    return cand

def read_exact(f, n):
    rem=n; chunks=[]
    while rem>0:
        c=f.read(rem)
        if not c: break
        chunks.append(c); rem-=len(c)
    return b''.join(chunks)

def run_server2(host,port,files_dir,timeout):
    os.makedirs(files_dir, exist_ok=True)
    s=socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.bind((host,port)); s.listen(8)
    def handle(conn,addr):
        conn.settimeout(timeout); f=conn.makefile('rb')
        try:
            line=f.readline().decode().strip()
            if not line: return
            if line.upper()=='PING':
                conn.sendall(b'PONG\n'); return
            parts=line.split(None,1)
            if len(parts)!=2 or parts[0].upper()!='GET':
                conn.sendall(b'ERR BadRequest\n'); return
            try:
                lp=safe_path_join(files_dir, parts[1])
            except:
                conn.sendall(b'ERR InvalidPath\n'); return
            if not os.path.isfile(lp):
                conn.sendall(b'NOTFOUND\n'); return
            size=os.path.getsize(lp); conn.sendall(f'OK {size}\n'.encode())
            with open(lp,'rb') as fh:
                while True:
                    ch=fh.read(8192)
                    if not ch: break
                    conn.sendall(ch)
        except:
            pass
        finally:
            try: f.close()
            except: pass
            conn.close()
    try:
        while True:
            conn,addr=s.accept()
            threading.Thread(target=handle,args=(conn,addr),daemon=True).start()
    finally:
        s.close()

def fetch_from_server2(host,port,path,timeout):
    try:
        with socket.create_connection((host,port),timeout=timeout) as s:
            sf=s.makefile('rb'); s.sendall(f'GET {path}\n'.encode())
            hdr=sf.readline().decode().strip()
            if not hdr: return False,None
            if hdr=='NOTFOUND': return False,None
            if hdr.startswith('OK '):
                size=int(hdr.split()[1]); data=read_exact(sf,size); return True,data
            return False,None
    except:
        return False,None

def run_server1(host,port,files_dir,server2_host,server2_port,timeout):
    os.makedirs(files_dir, exist_ok=True)
    s=socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.bind((host,port)); s.listen(8)
    def handle(conn,addr):
        conn.settimeout(timeout+2); f=conn.makefile('rb')
        try:
            line=f.readline().decode().strip()
            if not line: return
            if line.upper()=='PING':
                conn.sendall(b'PONG\n'); return
            parts=line.split(None,1)
            if len(parts)!=2 or parts[0].upper()!='GET':
                conn.sendall(b'ERR BadRequest\n'); return
            path=parts[1]
            try:
                lp=safe_path_join(files_dir,path)
            except:
                conn.sendall(b'ERR InvalidPath\n'); return
            found1=os.path.isfile(lp); data1=None
            if found1:
                with open(lp,'rb') as fh: data1=fh.read()
            found2,data2=fetch_from_server2(server2_host,server2_port,path,timeout)
            if not found1 and not found2:
                conn.sendall(b'NOTFOUND\n'); return
            if found1 and not found2:
                conn.sendall(f'FOUND ONLY 1 {len(data1)}\n'.encode()); conn.sendall(data1); return
            if found2 and not found1:
                conn.sendall(f'FOUND ONLY 2 {len(data2)}\n'.encode()); conn.sendall(data2); return
            h1=hashlib.sha256(data1).hexdigest(); h2=hashlib.sha256(data2).hexdigest()
            if h1==h2 and len(data1)==len(data2):
                conn.sendall(f'FOUND MATCH {len(data1)}\n'.encode()); conn.sendall(data1)
            else:
                conn.sendall(f'FOUND DIFF {len(data1)} {len(data2)}\n'.encode()); conn.sendall(data1); conn.sendall(data2)
        except:
            pass
        finally:
            try: f.close()
            except: pass
            conn.close()
    try:
        while True:
            conn,addr=s.accept()
            threading.Thread(target=handle,args=(conn,addr),daemon=True).start()
    finally:
        s.close()

def main():
    import argparse
    p=argparse.ArgumentParser()
    p.add_argument('--mode',choices=['server1','server2'],required=True)
    p.add_argument('--host',default='0.0.0.0')
    p.add_argument('--port',type=int,default=None)
    p.add_argument('--files-dir',default='/var/lib/server_files')
    p.add_argument('--server2-host',default=None)
    p.add_argument('--server2-port',type=int,default=9002)
    p.add_argument('--timeout',type=int,default=5)
    args=p.parse_args()
    if args.mode=='server1': default_port=9001
    else: default_port=9002
    host=args.host; port=args.port if args.port else default_port
    if args.mode=='server2':
        run_server2(host,port,args.files_dir,args.timeout)
    else:
        if not args.server2_host:
            print('server2 host required',file=sys.stderr); sys.exit(2)
        run_server1(host,port,args.files_dir,args.server2_host,args.server2_port,args.timeout)

if __name__=='__main__': main()