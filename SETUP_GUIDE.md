# EBS System Manager — Setup Guide

A step-by-step guide to deploy the `ebs` command on any Oracle E-Business Suite environment.

---

## Quick Start

```bash
# 1. Copy the ebs script to the app server
scp -P <SSH_PORT> -i "<SSH_KEY>" ebs opc@<APP_SERVER_IP>:~/ebs

# 2. Edit the configuration section (see "Parameters to Change" below)
ssh -p <SSH_PORT> -i "<SSH_KEY>" opc@<APP_SERVER_IP>
vi ~/ebs

# 3. Install as system command
sudo cp ~/ebs /usr/local/bin/ebs
sudo chmod +x /usr/local/bin/ebs

# 4. Fix line endings (if copied from Windows)
sudo sed -i 's/\r$//' /usr/local/bin/ebs

# 5. Set up SSH key for DB server access
ssh-keygen -t rsa -b 4096 -f ~/.ssh/ebs_db_key -N ''
ssh-copy-id -i ~/.ssh/ebs_db_key.pub opc@<DB_PRIVATE_IP>

# 6. Test
ebs check
ebs start
ebs stop
```

---

## Parameters to Change

All parameters are in the **CONFIGURATION** section at the top of the `ebs` script (lines 17–31).

### Database Server

| Parameter | Description | How to Find |
|-----------|-------------|-------------|
| `DB_HOST` | DB server private IP or hostname | `cat /etc/hosts \| grep db` or OCI console |
| `DB_SSH_USER` | SSH user on DB server | Usually `opc` on OCI |
| `DB_SSH_KEY` | Path to SSH key for DB server | See "SSH Setup" section below |
| `DB_ORACLE_USER` | OS user that owns the DB | Usually `oracle` |
| `DB_SCRIPTS_DIR` | Path to EBS DB scripts | See "Finding DB Scripts" below |

### Application Server

| Parameter | Description | How to Find |
|-----------|-------------|-------------|
| `APP_USER` | OS user that owns EBS app | Usually `applmgr` |
| `EBS_ENV_FILE` | Path to `EBSapps.env` | See "Finding Env File" below |
| `APPS_USERNAME` | EBS APPS schema username | Usually `apps` |
| `APPS_PASSWORD` | EBS APPS schema password | Ask your DBA |
| `WEBLOGIC_PASSWORD` | WebLogic admin password | Ask your DBA |

### Example Configurations

**UAT Environment:**
```bash
DB_HOST="10.101.14.21"
DB_SSH_USER="opc"
DB_SSH_KEY="/home/opc/.ssh/ebs_db_key"
DB_ORACLE_USER="oracle"
DB_SCRIPTS_DIR="/u01/app/oracle/product/19.0.0.0/dbhome_1/appsutil/scripts/UAT_ebsdbuat01"
APP_USER="applmgr"
EBS_ENV_FILE="/apps/ebs/EBSapps.env"
APPS_USERNAME="apps"
APPS_PASSWORD="apps"
WEBLOGIC_PASSWORD="welcome1"
```

**Production Environment (example):**
```bash
DB_HOST="10.0.1.50"
DB_SSH_USER="opc"
DB_SSH_KEY="/home/opc/.ssh/ebs_db_key"
DB_ORACLE_USER="oracle"
DB_SCRIPTS_DIR="/u01/app/oracle/product/19.0.0.0/dbhome_1/appsutil/scripts/PROD_ebsdbprd01"
APP_USER="applmgr"
EBS_ENV_FILE="/apps/ebs/EBSapps.env"
APPS_USERNAME="apps"
APPS_PASSWORD="prod_apps_pwd"
WEBLOGIC_PASSWORD="prod_wls_pwd"
```

---

## How to Find Each Parameter

### Finding DB_SCRIPTS_DIR

SSH to the DB server as the oracle user and locate the EBS admin scripts:

```bash
# On the DB server:
sudo su - oracle
find $ORACLE_HOME -name "adcdbctl.sh" -type f 2>/dev/null
```

The output will be something like:
```
/u01/app/oracle/product/19.0.0.0/dbhome_1/appsutil/scripts/PROD_ebsdbprd01/adcdbctl.sh
```

The `DB_SCRIPTS_DIR` is the directory containing that file:
```
/u01/app/oracle/product/19.0.0.0/dbhome_1/appsutil/scripts/PROD_ebsdbprd01
```

**Pattern:** `$ORACLE_HOME/appsutil/scripts/<SID>_<db_hostname>`

### Finding EBS_ENV_FILE

SSH to the app server and search for the environment file:

```bash
# On the app server:
sudo find /apps -name "EBSapps.env" -maxdepth 3 -type f 2>/dev/null
```

Common locations:
- `/apps/ebs/EBSapps.env`
- `/d01/oracle/apps/EBSapps.env`
- `/oracle/apps/EBSapps.env`

**Verify it works:**
```bash
sudo -u applmgr bash -c 'source /apps/ebs/EBSapps.env run 2>/dev/null; which adstrtal.sh'
```

