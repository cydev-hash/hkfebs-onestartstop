#!/bin/bash
#==============================================================================
#  EBS Full System Startup Script
#
#  Execute as:  opc user on the application server
#  Usage:       ./start_ebs.sh [--skip-db]
#
#  Startup Sequence:
#    1. Start Oracle Container Database  (via SSH to DB server)
#    2. Start EBS Application Services   (locally as applmgr)
#    3. Verify all services are running
#==============================================================================

set -o pipefail

#──────────────────────────────────────────────────────────────────────────────
# CONFIGURATION  (modify these values as needed)
#──────────────────────────────────────────────────────────────────────────────
DB_HOST="10.101.14.21"
DB_SSH_USER="opc"
DB_SSH_KEY=""                        # SSH key for DB server (empty = default)
DB_ORACLE_USER="oracle"
DB_SCRIPTS_DIR="/u01/app/oracle/product/19.0.0.0/dbhome_1/appsutil/scripts/UAT_ebsdbuat01"

APP_USER="applmgr"
EBS_ENV_FILE="/apps/ebs/fs1/EBSapps/EBSapps.env"

APPS_USERNAME="apps"
APPS_PASSWORD="apps"
WEBLOGIC_PASSWORD="welcome1"

#──────────────────────────────────────────────────────────────────────────────
# PARSE ARGUMENTS
#──────────────────────────────────────────────────────────────────────────────
SKIP_DB=false
for arg in "$@"; do
    case "$arg" in
        --skip-db) SKIP_DB=true ;;
        --help|-h)
            echo "Usage: $0 [--skip-db]"
            echo "  --skip-db  Skip database startup (start app services only)"
            exit 0
            ;;
    esac
done

#──────────────────────────────────────────────────────────────────────────────
# DISPLAY HELPERS
#──────────────────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; MAGENTA='\033[0;35m'
BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'

SCRIPT_START_TIME=$(date +%s)
declare -a STEP_NAMES=()
declare -a STEP_DURATIONS=()
declare -a STEP_STATUSES=()

print_banner()  { echo ""; echo -e "${BOLD}${BLUE}╔══════════════════════════════════════════════════════════════════╗${NC}"; echo -e "${BOLD}${BLUE}║${NC}  ${BOLD}$1${NC}"; echo -e "${BOLD}${BLUE}╚══════════════════════════════════════════════════════════════════╝${NC}"; echo ""; }
print_header()  { echo ""; echo -e "${BOLD}${MAGENTA}── $1 ──${NC}"; echo ""; }
print_step()    { echo -e "${CYAN}[$(date '+%H:%M:%S')]${NC} ${BOLD}▶${NC} $1"; }
print_substep() { echo -e "${DIM}[$(date '+%H:%M:%S')]${NC}   $1"; }
print_success() { echo -e "${GREEN}[$(date '+%H:%M:%S')]${NC} ${GREEN}✔ $1${NC} ${DIM}($2)${NC}"; }
print_error()   { echo -e "${RED}[$(date '+%H:%M:%S')]${NC} ${RED}✘ $1${NC}"; }
print_warning() { echo -e "${YELLOW}[$(date '+%H:%M:%S')]${NC} ${YELLOW}⚠ $1${NC}"; }
print_info()    { echo -e "${DIM}[$(date '+%H:%M:%S')]${NC}   ${DIM}$1${NC}"; }

format_duration() {
    local s=$1
    if ((s >= 3600)); then printf "%dh %dm %ds" $((s/3600)) $((s%3600/60)) $((s%60))
    elif ((s >= 60)); then printf "%dm %ds" $((s/60)) $((s%60))
    else printf "%ds" $s; fi
}

record_step() { STEP_NAMES+=("$1"); STEP_DURATIONS+=("$2"); STEP_STATUSES+=("$3"); }

# SSH options
SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=30 -o BatchMode=yes"
[[ -n "$DB_SSH_KEY" ]] && SSH_OPTS="$SSH_OPTS -i $DB_SSH_KEY"

