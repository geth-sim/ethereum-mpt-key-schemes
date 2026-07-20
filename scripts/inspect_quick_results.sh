#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=common.sh
source "$(dirname "$0")/common.sh"

require_command jq

summary="$RUNTIME_DIR/quick-summary.json"

[[ -f "$summary" ]] || die "missing quick summary: $summary"
experiment_id="$(jq -er '.experiment_id' "$summary")"
result_dir="$SIMULATOR_WORKDIR/logFiles/evm/runs/$experiment_id/simBlocks"
result="$result_dir/evm_simulation_result_${experiment_id}_0_${TARGET_BLOCK}.json"
[[ -f "$result" ]] || die "missing result for experiment $experiment_id: $result"
final_key="$(printf '%08d' "$TARGET_BLOCK")"

inspection="$(jq -n \
  --slurpfile result "$result" \
  --slurpfile summary "$summary" \
  --arg final_key "$final_key" \
  --arg target_hash "$TARGET_HASH" \
  --argjson target_block "$TARGET_BLOCK" '
    ($result[0]) as $r |
    ($summary[0]) as $s |
    {
      blocks: ($r | length),
      final_block: $r[$final_key].Number,
      payment_transactions: ([$r[] | .PaymentTxLen // 0] | add),
      call_transactions: ([$r[] | .CallTxLen // 0] | add),
      expected_blocks: ($s.end_block - $s.start_block + 1),
      expected_transactions: $s.transactions,
      summary_start_block: $s.start_block,
      summary_end_block: $s.end_block,
      summary_target_hash: $s.target_hash,
      experiment_id: $s.experiment_id,
      configured_target_block: $target_block,
      configured_target_hash: $target_hash
    }
  ' )"

echo "Primary result: $result"
echo "Result size:    $(du -h "$result" | awk '{print $1}')"
echo "$inspection" | jq .

echo "$inspection" | jq -e '
  .blocks == .expected_blocks and
  .summary_start_block == 0 and
  .summary_end_block == .configured_target_block and
  .summary_target_hash == .configured_target_hash and
  .final_block == .configured_target_block and
  (.payment_transactions + .call_transactions) == .expected_transactions
' >/dev/null || die "result JSON does not agree with the quick summary"

echo "RESULT INSPECTION: PASS"
