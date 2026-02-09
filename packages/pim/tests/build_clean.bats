# packages/pim/tests/build_clean.bats
# Tests for `pim build clean`

setup() {
  load './pim'
}

@test "build clean without flags shows usage hint" {
  run "$PIM_CMD" build clean
  [ "$status" -eq 0 ]
  [[ "$output" == *"--orphaned"* ]]
  [[ "$output" == *"--all"* ]]
}

@test "build clean --orphaned reports results" {
  run "$PIM_CMD" build clean --orphaned
  [ "$status" -eq 0 ]
  [[ "$output" == *"orphaned"* ]]
}