#──────────────────────────────────────────────────────────────────────────────
# PRE-FLIGHT CHECKS
#──────────────────────────────────────────────────────────────────────────────
print_banner "EBS SYSTEM STARTUP"
echo -e "  ${BOLD}Date:${NC}        $(date '+%Y-%m-%d %H:%M:%S %Z')"
echo -e "  ${BOLD}App Server:${NC}  $(hostname)"
echo -e "  ${BOLD}DB Server:${NC}   ${DB_HOST}"
echo -e "  ${BOLD}Skip DB:${NC}     ${SKIP_DB}"
echo ""

# Check SSH to DB server
if [[ "$SKIP_DB" == "false" ]]; then
    print_step "Testing SSH connectivity to DB server ${DB_HOST}..."
    if ssh ${SSH_OPTS} ${DB_SSH_USER}@${DB_HOST} "echo OK" &>/dev/null; then
        print_success "SSH connectivity confirmed" "OK"
    else
        print_error "Cannot SSH to ${DB_SSH_USER}@${DB_HOST}"
        echo ""
        print_info "Set up SSH key-based authentication:"
        print_info "  1. ssh-keygen -t rsa -b 4096 -f ~/.ssh/ebs_db_key -N ''"
        print_info "  2. ssh-copy-id -i ~/.ssh/ebs_db_key.pub ${DB_SSH_USER}@${DB_HOST}"
        print_info "  3. Edit this script: set DB_SSH_KEY=\"~/.ssh/ebs_db_key\""
        print_info ""
        print_info "Or run with --skip-db to start only the application services."
        exit 1
    fi
fi

echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

#==============================================================================
# STEP 1: START DATABASE
#==============================================================================
if [[ "$SKIP_DB" == "false" ]]; then
    print_header "STEP 1/3: Start Oracle Container Database"
    STEP_START=$(date +%s)
    print_step "Starting the container database on ${DB_HOST}..."

    TMP_DB_LOG=$(mktemp /tmp/ebs_db_start_XXXXXX.log)

    ssh ${SSH_OPTS} ${DB_SSH_USER}@${DB_HOST} \
        "sudo su - ${DB_ORACLE_USER} -c 'cd ${DB_SCRIPTS_DIR} && ./adcdbctl.sh start'" 2>&1 | \
        tee "${TMP_DB_LOG}" | while IFS= read -r line; do
        case "$line" in
            *"Starting the container database"*)  print_substep "$line" ;;
            *"ORACLE instance started"*)          print_substep "$line" ;;
            *"Database mounted"*)                 print_substep "$line" ;;
            *"Database opened"*)                  print_substep "$line" ;;
            *"Total System Global Area"*)         print_substep "$line" ;;
            *"adcdbctl.sh: exiting"*)             print_substep "$line" ;;
        esac
    done

    STEP_DURATION_FMT=$(format_duration $(( $(date +%s) - STEP_START )))

    if grep -q "exiting with status 0" "${TMP_DB_LOG}" 2>/dev/null; then
        print_success "Database startup complete" "${STEP_DURATION_FMT}"
        record_step "Start Database" "$STEP_DURATION_FMT" "SUCCESS"
    else
        print_error "Database startup failed"
        record_step "Start Database" "$STEP_DURATION_FMT" "FAILED"
        print_info "Full output saved: ${TMP_DB_LOG}"
        exit 1
    fi
    rm -f "${TMP_DB_LOG}"
else
    print_header "STEP 1/3: Start Database (SKIPPED)"
    print_warning "Database startup skipped (--skip-db)"
    record_step "Start Database" "skipped" "SKIPPED"
fi

#==============================================================================
# STEP 2: START EBS APPLICATION SERVICES
#==============================================================================
print_header "STEP 2/3: Start EBS Application Services"
STEP_START=$(date +%s)
print_step "Starting all EBS application services as ${APP_USER}..."
print_info "This step may take 15-30 minutes. Key status updates shown below..."

