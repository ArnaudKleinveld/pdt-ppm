# packages/pim/tests/build_show.bats
# Tests for `pim build show PROFILE`

setup() {
  load './pim'
}

@test "build show fails for nonexistent profile" {
  run "$PIM_CMD" build show nonexistent --arch arm64
  [ "$status" -eq 1 ]
  [[ "$output" == *"No image found"* ]]
}

@test "build show displays image details for default profile" {
  run "$PIM_CMD" build show default
  [ "$status" -eq 0 ]
  [[ "$output" == *"Image:"* ]]
  [[ "$output" == *"Path:"* ]]
  [[ "$output" == *"Cache key:"* ]]
  [[ "$output" == *"Built:"* ]]
}
