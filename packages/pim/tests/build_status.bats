# packages/pim/tests/build_status.bats
# Tests for `pim build status`

setup() {
  load './pim'
}

@test "build status shows Host architecture" {
  run "$PIM_CMD" build status
  [ "$status" -eq 0 ]
  [[ "$output" == *"Host architecture:"* ]]
}

@test "build status shows Image directory" {
  run "$PIM_CMD" build status
  [ "$status" -eq 0 ]
  [[ "$output" == *"Image directory:"* ]]
}

@test "build status shows Disk size 20G from defaults" {
  run "$PIM_CMD" build status
  [ "$status" -eq 0 ]
  [[ "$output" == *"Disk size:"*"20G"* ]]
}

@test "build status shows Memory" {
  run "$PIM_CMD" build status
  [ "$status" -eq 0 ]
  [[ "$output" == *"Memory:"*"MB"* ]]
}

@test "build status shows CPUs" {
  run "$PIM_CMD" build status
  [ "$status" -eq 0 ]
  [[ "$output" == *"CPUs:"* ]]
}

@test "build status shows Builders section with arm64" {
  run "$PIM_CMD" build status
  [ "$status" -eq 0 ]
  [[ "$output" == *"Builders:"* ]]
  [[ "$output" == *"arm64:"* ]]
}

@test "build status shows Builders section with x86_64" {
  run "$PIM_CMD" build status
  [ "$status" -eq 0 ]
  [[ "$output" == *"x86_64:"* ]]
}

@test "build status shows Cached images count" {
  run "$PIM_CMD" build status
  [ "$status" -eq 0 ]
  [[ "$output" == *"Cached images:"* ]]
}
