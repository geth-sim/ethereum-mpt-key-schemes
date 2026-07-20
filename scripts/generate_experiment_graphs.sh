#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=common.sh
source "$(dirname "$0")/common.sh"

usage() {
  cat <<'EOF'
Usage:
  ./scripts/generate_experiment_graphs.sh E1 <validation|paper> [output-dir]
  ./scripts/generate_experiment_graphs.sh E3 <validation|paper> [output-dir]
  ./scripts/generate_experiment_graphs.sh E4 <validation|paper> [output-dir]
  ./scripts/generate_experiment_graphs.sh E5 <validation|paper> [output-dir]
  ./scripts/generate_experiment_graphs.sh E6 <validation|paper> [output-dir]
  ./scripts/generate_experiment_graphs.sh E7 <validation|paper> [output-dir]

E2 rewrites databases and does not produce block-execution graphs.
Override the defaults with ANALYSIS_START_BLOCK and ANALYSIS_WINDOW.
EOF
}

experiment="${1:-}"
profile="${2:-}"
[[ "$experiment" =~ ^E[1-7]$ ]] || { usage; exit 2; }
[[ "$experiment" != "E2" ]] || die "E2 has no block-execution graph family"
[[ "$profile" == "validation" || "$profile" == "paper" ]] || { usage; exit 2; }

paper_root="$RUNTIME_DIR/paper-experiments/$profile"
experiment_report="$paper_root/$experiment/run-report.json"
output_root="${3:-$paper_root/$experiment/graphs}"

[[ -f "$experiment_report" ]] ||
  die "experiment report not found: $experiment_report"

if [[ "$profile" == "paper" ]]; then
  start_block="${ANALYSIS_START_BLOCK:-5000000}"
  window="${ANALYSIS_WINDOW:-100000}"
else
  start_block="${ANALYSIS_START_BLOCK:-0}"
  window="${ANALYSIS_WINDOW:-10000}"
fi

report_has_case() {
  local report="$1"
  local case_id="$2"
  jq -e --arg case_id "$case_id" \
    '[.cases[] | (.case_id // .manifest_case.id)] | index($case_id) != null' \
    "$report" >/dev/null
}

resolve_case_report() {
  local case_id="$1"
  local family="${case_id%%_*}"
  local combined="$paper_root/$family/run-report.json"
  local individual="$paper_root/$family/run-report_${case_id}.json"
  if [[ -f "$combined" ]] && report_has_case "$combined" "$case_id"; then
    printf '%s\n' "$combined"
  elif [[ -f "$individual" ]] && report_has_case "$individual" "$case_id"; then
    printf '%s\n' "$individual"
  else
    die "no run report contains case $case_id"
  fi
}

generate_cases() {
  local output_dir="$1"
  shift
  local -a case_specs=("$@")
  local -a reports=()
  local -a case_args=()
  local spec case_id report existing

  for spec in "${case_specs[@]}"; do
    case_id="${spec%%=*}"
    report="$(resolve_case_report "$case_id")"
    existing=false
    for candidate in "${reports[@]}"; do
      if [[ "$candidate" == "$report" ]]; then
        existing=true
        break
      fi
    done
    [[ "$existing" == "true" ]] || reports+=("$report")
    case_args+=(--case "$spec")
  done

  local primary_report="${reports[0]}"
  local -a extra_reports=()
  for report in "${reports[@]:1}"; do
    extra_reports+=(--suite-report "$report")
  done
  "$ROOT_DIR/scripts/generate_graphs.sh" \
    "$primary_report" "$output_dir" \
    --start-block "$start_block" --window "$window" \
    "${extra_reports[@]}" "${case_args[@]}"
}

case "$experiment" in
  E1)
    generate_cases "$output_root" \
      'E1_H=H' 'E1_P=P' 'E1_PH=PH' 'E1_PV=PV' \
      'E1_PVstar=PV*' 'E1_VH=VH' 'E1_VP=VP' 'E1_VPstar=VP*'
    ;;
  E3)
    generate_cases "$output_root" \
      'E1_H=H' \
      'E1_PVstar=PV*' \
      'E3_PVstar_myhash=PV* myHash' \
      'E3_PVstar_myhash_cache4g_unified=PV* myHash cache 4GiB' \
      'E1_VPstar=VP*' \
      'E3_VPstar_myhash=VP* myHash' \
      'E3_VPstar_myhash_cache4g_unified=VP* myHash cache 4GiB'
    ;;
  E4)
    generate_cases "$output_root" \
      'E1_H=H' \
      'E1_PVstar=PV*' \
      'E4_PVstar_padding=PV* no Snappy' \
      'E1_VPstar=VP*' \
      'E4_VPstar_padding=VP* no Snappy'
    ;;
  E5)
    generate_cases "$output_root" \
      'E1_H=H' \
      'E1_VH=VH 4B' \
      'E5_VH_20bit=VH 2.5B' \
      'E5_VH_16bit=VH 2B'
    ;;
  E6)
    # All PebbleDB configurations.
    generate_cases "$output_root/pebble-overview" \
      'E6_H_pebble_snappy=H Pebble Snappy' \
      'E6_H_pebble_zstd=H Pebble zstd' \
      'E6_PVstar_pebble_snappy=PV* Pebble Snappy' \
      'E6_PVstar_pebble_zstd=PV* Pebble zstd' \
      'E6_VPstar_pebble_snappy=VP* Pebble Snappy' \
      'E6_VPstar_pebble_zstd=VP* Pebble zstd'

    # Speedup relative to the matching H for each compression.
    generate_cases "$output_root/pebble-snappy" \
      'E6_H_pebble_snappy=H Pebble Snappy' \
      'E6_PVstar_pebble_snappy=PV* Pebble Snappy' \
      'E6_VPstar_pebble_snappy=VP* Pebble Snappy'
    generate_cases "$output_root/pebble-zstd" \
      'E6_H_pebble_zstd=H Pebble zstd' \
      'E6_PVstar_pebble_zstd=PV* Pebble zstd' \
      'E6_VPstar_pebble_zstd=VP* Pebble zstd'

    # Compare each scheme across backend/compression choices.
    generate_cases "$output_root/h-backend-compression" \
      'E1_H=H LevelDB Snappy' \
      'E6_H_pebble_snappy=H Pebble Snappy' \
      'E6_H_pebble_zstd=H Pebble zstd'
    generate_cases "$output_root/pvstar-backend-compression" \
      'E1_PVstar=PV* LevelDB Snappy' \
      'E6_PVstar_pebble_snappy=PV* Pebble Snappy' \
      'E6_PVstar_pebble_zstd=PV* Pebble zstd'
    generate_cases "$output_root/vpstar-backend-compression" \
      'E1_VPstar=VP* LevelDB Snappy' \
      'E6_VPstar_pebble_snappy=VP* Pebble Snappy' \
      'E6_VPstar_pebble_zstd=VP* Pebble zstd'
    ;;
  E7)
    # Non-archive comparisons use the non-archive H case as their baseline.
    generate_cases "$output_root" \
      'E7_H_nonarchive=H' \
      'E7_PVstar_nonarchive=PV*' \
      'E7_VPstar_nonarchive=VP*'
    ;;
esac

echo "$experiment graph generation: PASS"
echo "Graphs: $output_root"