If this prints the path to `adstrtal.sh`, the env file is correct.

### Finding APP_USER

```bash
# Check what user owns the EBS application files:
ls -la /apps/ebs/  # or wherever your EBS is installed
# The owner is your APP_USER (typically: applmgr, oracle, or apps)
```

### Finding DB_ORACLE_USER

```bash
# On the DB server:
ps -ef | grep ora_pmon | grep -v grep
# The first column shows the user (typically: oracle)
```

---

## SSH Setup (App Server → DB Server)

The `ebs` command needs passwordless SSH from the app server to the DB server.

### Option A: Generate New Key Pair (Recommended)

```bash
# On the app server as opc:
ssh-keygen -t rsa -b 4096 -f ~/.ssh/ebs_db_key -N ''

# Copy public key to DB server (requires password or existing access):
ssh-copy-id -i ~/.ssh/ebs_db_key.pub opc@<DB_HOST>

# Test:
ssh -i ~/.ssh/ebs_db_key opc@<DB_HOST> "echo OK"

# Update ebs script:
# Set DB_SSH_KEY="/home/opc/.ssh/ebs_db_key"
```

### Option B: Copy Existing OCI Key

If both servers use the same OCI SSH key:

```bash
# From your workstation:
scp -P <SSH_PORT> -i "<YOUR_KEY>" "<YOUR_KEY>" opc@<APP_SERVER>:~/.ssh/ebs_db_key

# On the app server:
chmod 600 ~/.ssh/ebs_db_key

# Test:
ssh -i ~/.ssh/ebs_db_key opc@<DB_HOST> "echo OK"
```

---

## Verification Checklist

After installation, run through this checklist:

```
✅  ebs --help              # Shows usage information
✅  ebs check               # Shows status of all services
✅  ebs check --skip-db     # Shows status of app services only
✅  ebs stop                # Stops all services
✅  ebs check               # Confirms everything is stopped
✅  ebs start               # Starts all services (15-30 min)
✅  ebs check               # Confirms everything is running
```

---

## Troubleshooting

### "command not found: adstrtal.sh"
- **Cause:** Wrong `EBS_ENV_FILE` path
- **Fix:** Run `sudo find /apps -name "EBSapps.env" -maxdepth 3` and update the path

### "adcdbctl.sh: exiting with status 9"
- **Cause:** Database is already running
- **Fix:** The script auto-detects this and skips — no action needed

### "Cannot SSH to opc@DB_HOST"
- **Cause:** SSH key-based auth not configured
- **Fix:** Follow the SSH Setup section above

### "bash: /usr/local/bin/ebs: bad interpreter"
- **Cause:** Windows CRLF line endings
- **Fix:** `sudo sed -i 's/\r$//' /usr/local/bin/ebs`

### App services take 0 seconds (instant failure)
- **Cause:** Usually wrong `EBS_ENV_FILE` path or `APP_USER`
- **Fix:** Verify with:
  ```bash
  sudo -u <APP_USER> bash -c 'source <EBS_ENV_FILE> run 2>/dev/null; which adstrtal.sh'
  ```

### "Permission denied" on credentials temp file
- **Cause:** Temp file created by root can't be read by applmgr
- **Fix:** The script uses `chmod 644` on the temp file — this should work. If not, check `/tmp` permissions.

---

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│  Your Windows PC                                        │
│  ssh -p PORT -i KEY opc@APP_SERVER_IP                   │
└──────────────────────┬──────────────────────────────────┘
                       │ SSH
                       ▼
┌─────────────────────────────────────────────────────────┐
│  Application Server (ebsuat01)                          │
│  User: opc                                              │
│  Command: /usr/local/bin/ebs                            │
│                                                         │
│  ┌───────────────────────────────────────────────────┐  │
│  │ ebs start / stop                                  │  │
│  │   ├── ssh opc@DB_HOST → sudo su - oracle          │  │
│  │   │     └── adcdbctl.sh start/stop                │  │
│  │   └── sudo -u applmgr                             │  │
│  │         └── adstrtal.sh / adstpall.sh             │  │
│  └───────────────────────────────────────────────────┘  │
│                       │ SSH (internal)                   │
└───────────────────────┼─────────────────────────────────┘
                        ▼
┌─────────────────────────────────────────────────────────┐
│  Database Server (ebsdbuat01)                           │
│  User: oracle                                           │
│  Scripts: $ORACLE_HOME/appsutil/scripts/<SID>_<host>/   │
└─────────────────────────────────────────────────────────┘
```

---

## Files in This Repository

| File | Description |
|------|-------------|
| `ebs` | Main unified command script (install to `/usr/local/bin/ebs`) |
| `start_ebs.sh` | Standalone start script (alternative to `ebs start`) |
| `stop_ebs.sh` | Standalone stop script (alternative to `ebs stop`) |
| `check_ebs_status.sh` | Standalone status check (alternative to `ebs check`) |
| `SETUP_GUIDE.md` | This setup guide |
| `README.md` | Project overview |