TMP_APP_LOG=$(mktemp /tmp/ebs_app_start_XXXXXX.log)

# Use -nopromptmsg flag to read credentials from stdin (no expect needed)
printf '%s\n' "${APPS_USERNAME}" "${APPS_PASSWORD}" "${WEBLOGIC_PASSWORD}" | \
    sudo -u ${APP_USER} bash -c "source ${EBS_ENV_FILE} run 2>/dev/null && adstrtal.sh -nopromptmsg" 2>&1 | \
    tee "${TMP_APP_LOG}" | while IFS= read -r line; do
    case "$line" in
        *"Starting Fulfillment"*)            print_substep "Starting Fulfillment Server..." ;;
        *"Starting Oracle Process"*)         print_substep "Starting OPMN..." ;;
        *"Starting OPMN managed"*)           print_substep "Starting Oracle HTTP Server (OHS)..." ;;
        *"Starting the Node Manager"*)       print_substep "Starting Node Manager..." ;;
        *"Checking for FNDFS"*|*"Starting listener process APPS"*)
                                             print_substep "Starting Apps Listener..." ;;
        *"Starting concurrent manager"*)     print_substep "Starting Concurrent Manager..." ;;
        *"Starting WLS Admin"*)              print_substep "Starting WebLogic Admin Server..." ;;
        *"Starting forms_server"*)           print_substep "Starting Forms Server..." ;;
        *"Starting oafm_server"*)            print_substep "Starting OAFM Server..." ;;
        *"Starting oacore_server"*)          print_substep "Starting OACore Server..." ;;
        *"All enabled services"*)            print_substep "$line" ;;
    esac
done

STEP_DURATION_FMT=$(format_duration $(( $(date +%s) - STEP_START )))

if grep -q "Exiting with status 0" "${TMP_APP_LOG}" 2>/dev/null; then
    print_success "EBS Application services startup complete" "${STEP_DURATION_FMT}"
    record_step "Start EBS App Services" "$STEP_DURATION_FMT" "SUCCESS"
else
    print_error "EBS Application services startup may have failed"
    record_step "Start EBS App Services" "$STEP_DURATION_FMT" "FAILED"
    print_info "Check log: /apps/ebs/fs1/inst/apps/UAT_ebsuat01/logs/appl/admin/log/adstrtal.log"
fi
rm -f "${TMP_APP_LOG}"

#==============================================================================
# STEP 3: VERIFICATION
#==============================================================================
print_header "STEP 3/3: Post-Startup Verification"
STEP_START=$(date +%s)
VERIFY_PASS=0
VERIFY_FAIL=0

print_step "Verifying EBS system status..."

# --- Database verification ---
if [[ "$SKIP_DB" == "false" ]]; then
    print_substep "Checking database processes on ${DB_HOST}..."
    DB_PMON=$(ssh ${SSH_OPTS} ${DB_SSH_USER}@${DB_HOST} "ps -ef | grep ora_pmon | grep -v grep" 2>/dev/null)
    if [[ -n "$DB_PMON" ]]; then
        print_success "Database (ora_pmon) is running" "OK"
        ((VERIFY_PASS++))
    else
        print_error "Database (ora_pmon) is NOT running"
        ((VERIFY_FAIL++))
    fi

    DB_LSNR=$(ssh ${SSH_OPTS} ${DB_SSH_USER}@${DB_HOST} "ps -ef | grep tnslsnr | grep -v grep" 2>/dev/null)
    if [[ -n "$DB_LSNR" ]]; then
        print_success "DB Listener (tnslsnr) is running" "OK"
        ((VERIFY_PASS++))
    else
        print_warning "DB Listener (tnslsnr) not detected (may be managed by Grid Infrastructure)"
    fi
fi

# --- Application verification ---
print_substep "Checking application processes on $(hostname)..."

