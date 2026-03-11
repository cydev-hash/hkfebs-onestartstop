#!/bin/bash
#==============================================================================
#  EBS System Status Check Script
#
#  Execute as:  opc user on the application server
#  Usage:       ./check_ebs_status.sh [--skip-db]
#
#  Checks whether EBS services are running or stopped.
#==============================================================================

#──────────────────────────────────────────────────────────────────────────────
# CONFIGURATION
#──────────────────────────────────────────────────────────────────────────────
DB_HOST="10.101.14.21"
DB_SSH_USER="opc"
DB_SSH_KEY=""
APP_USER="applmgr"

#──────────────────────────────────────────────────────────────────────────────
# PARSE ARGUMENTS
#──────────────────────────────────────────────────────────────────────────────
SKIP_DB=false
for arg in "$@"; do
    case "$arg" in
        --skip-db) SKIP_DB=true ;;
        --help|-h)
            echo "Usage: $0 [--skip-db]"
            echo "  --skip-db  Skip database checks"
            exit 0
            ;;
    esac
done

#──────────────────────────────────────────────────────────────────────────────
# DISPLAY HELPERS
#──────────────────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'

UP=0; DOWN=0; WARN=0

check_pass()    { echo -e "  ${GREEN}✔ RUNNING${NC}  $1"; ((UP++)); }
check_fail()    { echo -e "  ${RED}✘ STOPPED${NC}  $1"; ((DOWN++)); }
check_warn()    { echo -e "  ${YELLOW}⚠ UNKNOWN${NC}  $1"; ((WARN++)); }

SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=10 -o BatchMode=yes"
[[ -n "$DB_SSH_KEY" ]] && SSH_OPTS="$SSH_OPTS -i $DB_SSH_KEY"

#──────────────────────────────────────────────────────────────────────────────
# STATUS CHECK
#──────────────────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}${CYAN}════════════════════════════════════════════════════════════════${NC}"
echo -e "${BOLD}  EBS System Status Check  —  $(date '+%Y-%m-%d %H:%M:%S %Z')${NC}"
echo -e "${BOLD}${CYAN}════════════════════════════════════════════════════════════════${NC}"

# --- Database ---
echo ""
echo -e "${BOLD}  Database Server (${DB_HOST})${NC}"
echo -e "  ${DIM}────────────────────────────────────────${NC}"

if [[ "$SKIP_DB" == "false" ]]; then
    if ssh ${SSH_OPTS} ${DB_SSH_USER}@${DB_HOST} "echo OK" &>/dev/null; then
        # ora_pmon
        if ssh ${SSH_OPTS} ${DB_SSH_USER}@${DB_HOST} "ps -ef | grep ora_pmon | grep -v grep" &>/dev/null; then
            DB_NAME=$(ssh ${SSH_OPTS} ${DB_SSH_USER}@${DB_HOST} "ps -ef | grep ora_pmon | grep -v grep" 2>/dev/null | awk '{print $NF}' | sed 's/ora_pmon_//')
            check_pass "Oracle Database (${DB_NAME})"
        else
            check_fail "Oracle Database (ora_pmon)"
        fi

        # Listener
        LSNR_INFO=$(ssh ${SSH_OPTS} ${DB_SSH_USER}@${DB_HOST} "ps -ef | grep tnslsnr | grep -v grep" 2>/dev/null | awk '{print $9}')
        if [[ -n "$LSNR_INFO" ]]; then
            check_pass "DB Listener (${LSNR_INFO})"
        else
            check_warn "DB Listener (may be Grid Infrastructure managed)"
        fi
    else
        check_warn "Cannot reach DB server via SSH"
        check_warn "DB Listener status unknown"
    fi
else
    echo -e "  ${YELLOW}⚠ SKIPPED${NC}  Database checks skipped (--skip-db)"
fi

# --- Application ---
echo ""
echo -e "${BOLD}  Application Server ($(hostname))${NC}"
echo -e "  ${DIM}────────────────────────────────────────${NC}"

# WebLogic Admin Server
if ps -ef | grep -q "[w]eblogic.Server.*AdminServer" 2>/dev/null; then
    check_pass "WebLogic Admin Server"
elif ps -ef | grep -q "[w]eblogic.Server" 2>/dev/null; then
    check_pass "WebLogic Server (managed servers detected)"
else
    check_fail "WebLogic Server"
fi

# OHS / HTTP Server
if ps -ef | grep -q "[h]ttpd" 2>/dev/null; then
    check_pass "Oracle HTTP Server (OHS)"
else
    check_fail "Oracle HTTP Server (OHS)"
fi

# Node Manager
if ps -ef | grep -q "[N]odeManager" 2>/dev/null; then
    check_pass "Node Manager"
else
    check_fail "Node Manager"
fi

# Concurrent Manager
if ps -ef | grep -q "[F]NDLIBR" 2>/dev/null; then
    check_pass "Concurrent Manager (FNDLIBR)"
else
    check_fail "Concurrent Manager (FNDLIBR)"
fi

# Forms Server
if ps -ef | grep -q "[f]orms_server\|[d]_frd" 2>/dev/null; then
    check_pass "Forms Server"
else
    check_fail "Forms Server"
fi

# OAFM Server
if ps -ef | grep -q "[o]afm_server" 2>/dev/null; then
    check_pass "OAFM Server"
else
    check_fail "OAFM Server"
fi

# OACore Server
if ps -ef | grep -q "[o]acore_server" 2>/dev/null; then
    check_pass "OACore Server"
else
    check_fail "OACore Server"
fi

# Apps Listener
if ps -ef | grep -q "[t]nslsnr.*APPS_" 2>/dev/null; then
    check_pass "Apps Listener (APPS_UAT)"
else
    check_fail "Apps Listener"
fi

# OPMN
if ps -ef | grep -q "[o]pmn" 2>/dev/null; then
    check_pass "OPMN"
else
    check_fail "OPMN"
fi

# applmgr process count
APP_PROC_COUNT=$(ps -u ${APP_USER} -o pid= 2>/dev/null | wc -l)

#──────────────────────────────────────────────────────────────────────────────
# SUMMARY
#──────────────────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}${CYAN}════════════════════════════════════════════════════════════════${NC}"

TOTAL=$((UP + DOWN))
if ((DOWN == 0 && UP > 0)); then
    echo -e "  ${BOLD}${GREEN}Status: EBS SYSTEM IS RUNNING${NC}"
elif ((UP == 0)); then
    echo -e "  ${BOLD}${RED}Status: EBS SYSTEM IS STOPPED${NC}"
else
    echo -e "  ${BOLD}${YELLOW}Status: EBS SYSTEM IS PARTIALLY RUNNING${NC}"
fi

echo -e "  ${GREEN}${UP} running${NC}  |  ${RED}${DOWN} stopped${NC}  |  ${YELLOW}${WARN} unknown${NC}  |  ${DIM}${APP_PROC_COUNT} applmgr processes${NC}"
echo -e "${BOLD}${CYAN}════════════════════════════════════════════════════════════════${NC}"
echo ""
