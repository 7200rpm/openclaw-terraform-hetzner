#!/bin/bash

create_release_config_worktree() {
  local repo_dir="$1"
  local commit="$2"

  if [[ -z "$repo_dir" || -z "$commit" ]]; then
    echo "Error: create_release_config_worktree requires repo_dir and commit"
    return 1
  fi

  git -C "$repo_dir" fetch --all --tags >/dev/null 2>&1 || true

  RELEASE_WORKTREE_ROOT="$(mktemp -d)"
  RELEASE_CONFIG_DIR="$RELEASE_WORKTREE_ROOT/config"

  git -C "$repo_dir" worktree add --detach "$RELEASE_CONFIG_DIR" "$commit" >/dev/null
}

cleanup_release_config_worktree() {
  local repo_dir="$1"

  if [[ -n "${RELEASE_CONFIG_DIR:-}" && -d "${RELEASE_CONFIG_DIR}" ]]; then
    git -C "$repo_dir" worktree remove --force "$RELEASE_CONFIG_DIR" >/dev/null 2>&1 || true
  fi

  if [[ -n "${RELEASE_WORKTREE_ROOT:-}" && -d "${RELEASE_WORKTREE_ROOT}" ]]; then
    rm -rf "$RELEASE_WORKTREE_ROOT"
  fi
}

upsert_env_file_value() {
  local file="$1"
  local key="$2"
  local value="$3"
  local escaped_value=""

  if [[ ! -f "$file" ]]; then
    echo "Error: Env file not found: $file"
    return 1
  fi

  escaped_value=$(printf '%s' "$value" | sed 's/[&/\\]/\\&/g')

  if grep -q "^${key}=" "$file"; then
    sed -i.bak "s/^${key}=.*/${key}=${escaped_value}/" "$file"
    rm -f "$file.bak"
  else
    printf "%s=%s\n" "$key" "$value" >> "$file"
  fi
}

wait_for_remote_health() {
  local host="$1"
  local url="$2"
  local attempts="$3"
  local delay_seconds="$4"
  local ssh_user="${5:-openclaw}"

  local attempt
  for attempt in $(seq 1 "$attempts"); do
    if ssh -o StrictHostKeyChecking=accept-new "${ssh_user}@${host}" \
      "curl -sf ${url} >/dev/null 2>&1"; then
      return 0
    fi

    if [[ "$attempt" -lt "$attempts" ]]; then
      sleep "$delay_seconds"
    fi
  done

  return 1
}

wait_for_remote_command() {
  local host="$1"
  local command="$2"
  local attempts="$3"
  local delay_seconds="$4"
  local ssh_user="${5:-openclaw}"

  local attempt
  for attempt in $(seq 1 "$attempts"); do
    if ssh -o StrictHostKeyChecking=accept-new "${ssh_user}@${host}" \
      "$command"; then
      return 0
    fi

    if [[ "$attempt" -lt "$attempts" ]]; then
      sleep "$delay_seconds"
    fi
  done

  return 1
}
