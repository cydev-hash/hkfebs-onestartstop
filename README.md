# EBS One-Step Start & Stop Scripts

Automated scripts to start and stop an Oracle E-Business Suite (EBS) R12.2 system in a single command.

## Overview

These scripts are designed for the **opc** user on the EBS application server. They handle:

- **Database startup/shutdown** via SSH to the DB server
- **EBS Application services** startup/shutdown using `adstrtal.sh` / `adstpall.sh`
- **Live status updates** with color-coded output and per-step timing
- **Post-operation verification** of all key services
- **Process cleanup** (stop script) with 5-minute grace period and force-kill

## Scripts

| Script | Purpose | Usage |
|--------|---------|-------|
| `start_ebs.sh` | Start DB → Start EBS App → Verify | `./start_ebs.sh` |
| `stop_ebs.sh` | Stop EBS App → Cleanup → Stop DB → Verify | `./stop_ebs.sh` |

### Command Options

```bash
./start_ebs.sh              # Full startup (DB + Application)
./start_ebs.sh --skip-db    # Start application services only
./start_ebs.sh --help       # Show usage

./stop_ebs.sh               # Full shutdown (Application + DB)
./stop_ebs.sh --skip-db     # Stop application services only
./stop_ebs.sh --help        # Show usage
```

## Environment

| Component | Detail |
|-----------|--------|
| **App Server** | `ebsuat01` |
| **DB Server** | `10.101.14.21` (`ebsdbuat01`) |
| **EBS Version** | R12.2 |
| **Oracle DB** | 19c (19.18.0.0.0) Container Database |
| **OS** | Oracle Linux 8.9 |

## Startup Sequence

```
1. Start Oracle Container Database    (SSH → adcdbctl.sh start)
2. Start EBS Application Services     (adstrtal.sh -nopromptmsg)
   ├── Fulfillment Server
   ├── OPMN
   ├── Oracle HTTP Server (OHS)
   ├── Node Manager
   ├── Apps Listener
   ├── Concurrent Manager
   ├── WebLogic Admin Server
   ├── Forms Server
   ├── OAFM Server
   └── OACore Server
3. Post-Startup Verification
   ├── Database (ora_pmon)
   ├── DB Listener (tnslsnr)
   ├── WebLogic Server
   ├── Oracle HTTP Server
   ├── Concurrent Manager (FNDLIBR)
   ├── Node Manager
   ├── Forms Server
   └── Apps Listener
```

## Shutdown Sequence

```
1. Stop EBS Application Services      (adstpall.sh -nopromptmsg)
2. Wait & Cleanup Processes            (5-min grace → force kill)
3. Stop Oracle Container Database      (SSH → adcdbctl.sh stop)
4. Post-Shutdown Verification
```

## Prerequisites

### SSH Key-Based Auth (App → DB)

The scripts require passwordless SSH from the app server to the DB server:

```bash
# On app server as opc:
ssh-keygen -t rsa -b 4096 -f ~/.ssh/ebs_db_key -N ''
ssh-copy-id -i ~/.ssh/ebs_db_key.pub opc@10.101.14.21

# Then edit both scripts: set DB_SSH_KEY="~/.ssh/ebs_db_key"
```

Use `--skip-db` to operate on app services only without SSH to the DB server.

## Configuration

Both scripts have a configuration section at the top that can be modified:

```bash
DB_HOST="10.101.14.21"
DB_SSH_USER="opc"
DB_SSH_KEY=""                        # SSH key for DB server
DB_ORACLE_USER="oracle"
DB_SCRIPTS_DIR="/u01/app/oracle/product/19.0.0.0/dbhome_1/appsutil/scripts/UAT_ebsdbuat01"

APP_USER="applmgr"
EBS_ENV_FILE="/apps/ebs/fs1/EBSapps/EBSapps.env"

APPS_USERNAME="apps"
APPS_PASSWORD="apps"
WEBLOGIC_PASSWORD="welcome1"
```

## Installation

```bash
# Copy to app server
scp -P 122 -i "<ssh_key>" start_ebs.sh stop_ebs.sh opc@<app_server_ip>:~/

# Make executable
ssh -p 122 -i "<ssh_key>" opc@<app_server_ip> "chmod +x ~/start_ebs.sh ~/stop_ebs.sh"
```

## Sample Output

```
╔══════════════════════════════════════════════════════════════════╗
║  EBS SYSTEM STARTUP                                             ║
╚══════════════════════════════════════════════════════════════════╝

── STEP 1/3: Start Oracle Container Database ──

[09:20:01] ▶ Starting the container database on 10.101.14.21...
[09:20:15]   ORACLE instance started
[09:20:28]   Database mounted
[09:20:35]   Database opened
[09:20:35] ✔ Database startup complete (34s)

── STEP 2/3: Start EBS Application Services ──

[09:20:36] ▶ Starting all EBS application services as applmgr...
[09:20:45]   Starting Fulfillment Server...
[09:21:10]   Starting OPMN...
[09:21:30]   Starting Oracle HTTP Server (OHS)...
[09:22:00]   Starting Node Manager...
[09:23:15]   Starting Concurrent Manager...
[09:24:00]   Starting WebLogic Admin Server...
[09:26:30]   Starting Forms Server...
[09:28:45]   Starting OAFM Server...
[09:31:00]   Starting OACore Server...
[09:35:20] ✔ EBS Application services startup complete (14m 44s)

── STEP 3/3: Post-Startup Verification ──

[09:35:21] ✔ Database (ora_pmon) is running (OK)
[09:35:21] ✔ WebLogic Server is running (OK)
[09:35:21] ✔ Oracle HTTP Server (OHS) is running (OK)
[09:35:21] ✔ Concurrent Manager (FNDLIBR) is running (OK)
[09:35:21] ✔ Node Manager is running (OK)

  ✔  EBS SYSTEM STARTUP COMPLETED SUCCESSFULLY

  Total Time:  15m 20s

  Step                                Duration        Status
  ───────────────────────────────     ───────────     ────────────
  Start Database                      34s             SUCCESS
  Start EBS App Services              14m 44s         SUCCESS
  Verification                        2s              5 passed, 0 failed
```
