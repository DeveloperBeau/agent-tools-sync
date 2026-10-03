#!/usr/bin/env bash

setup_context7() {
  section "context7"
  local available failed=0 agent
  mcp_setup_available; available=$?
  [ "$available" -ne 1 ] || return 0
  [ "$available" -eq 0 ] || return 1
  for agent in claude codex; do
    mcp_ensure "$agent" context7 http https://mcp.context7.com/mcp || failed=1
  done
  return "$failed"
}
