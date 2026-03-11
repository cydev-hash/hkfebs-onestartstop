#!/bin/bash
#==============================================================================
#  EBS Full System Stop Script
#
#  Execute as:  opc user on the application server
#  Usage:       ./stop_ebs.sh [--skip-db]
#
#  Stop Sequence:
#    1. Stop EBS Application Services    (locally as applmgr via adstpall.sh)
#    2. Wait & cleanup remaining applmgr processes
#    3. Stop Oracle Container Database   (via SSH to DB server)
#    4. Verify all services are stopped
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

CLEANUP_WAIT_SECS=300                # 5 minutes wait before force-killing

#──────────────────────────────────────────────────────────────────────────────
# PARSE ARGUMENTS
#──────────────────────────────────────────────────────────────────────────────
SKIP_DB=false
for arg in "$@"; do
    case "$arg" in
        --skip-db) SKIP_DB=true ;;
        --help|-h)
            echo "Usage: $0 [--skip-db]"
            echo "  --skip-db  Skip database shutdown (stop app services only)"
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
print_banner "EBS SYSTEM SHUTDOWN"
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
        print_info "Use --skip-db to stop only the application services."
        exit 1
    fi
fi

echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

#==============================================================================
# STEP 1: STOP EBS APPLICATION SERVICES
#==============================================================================
print_header "STEP 1/4: Stop EBS Application Services"
STEP_START=$(date +%s)
print_step "Stopping all EBS application services as ${APP_USER}..."
print_info "This step may take 10-20 minutes. Key status updates shown below..."

TMP_APP_LOG=$(mktemp /tmp/ebs_app_stop_XXXXXX.log)

# Use -nopromptmsg flag to read credentials from stdin (no expect needed)
printf '%s\n' "${APPS_USERNAME}" "${APPS_PASSWORD}" "${WEBLOGIC_PASSWORD}" | \
    sudo -u ${APP_USER} bash -c "source ${EBS_ENV_FILE} run 2>/dev/null && adstpall.sh -nopromptmsg" 2>&1 | \
    tee "${TMP_APP_LOG}" | while IFS= read -r line; do
    case "$line" in
        *"Stopping OPMN managed"*|*"Stopping Oracle HTTP"*)
                                             print_substep "Stopping Oracle HTTP Server (OHS)..." ;;
        *"Shutting down concurrent"*)        print_substep "Stopping Concurrent Manager..." ;;
        *"Shutting down Fulfillment"*)       print_substep "Stopping Fulfillment Server..." ;;
        *"Stopping Oracle Process"*)         print_substep "Stopping OPMN..." ;;
        *"Stopping oacore_server"*)          print_substep "Stopping OACore Server..." ;;
        *"Stopping oafm_server"*)            print_substep "Stopping OAFM Server..." ;;
        *"Stopping forms_server"*)           print_substep "Stopping Forms Server..." ;;
        *"Shutting down listener"*)          print_substep "Stopping Apps Listener..." ;;
        *"Stopping WLS Admin"*)              print_substep "Stopping WebLogic Admin Server..." ;;
        *"Stopping.*Node"*|*"adnodemgrctl"*stop*)
                                             print_substep "Stopping Node Manager..." ;;
        *"All enabled services"*stopped*)    print_substep "$line" ;;
    esac
done

STEP_DURATION_FMT=$(format_duration $(( $(date +%s) - STEP_START )))

if grep -q "Exiting with status 0" "${TMP_APP_LOG}" 2>/dev/null; then
    print_success "EBS Application services stopped" "${STEP_DURATION_FMT}"
    record_step "Stop EBS App Services" "$STEP_DURATION_FMT" "SUCCESS"
else
    print_warning "EBS Application services stop may have had issues"
    record_step "Stop EBS App Services" "$STEP_DURATION_FMT" "WARNING"
    print_info "Check log: /apps/ebs/fs1/inst/apps/UAT_ebsuat01/logs/appl/admin/log/adstpall.log"
fi
rm -f "${TMP_APP_LOG}"

#==============================================================================
# STEP 2: WAIT & CLEANUP REMAINING PROCESSES
#==============================================================================
print_header "STEP 2/4: Cleanup Remaining Processes"
STEP_START=$(date +%s)

print_step "Checking for remaining ${APP_USER} processes..."

# Check if any applmgr processes still exist
REMAINING=$(ps -u ${APP_USER} -o pid= 2>/dev/null | wc -l)

if ((REMAINING == 0)); then
    STEP_DURATION_FMT=$(format_duration $(( $(date +%s) - STEP_START )))
    print_success "No remaining ${APP_USER} processes found" "${STEP_DURATION_FMT}"
    record_step "Cleanup Processes" "$STEP_DURATION_FMT" "SUCCESS"
else
    print_warning "${REMAINING} ${APP_USER} processes still running"
    print_step "Waiting up to 5 minutes for graceful termination..."

    WAIT_START=$(date +%s)
    while true; do
        REMAINING=$(ps -u ${APP_USER} -o pid= 2>/dev/null | wc -l)
        ELAPSED=$(( $(date +%s) - WAIT_START ))

        if ((REMAINING == 0)); then
            print_success "All ${APP_USER} processes have terminated gracefully" "$(format_duration $ELAPSED)"
            break
        fi

        if ((ELAPSED >= CLEANUP_WAIT_SECS)); then
            print_warning "${REMAINING} processes still running after 5 minutes"
            print_step "Force killing remaining ${APP_USER} processes..."
            sudo pkill -9 -u ${APP_USER} 2>/dev/null || true
            sleep 3

            # Verify kill was successful
            REMAINING=$(ps -u ${APP_USER} -o pid= 2>/dev/null | wc -l)
            if ((REMAINING == 0)); then
                print_success "All remaining processes force-killed" "OK"
            else
                print_warning "${REMAINING} processes could not be killed (may be system processes)"
            fi
            break
        fi

        print_info "Waiting... ${REMAINING} processes remaining ($(format_duration $((CLEANUP_WAIT_SECS - ELAPSED))) left)"
        sleep 30
    done

    STEP_DURATION_FMT=$(format_duration $(( $(date +%s) - STEP_START )))
    record_step "Cleanup Processes" "$STEP_DURATION_FMT" "SUCCESS"
