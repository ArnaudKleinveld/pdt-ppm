# packages/pim/tests/build_list.bats
# Tests for `pim build list` and `pim build ls`

setup() {
  load './pim'
}

@test "build list succeeds" {
  run "$PIM_CMD" build list
  [ "$status" -eq 0 ]
}

@test "build ls is an alias for list" {
  run "$PIM_CMD" build ls
  [ "$status" -eq 0 ]
}

@test "build list --long shows column headers" {
  run "$PIM_CMD" build list --long
  [ "$status" -eq 0 ]
  [[ "$output" == *"PROFILE"* ]]
  [[ "$output" == *"ARCH"* ]]
}
