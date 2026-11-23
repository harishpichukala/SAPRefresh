#!/bin/bash
#------------------------------------------------------------------------------
# sap_refresh_tables.sh - non-interactive R3trans export/import for system refresh
#
# Usage (as <sid>adm, SAP system must be running and R3trans must connect):
#   ./sap_refresh_tables.sh export [-d DIR] [-g group1,group2,...]
#   ./sap_refresh_tables.sh import [-d DIR] [-g group1,group2,...]
#   ./sap_refresh_tables.sh list
#   ./sap_refresh_tables.sh sec-backup [-d DIR] [-s SECDIR]   # tar of the sec folder (PSEs, SNC files)
#   ./sap_refresh_tables.sh sec-restore [-d DIR] [-s SECDIR]  # restores it, keeps old copy as <sec>.pre_restore_<ts>
#
# Groups: rfc secstore strust logon profile ale opmode wf bw   (default: all)
#
# Extra tables without editing the script (e.g. from SCTC_LIST_TABLES):
#   EXTRA_rfc="ZMYTAB1 ZMYTAB2" ./sap_refresh_tables.sh export ...
#
# Exit code: 0 = all OK, 1 = at least one group failed, 2 = usage/precheck error
# No prompts. Everything goes to $DIR/log/. Review WARN lines before go-live.
#
# Table lists are community-sourced; run SCTC_LIST_TABLES on your release and
# diff against them. Tables in *_OPT are exported one by one and skipped if
# they do not exist on your release.
#------------------------------------------------------------------------------
set -u

DIR_DEFAULT="/usr/sap/trans/refresh_${SAPSYSTEMNAME:-SID}"
ALL_GROUPS="rfc secstore strust logon profile ale opmode wf bw"

# --- group definitions --------------------------------------------------------
# SM59 + SMT1/SMT2 (trust relations live in RFCSYSACL / RFCTRUST)
rfc_CORE="RFCDES RFCDOC RFCATTRIB RFCDESSECU RFCCHECK RFCSYSACL RFCTRUST"
rfc_OPT="RFCCMC RFCGO RFCSTXTAB RFCLIST RFCTA LOGIC_DEST QSENDDEST QIWKTAB MQDES"
# Secure store: SM59 passwords AND SPNEGO keytab (/SPNEGO/KEYTAB/*) - keep as one set
secstore_CORE="RSECTAB RSECACHK RSECACTB"
secstore_OPT=""
# STRUST
strust_CORE="SSF_PSE_D SSF_PSE_H SSFAPPLIC SSFAPPLICT"
strust_OPT="SSF_PSE_L SSF_PSE_T TWPSSO2ACL"
# SMLG (logon groups) + RZ12 (RFC server groups)
logon_CORE="RZLLITAB RZLLICLASS"
logon_OPT=""
# RZ10 (profile versions kept in the DB; OS profile files are NOT covered)
profile_CORE="TPFET TPFHT TPFID"
profile_OPT=""
# WE20/WE21 + BD54 (needed around BDLS)
ale_CORE="EDPP1 EDP12 EDP13 EDP21 EDIPOA EDIPORT TBDLS TBDLST"
ale_OPT="EDIPOD TBD05 TBD06 TBDBR TBDBRF"
# RZ04 operation modes / instance definitions (TPFBA = operation modes).
# Related instance/timetable tables: look them up via SCTC_LIST_TABLES and add via EXTRA_opmode.
opmode_CORE="TPFBA"
opmode_OPT=""
# SAP Business Workflow configuration: event type linkage + activation.
# Task/agent assignments and org data (HRP*) are not included - see notes.
wf_CORE="SWETYPECOU SWETYPEENA"
wf_OPT="SWEINSTCOU"
# RSA1 (BW / embedded BW) source-system and logical-system mapping
bw_CORE=""
bw_OPT="RSADMINA RSBASIDOC RSLOGSYSDEST RSLOGSYSMAP RSPOR_T_PORTAL"

# --- helpers --------------------------------------------------------------------
log()  { echo "$(date '+%F %T') $*" | tee -a "$LOGDIR/run.log"; }
die()  { echo "ERROR: $*" >&2; exit 2; }

usage() { sed -n '2,16p' "$0"; exit 2; }

[ $# -ge 1 ] || usage
MODE="$1"; shift
DIR="$DIR_DEFAULT"; GROUPS_SEL="$ALL_GROUPS"
SECDIR_OPT=""
while getopts "d:g:s:" o; do
  case "$o" in
    d) DIR="$OPTARG" ;;
    g) GROUPS_SEL="${OPTARG//,/ }" ;;
    s) SECDIR_OPT="$OPTARG" ;;
    *) usage ;;
  esac
done

if [ "$MODE" = "list" ]; then
  for g in $ALL_GROUPS; do
    c="${g}_CORE"; p="${g}_OPT"
    echo "[$g] core: ${!c}"
    echo "[$g] opt : ${!p}"
  done
  exit 0
fi
case "$MODE" in export|import|sec-backup|sec-restore) ;; *) usage ;; esac

LOGDIR="$DIR/log"; CTLDIR="$DIR/ctl"; DUMPDIR="$DIR/dump"
mkdir -p "$LOGDIR" "$CTLDIR" "$DUMPDIR" || die "cannot create $DIR"