fi

#==============================================================================
# STEP 3: STOP DATABASE
#==============================================================================
if [[ "$SKIP_DB" == "false" ]]; then
    print_header "STEP 3/4: Stop Oracle Container Database"
    STEP_START=$(date +%s)
    print_step "Stopping the container database on ${DB_HOST}..."

    TMP_DB_LOG=$(mktemp /tmp/ebs_db_stop_XXXXXX.log)

    ssh ${SSH_OPTS} ${DB_SSH_USER}@${DB_HOST} \
        "sudo su - ${DB_ORACLE_USER} -c 'cd ${DB_SCRIPTS_DIR} && ./adcdbctl.sh stop'" 2>&1 | \
        tee "${TMP_DB_LOG}" | while IFS= read -r line; do
        case "$line" in
            *"Shutting down container database"*)  print_substep "$line" ;;
            *"Database closed"*)                   print_substep "$line" ;;
            *"Database dismounted"*)               print_substep "$line" ;;
            *"ORACLE instance shut down"*)         print_substep "$line" ;;
            *"adcdbctl.sh: exiting"*)              print_substep "$line" ;;
        esac
    done

    STEP_DURATION_FMT=$(format_duration $(( $(date +%s) - STEP_START )))

    if grep -q "exiting with status 0" "${TMP_DB_LOG}" 2>/dev/null; then
        print_success "Database shutdown complete" "${STEP_DURATION_FMT}"
        record_step "Stop Database" "$STEP_DURATION_FMT" "SUCCESS"
    else
        print_error "Database shutdown may have failed"
        record_step "Stop Database" "$STEP_DURATION_FMT" "FAILED"
        print_info "Full output saved: ${TMP_DB_LOG}"
    fi
    rm -f "${TMP_DB_LOG}"
else
    print_header "STEP 3/4: Stop Database (SKIPPED)"
    print_warning "Database shutdown skipped (--skip-db)"
    record_step "Stop Database" "skipped" "SKIPPED"
fi

#==============================================================================
# STEP 4: VERIFICATION
#==============================================================================
print_header "STEP 4/4: Post-Shutdown Verification"
STEP_START=$(date +%s)
VERIFY_PASS=0
VERIFY_FAIL=0

print_step "Verifying EBS system is fully stopped..."

# --- Database verification ---
if [[ "$SKIP_DB" == "false" ]]; then
    print_substep "Checking database processes on ${DB_HOST}..."
    DB_PMON=$(ssh ${SSH_OPTS} ${DB_SSH_USER}@${DB_HOST} "ps -ef | grep ora_pmon | grep -v grep" 2>/dev/null)
    if [[ -z "$DB_PMON" ]]; then
        print_success "Database (ora_pmon) is stopped" "OK"
        ((VERIFY_PASS++))
    else
        print_error "Database (ora_pmon) is still running!"
        ((VERIFY_FAIL++))
    fi
fi

# --- Application verification ---
print_substep "Checking application processes on $(hostname)..."

# Check applmgr processes
APP_PROCS=$(ps -u ${APP_USER} -o pid= 2>/dev/null | wc -l)
if ((APP_PROCS == 0)); then
    print_success "No ${APP_USER} processes running" "OK"
    ((VERIFY_PASS++))
else
    print_warning "${APP_PROCS} ${APP_USER} processes still running"
    ((VERIFY_FAIL++))
fi

# WebLogic
if ps -ef | grep -q "[w]eblogic.Server" 2>/dev/null; then
    print_error "WebLogic Server is still running!"
    ((VERIFY_FAIL++))
else
    print_success "WebLogic Server is stopped" "OK"
    ((VERIFY_PASS++))
fi

# Oracle HTTP Server
if ps -ef | grep -q "[h]ttpd" 2>/dev/null; then
    print_error "HTTP Server is still running!"
    ((VERIFY_FAIL++))
else
    print_success "HTTP Server is stopped" "OK"
    ((VERIFY_PASS++))
fi

# Node Manager
if ps -ef | grep -q "[N]odeManager" 2>/dev/null; then
    print_error "Node Manager is still running!"
    ((VERIFY_FAIL++))
else
    print_success "Node Manager is stopped" "OK"
    ((VERIFY_PASS++))
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
    echo -e "  ${BOLD}${GREEN}║     ✔  EBS SYSTEM SHUTDOWN COMPLETED SUCCESSFULLY      ║${NC}"
    echo -e "  ${BOLD}${GREEN}╚══════════════════════════════════════════════════════════╝${NC}"
else
    echo ""
    echo -e "  ${BOLD}${YELLOW}╔══════════════════════════════════════════════════════════╗${NC}"
    echo -e "  ${BOLD}${YELLOW}║     ⚠  EBS SYSTEM SHUTDOWN COMPLETED WITH WARNINGS     ║${NC}"
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
