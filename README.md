
#  Distributed File Service Assignment


- **Group:** 20
- **Subject Code:** Distributed Computing (CCZG 526)

**Team**

- Deviprasad Tummidi (2024mt035079@wilp.bits-pilani.ac.in)
- Arpit Malik (2024mt03616@wilp.bits-pilani.ac.in)
- Pravin Piske (2024mt03608@wilp.bits-pilani.ac.in)
- Duraiarasan (2024mt03574@wilp.bits-pilani.ac.in)
- Nakella Murali Krishna (2023mt03624@wilp.bits-pilani.ac.in)


**Problem Statement**

```
Implement a simple distributed system with one client (CLIENT) and two servers (SERVER1 and SERVER 2). Two servers SERVER1 and SERVER 2 are used as file servers and contains same set of files (one is replica of another).  Note that there may be delay in updating the servers. 
The above distributed system must perform the following:
- CLIENT sends a file request with a “pathname” to SERVER 1. 
- SERVER 1 checks its own file system for the file and sends the same file request to SERVER 2. 
- SERVER 2 returns the file if available. 
- SERVER 1 then compares the contents of file it found in its directory and the file that is received from SERVER 2.
- If there is no difference between the file contents, SERVER1 sends the file to client.
- If there is a difference between the file contents, SERVER1 sends both the files to client.
- If file is available on one of the servers, then the file is returned to client via SERVER 1.
- If the file is not available, SERVER 1 should send appropriate message to CLIENT.

```

---

# Solution

### 1️⃣ Prerequisites

Ensure you have the following tools installed and configured in your client desktop or machine.

- [AWS CLI v2](https://docs.aws.amazon.com/cli/latest/userguide/install-cliv2.html)
- Valid AWS credentials configured using `aws configure`
- Python Version : `< 3.10`
- Terraform : `< 1.12`
- Unix-based terminal (Linux/macOS)


### 2️⃣ Platform Specific setup

- Targeted Cloud Platform : **AWS**
- Create below resources before running this automation:

```
- Default VPC in the region
- Subnet 
- SecurityGroup
- Key Pair in '.pem' created in aws
- Inbound Rules 
  --------------------
  Protocol   |   Port
  --------------------
  TCP        -   9001
  TCP        -   9002
  SSH        -   22
  ---------------------
```
- Note down all the IDs of the above resources in AWS.
- Download key to your desktop or VM and place it at a known location.

### 3️⃣ Preparing Terraform files

- Clone this repo to your client VM or desktop 
- Nagivate to the $repo_dir/terraform directory 
- Find `terraform.tfvars` file and update values according to your aws environmeny

```
# Update these variables according your environment
vpc_id = "vpc-xxxxxxxx"
subnet_id = "subnet-xxxxxxx"
security_group_id = "sg-xxxxxxx"
key_name = "my_key"
ssh_private_key_path = "/<path_in_my_local_vm>/Downloads/my_key.pem"
```

### 4️⃣ Create necessary setup using Terraform

```
cd $repo_dir/terraform

terraform init

terraform plan

terraform apply -auto-approve
```

** Note down the **public IP** address of the Mediator Server : `Server_1` in the terraform output.

**This will create the below setup**

- `Server 1`, `Server2` EC2 instances attached to the VPC, Subnet, SG defined in the `tfvars` file
- Create Private and Public SSH Keys locally --> Pushes to Remote --> Exchange Keys between these two EC2 instances for secure file transfer
- `user_data.tmpl` file will install necessary softwares.
- Two file directories on both Server_1 and Server_2 will be created

```
Server 1 - /var/lib/server1_files
Server 2 - /var/lib/server2_files
```
- Pushes file service python script `ec2_file_servers.py` to Server1 and 2 and create them as system services listening on the port `9001`
- Installs `rsync` utility to sync files between these servers.
- Enable cronjob that will periodically syncs files between Server1 and 2.

### 5️⃣ Testcases

- Run `client.py` from your client machine. Two args are needed. `PUBLIC_IP` of `Server2` and filename with default path `"/"`

#### Basic Usage():

```
$ python3 client.py
Usage: python3 client_request.py SERVER1_HOST /path/to/file
Or: python3 client_request.py ping SERVER1_HOST
```

#### Case 1: There is no such file called `dummy.txt` exists either on Server 1 or 2

==> It returns `NOT FOUND` in the header.

```
$ python3 client.py <SERVER1_HOST_IP> /dummy.txt
Connecting to ('SERVER1_HOST_IP', 9001) (timeout 8.0s) ...
Server response header: NOTFOUND
File not found on both servers - Server_1 and Server_2
```

#### Case 2: Same file available on both the servers.

Create a file called `test.txt` with the same file contents on both Server1 and Server2 at `/var/lib/server1_files` and `/var/lib/server2_files`

==> It returns `FOUND MATCH`

```
$ python3 client.py <SERVER1_HOST_IP>  /test.txt
Connecting to ('SERVER1_HOST_IP', 9001) (timeout 8.0s) ...
Server response header: FOUND MATCH 6
File is matching on both the servers and output saved to client_out/test.txt (6 bytes)
```

#### Case 3: File is available either on Server1 or Server2

Create a file only on Server1 at /var/lib/server1_files [OR] only on Server2 at /var/lib/server2_files

==> It returns `FOUND ONLY` in the header.

```
$ python3 client.py <SERVER1_HOST_IP> /serv1.txt
Connecting to ('SERVER1_HOST_IP', 9001) (timeout 8.0s) ...
Server response header: FOUND ONLY 1 16
File is available (only on Server 1) to client_out/serv1.txt_only_server_1 (16 bytes)
```

```
$ python3 client.py <SERVER1_HOST_IP>  /serv2.txt
Connecting to ('SERVER1_HOST_IP', 9001) (timeout 8.0s) ...
Server response header: FOUND ONLY 2 17
File is available (only on Server 2) to client_out/serv2.txt_only_server_2 (17 bytes)
```

#### Case 4: Create file with same name on both the servers but with different content inside them

==> It returns `FOUND DIFF` in the header.

```
$ python3 client.py <SERVER1_HOST_IP>  /test2.txt
Connecting to ('SERVER1_HOST_IP', 9001) (timeout 8.0s) ...
Server response header: FOUND DIFF 6 6
Found difference in files: client_out/test2.txt_server1 (6 bytes), client_out/test2.txt_server2 (6 bytes)
```