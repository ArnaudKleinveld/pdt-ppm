# PDT Claude functions

claude-pdt-refresh-reference() {
  # local tool="${1:?Usage: claude-pdt-refresh-reference <tool-name>}"
  local pdt_dir="$(hub list --path obsidian)/pdt"
  
  # (cd "$pdt_dir" && claude --print "/refresh-reference $tool")
  (cd "$pdt_dir" && claude)
}