# --- sec folder backup/restore (file-based PSEs: SNC / SSO 3.0, SAPSSLS etc.) ---
if [ "$MODE" = "sec-backup" ] || [ "$MODE" = "sec-restore" ]; then
  SEC="${SECDIR_OPT:-${SECUDIR:-${DIR_INSTANCE:-}/sec}}"
  [ -n "$SEC" ] && [ -d "$SEC" ] || [ "$MODE" = "sec-restore" ] || die "sec folder not found: '$SEC' (use -s)"
  TARBALL="$DIR/sec_$(basename "$(dirname "$SEC")").tar.gz"
  if [ "$MODE" = "sec-backup" ]; then
    tar -C "$(dirname "$SEC")" -czpf "$TARBALL" "$(basename "$SEC")" || die "tar failed"
    log "OK    sec backup $SEC -> $TARBALL"; exit 0
  else
    [ -f "$TARBALL" ] || die "no backup $TARBALL"
    if [ -d "$SEC" ]; then mv "$SEC" "${SEC}.pre_restore_$(date +%Y%m%d%H%M%S)" || die "cannot move old sec"; fi
    tar -C "$(dirname "$SEC")" -xzpf "$TARBALL" || die "untar failed"
    log "OK    sec restore $TARBALL -> $SEC"; exit 0
  fi
fi

# --- prechecks ------------------------------------------------------------------
command -v R3trans >/dev/null 2>&1 || die "R3trans not in PATH (run as <sid>adm)"
if [ -n "${SAPSYSTEMNAME:-}" ]; then
  exp_user="$(echo "$SAPSYSTEMNAME" | tr 'A-Z' 'a-z')adm"
  [ "$(id -un)" = "$exp_user" ] || die "run as $exp_user"
fi
R3trans -d -w "$LOGDIR/connect_check.log" >/dev/null 2>&1
rc=$?
[ $rc -le 4 ] || die "R3trans -d failed (rc=$rc), see $LOGDIR/connect_check.log"

# --- core operations --------------------------------------------------------------
write_ctl() {  # $1=ctlfile $2=dumpfile  $3...=tables
  local ctl="$1" dump="$2"; shift 2
  {
    echo "export"
    echo "client=all"
    echo "file='$dump'"
    for t in "$@"; do
      # 'delete from' is carried into the dump and clears the target rows on import
      echo "delete from $t"
      echo "select * from $t"
    done
  } > "$ctl"
}

run_export_set() {  # $1=name $2=ctl $3=dump $4=log
  R3trans -w "$4" "$2" >/dev/null 2>&1
  return $?
}

do_export() {
  local g="$1" c="${1}_CORE" p="${1}_OPT" rc fail=0 t
  local x="EXTRA_${1}"
  local core="${!c}" opt="${!p} ${!x:-}"
  rm -f "$DUMPDIR/$g".*.dump 2>/dev/null
  if [ -n "$core" ]; then
    write_ctl "$CTLDIR/$g.core.exp.ctl" "$DUMPDIR/$g.core.dump" $core
    run_export_set "$g.core" "$CTLDIR/$g.core.exp.ctl" "$DUMPDIR/$g.core.dump" "$LOGDIR/$g.core.exp.log"
    rc=$?
    if [ $rc -gt 4 ]; then log "FAIL  export $g core rc=$rc (see $LOGDIR/$g.core.exp.log)"; fail=1
    elif [ $rc -eq 4 ]; then log "WARN  export $g core rc=4 (check log)"
    else log "OK    export $g core"; fi
  fi
  for t in $opt; do
    write_ctl "$CTLDIR/$g.$t.exp.ctl" "$DUMPDIR/$g.$t.dump" "$t"
    run_export_set "$g.$t" "$CTLDIR/$g.$t.exp.ctl" "$DUMPDIR/$g.$t.dump" "$LOGDIR/$g.$t.exp.log"
    rc=$?
    if [ $rc -gt 4 ]; then
      rm -f "$DUMPDIR/$g.$t.dump"
      log "SKIP  export $g optional table $t rc=$rc (table missing on this release?)"
    else log "OK    export $g optional table $t"; fi
  done
  return $fail
}

do_import() {
  local g="$1" f rc fail=0 n=0
  for f in "$DUMPDIR/$g".*.dump; do
    [ -f "$f" ] || continue
    n=$((n+1))
    R3trans -w "$LOGDIR/$(basename "$f" .dump).imp.log" -i "$f" >/dev/null 2>&1
    rc=$?
    if [ $rc -gt 4 ]; then log "FAIL  import $(basename "$f") rc=$rc"; fail=1
    elif [ $rc -eq 4 ]; then log "WARN  import $(basename "$f") rc=4 (check log)"
    else log "OK    import $(basename "$f")"; fi
  done
  [ $n -gt 0 ] || { log "FAIL  import $g: no dump files in $DUMPDIR"; fail=1; }
  return $fail
}

overall=0
for g in $GROUPS_SEL; do
  case " $ALL_GROUPS " in *" $g "*) ;; *) die "unknown group: $g" ;; esac
  log "=== $MODE $g ==="
  if [ "$MODE" = "export" ]; then do_export "$g" || overall=1
  else do_import "$g" || overall=1; fi
done
log "finished $MODE, overall=$overall"
exit $overall