# WebLogic
if ps -ef | grep -q "[w]eblogic.Server" 2>/dev/null; then
    print_success "WebLogic Server is running" "OK"
    ((VERIFY_PASS++))
else
    print_error "WebLogic Server is NOT running"
    ((VERIFY_FAIL++))
fi

# Oracle HTTP Server
if ps -ef | grep -q "[h]ttpd" 2>/dev/null; then
    print_success "Oracle HTTP Server (OHS) is running" "OK"
    ((VERIFY_PASS++))
else
    print_error "Oracle HTTP Server is NOT running"
    ((VERIFY_FAIL++))
fi

# Concurrent Manager
if ps -ef | grep -q "[F]NDLIBR" 2>/dev/null; then
    print_success "Concurrent Manager (FNDLIBR) is running" "OK"
    ((VERIFY_PASS++))
else
    print_warning "Concurrent Manager (FNDLIBR) not detected (may still be starting)"
fi

# Node Manager
if ps -ef | grep -q "[N]odeManager" 2>/dev/null; then
    print_success "Node Manager is running" "OK"
    ((VERIFY_PASS++))
else
    print_error "Node Manager is NOT running"
    ((VERIFY_FAIL++))
fi

# Forms Server
if ps -ef | grep -q "[f]orms_server\|[f]rmbld" 2>/dev/null; then
    print_success "Forms Server is running" "OK"
    ((VERIFY_PASS++))
else
    print_warning "Forms Server process not detected (may still be starting)"
fi

# Apps Listener
if ps -ef | grep -q "[t]nslsnr.*APPS_" 2>/dev/null; then
    print_success "Apps Listener is running" "OK"
    ((VERIFY_PASS++))
else
    print_warning "Apps Listener not detected"
fi

STEP_DURATION_FMT=$(format_duration $(( $(date +%s) - STEP_START )))
record_step "Verification" "$STEP_DURATION_FMT" "${VERIFY_PASS} passed, ${VERIFY_FAIL} failed"

#==============================================================================
# SUMMARY
#==============================================================================
TOTAL_DURATION_FMT=$(format_duration $(( $(date +%s) - SCRIPT_START_TIME )))

echo ""
echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

if ((VERIFY_FAIL == 0)); then
    echo ""
    echo -e "  ${BOLD}${GREEN}╔══════════════════════════════════════════════════════════╗${NC}"
    echo -e "  ${BOLD}${GREEN}║     ✔  EBS SYSTEM STARTUP COMPLETED SUCCESSFULLY       ║${NC}"
    echo -e "  ${BOLD}${GREEN}╚══════════════════════════════════════════════════════════╝${NC}"
else
    echo ""
    echo -e "  ${BOLD}${YELLOW}╔══════════════════════════════════════════════════════════╗${NC}"
    echo -e "  ${BOLD}${YELLOW}║     ⚠  EBS SYSTEM STARTUP COMPLETED WITH WARNINGS      ║${NC}"
    echo -e "  ${BOLD}${YELLOW}╚══════════════════════════════════════════════════════════╝${NC}"
fi

echo ""
echo -e "  ${BOLD}Total Time:${NC}  ${TOTAL_DURATION_FMT}"
echo ""
printf "  ${BOLD}%-35s %-15s %-20s${NC}\n" "Step" "Duration" "Status"
printf "  %-35s %-15s %-20s\n" "───────────────────────────────────" "───────────────" "────────────────────"
for i in "${!STEP_NAMES[@]}"; do
    status="${STEP_STATUSES[$i]}"
    case "$status" in
        SUCCESS)  color="$GREEN" ;;
        SKIPPED)  color="$YELLOW" ;;
        FAILED)   color="$RED" ;;
        *)        color="$CYAN" ;;
    esac
    printf "  %-35s %-15s ${color}%-20s${NC}\n" "${STEP_NAMES[$i]}" "${STEP_DURATIONS[$i]}" "${status}"
done
echo ""
echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

if ((VERIFY_FAIL > 0)); then
    exit 1
fi
exit 0
