# ==============================================================================
# K8s-Sesh: A simple Zsh script for managing isolated EKS cluster sessions with kube context and AWS profile scoping.
# ==============================================================================
#
# Provides isolated EKS cluster sessions with scoped kube context and AWS profile.
# Spawns subshells with isolated KUBECONFIG via temp files, preventing accidental
# cross-cluster operations. No external dependencies beyond kubectl and zsh.
#
# How it works:
#   1. `ks <env>` looks up the alias in ~/.k8s-sesh/cluster-aliases
#   2. Extracts that context into a temp kubeconfig via `kubectl config view --raw --minify`
#   3. Extracts AWS region from EKS server URL (e.g., xxx.us-east-1.eks.amazonaws.com)
#   4. Exports __K_AWS_PROFILE, __K_AWS_REGION, and __K_KUBECONFIG as temp env vars
#   5. Spawns a new zsh subshell. The new zsh sources ~/.zshrc, which sources this file.
#      The block below detects the temp vars and sets KUBECONFIG, AWS_PROFILE,
#      AWS_DEFAULT_REGION, and the prompt
#   6. On `exit`, a trap cleans up the temp kubeconfig and the parent shell is untouched
#
# Config file: ~/.k8s-sesh/cluster-aliases
#   Format: alias=context|aws-profile  (coupled, sets AWS_PROFILE)
#           alias=context              (decoupled, AWS_PROFILE unchanged)
#   Example: dev=user@cluster.us-east-1.eksctl.io|dev
#
# Commands:
#   Sessions:
#     ks <env>             Spawn isolated shell for a cluster
#     ks n <namespace>     Switch namespace in current session
#     ks info              Show current context and namespace
#
#   Alias management:
#     ks add <a> <c> [p]   Add alias (a=alias, c=context, p=optional AWS profile)
#     ks rm <alias>        Remove a cluster alias
#     ks sync              Interactively register unregistered kubectl contexts
#
#   Info:
#     ks                   List available environments
#     ks help              Show all commands
#
#   Kubectl:
#     k                    Alias for kubectl (e.g. k get pods)
# ==============================================================================

# Step 4: When the subshell starts, zsh sources this file. If __K_KUBECONFIG is set
# (from step 3), apply it along with AWS profile/region and update the prompt.
# __K_SESSION=1 prevents the default AWS profile from overwriting it later in ~/.zshrc.
# A trap ensures the temp kubeconfig is deleted when the session exits.
if [ -n "$__K_KUBECONFIG" ]; then
  export KUBECONFIG="$__K_KUBECONFIG"
  export __K_SESSION=1

  # Clean up temp kubeconfig on exit
  trap "rm -f '$__K_KUBECONFIG'" EXIT

  # Set AWS profile/region
  if [ -n "$__K_AWS_PROFILE" ]; then
    export AWS_PROFILE="$__K_AWS_PROFILE"
    export AWS_DEFAULT_PROFILE="$__K_AWS_PROFILE"
  fi
  if [ -n "$__K_AWS_REGION" ]; then
    export AWS_DEFAULT_REGION="$__K_AWS_REGION"
  fi

  # Dynamic prompt — namespace updates after `k n`
  export __K_PROMPT_ENV="$__K_ENV"
  _k_prompt_prefix() {
    local ns
    ns=$(kubectl config view --minify -o jsonpath='{..namespace}' 2>/dev/null)
    local c="%F{cyan}" y="%F{yellow}" g="%F{green}" m="%F{magenta}" r="%f"
    local p="(${c}ctx:${__K_PROMPT_ENV}${r} | ${y}ns:${ns:-default}${r})"
    [ -n "$AWS_PROFILE" ] && p="${p} | ${g}aws:${AWS_PROFILE}${r}"
    [ -n "$AWS_DEFAULT_REGION" ] && p="${p} | ${m}${AWS_DEFAULT_REGION}${r}"
    echo "${p}"
  }
  PROMPT='$(_k_prompt_prefix) '$PROMPT

  unset __K_KUBECONFIG __K_AWS_PROFILE __K_AWS_REGION __K_ENV
fi

KUBE_ALIAS_FILE="$HOME/.k8s-sesh/cluster-aliases"

# Warn if global current-context is set outside a session
if [ -z "$__K_SESSION" ]; then
  _k_global_ctx=$(KUBECONFIG="$HOME/.kube/config" kubectl config current-context 2>/dev/null)
  if [ -n "$_k_global_ctx" ]; then
    echo "Warning: Global kubectl context is set to '$_k_global_ctx'." >&2
    echo "Run 'ks clear' to clear it, or 'ks <env>' to start a scoped session." >&2
  fi
  unset _k_global_ctx
fi

# Prints available environments from the config file
_k_list() {
  echo "Available environments:"
  while IFS='=' read -r a entry; do
    local c="${entry%%|*}"
    local p="${entry#*|}"
    if [ "$p" = "$entry" ]; then
      printf "  %-20s → %s\n" "$a" "$c"
    else
      printf "  %-20s → %s (AWS: %s)\n" "$a" "$c" "$p"
    fi
  done < "$KUBE_ALIAS_FILE"
}

# Spawn an isolated session for the given cluster alias
_k_session() {
  local env="$1"
  local entry
  entry=$(grep "^${env}=" "$KUBE_ALIAS_FILE" | cut -d'=' -f2-)
  if [ -z "$entry" ]; then
    return 1
  fi
  local ctx="${entry%%|*}"
  local profile="${entry#*|}"

  # Extract context into a temp kubeconfig
  # Always read from the global kubeconfig so nested sessions work
  local tmpkubeconfig
  tmpkubeconfig=$(mktemp /tmp/k8s-sesh-${env}-XXXXXXXX)
  KUBECONFIG="$HOME/.kube/config" kubectl config view --raw --minify --context="$ctx" > "$tmpkubeconfig" 2>/dev/null
  if [ $? -ne 0 ] || [ ! -s "$tmpkubeconfig" ]; then
    echo "Failed to extract context: $ctx"
    rm -f "$tmpkubeconfig"
    return 1
  fi

  # Extract region from EKS server URL (e.g., https://xxx.us-east-1.eks.amazonaws.com)
  local region=""
  local server
  server=$(KUBECONFIG="$tmpkubeconfig" kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null)
  if [[ "$server" =~ \.([a-z]+-[a-z]+-[0-9]+)\.eks\.amazonaws\.com ]]; then
    region="${match[1]}"
  fi

  # Export temp vars for the subshell to pick up
  export __K_KUBECONFIG="$tmpkubeconfig"
  export __K_ENV="$env"

  local info="Spawning session → $env ($ctx)"
  [ "$profile" != "$entry" ] && info="$info [AWS_PROFILE=$profile]" && export __K_AWS_PROFILE="$profile"
  [ -n "$region" ] && info="$info [region=$region]" && export __K_AWS_REGION="$region"
  echo "$info"

  # If already in a session, clean up current and replace shell
  if [ -n "$__K_SESSION" ]; then
    rm -f "$KUBECONFIG"
    exec zsh
  else
    zsh
    unset __K_KUBECONFIG __K_AWS_PROFILE __K_AWS_REGION __K_ENV
  fi
}

# Add a new cluster alias to the config file
_k_add() {
  if [ -z "$1" ] || [ -z "$2" ]; then
    echo "Usage: ks add <alias> <context> [aws-profile]"
    echo ""
    echo "Examples:"
    echo "  ks add prod user@ctx.eksctl.io                 # decoupled (no AWS profile)"
    echo "  ks add prod user@ctx.eksctl.io production      # coupled (sets AWS_PROFILE)"
    return 1
  fi
  mkdir -p "$(dirname "$KUBE_ALIAS_FILE")"
  if grep -q "^${1}=" "$KUBE_ALIAS_FILE" 2>/dev/null; then
    echo "Alias '$1' already exists. Remove it first with 'ks rm $1'."
    return 1
  fi
  local value="$2"
  if [ -n "$3" ]; then
    value="${2}|${3}"
  fi
  echo "${1}=${value}" >> "$KUBE_ALIAS_FILE"
  echo "Added: $1 → $value"
}

# Remove a cluster alias from the config file
_k_rm() {
  if [ -z "$1" ]; then
    echo "Usage: ks rm <alias>"
    return 1
  fi
  if ! grep -q "^${1}=" "$KUBE_ALIAS_FILE" 2>/dev/null; then
    echo "Alias '$1' not found."
    return 1
  fi
  sed -i '' "/^${1}=/d" "$KUBE_ALIAS_FILE"
  echo "Removed: $1"
}

# Interactively sync kubectl contexts into cluster-aliases
_k_sync() {
  mkdir -p "$(dirname "$KUBE_ALIAS_FILE")"
  touch "$KUBE_ALIAS_FILE"

  # Offer to clear global current-context for safety
  local current_ctx
  current_ctx=$(KUBECONFIG="$HOME/.kube/config" kubectl config current-context 2>/dev/null)
  if [ -n "$current_ctx" ]; then
    echo "Current global context: $current_ctx"
    echo ""
    echo "Clear current-context from ~/.kube/config?"
    printf "This makes 'kubectl' fail unless you're in a 'ks' session. [y/N] "
    read -r clear_ctx </dev/tty
    if [[ "$clear_ctx" =~ ^[Yy]$ ]]; then
      KUBECONFIG="$HOME/.kube/config" kubectl config unset current-context >/dev/null
      echo "Global context cleared. Use 'ks <env>' to start a session."
    fi
    echo ""
  fi

  local contexts
  contexts=$(KUBECONFIG="$HOME/.kube/config" kubectl config get-contexts -o name 2>/dev/null)
  if [ -z "$contexts" ]; then
    echo "No kubectl contexts found."
    return 1
  fi
  local found=0
  while IFS= read -r ctx; do
    # Skip if this context is already in the aliases file
    if grep -q "=${ctx}" "$KUBE_ALIAS_FILE" 2>/dev/null; then
      continue
    fi
    found=1
    echo ""
    echo "Unregistered context:"
    echo "  $ctx"
    echo ""
    printf "Alias (e.g. dev, prod), 'skip', or 'done': "
    read -r alias_name </dev/tty
    if [ "$alias_name" = "done" ]; then
      break
    fi
    if [ "$alias_name" = "skip" ] || [ -z "$alias_name" ]; then
      echo "Skipped."
      continue
    fi
    if grep -q "^${alias_name}=" "$KUBE_ALIAS_FILE" 2>/dev/null; then
      echo "Alias '$alias_name' already exists. Skipping."
      continue
    fi
    # AWS profile selection using zsh select menu
    local profiles=("none" "custom" "cancel")
    if [ -f "$HOME/.aws/config" ]; then
      while IFS= read -r p; do
        profiles+=("$p")
      done < <(grep '^\[profile ' "$HOME/.aws/config" | sed 's/\[profile //;s/\]//' | sort)
    fi
    echo ""
    echo "Select AWS profile:"
    local aws_profile=""
    local cancelled=0
    select choice in "${profiles[@]}"; do
      if [ -n "$choice" ]; then
        if [ "$choice" = "cancel" ]; then
          cancelled=1
          break
        elif [ "$choice" = "none" ]; then
          aws_profile=""
          break
        elif [ "$choice" = "custom" ]; then
          printf "Enter profile name: "
          read -r aws_profile </dev/tty
          break
        else
          aws_profile="$choice"
          break
        fi
      else
        echo "Invalid selection. Try again."
      fi
    done </dev/tty
    if [ "$cancelled" -eq 1 ]; then
      echo "Cancelled."
      break
    fi
    local value="$ctx"
    if [ -n "$aws_profile" ]; then
      value="${ctx}|${aws_profile}"
    fi
    echo "${alias_name}=${value}" >> "$KUBE_ALIAS_FILE"
    echo "Added: $alias_name → $value"
  done <<< "$contexts"
  if [ "$found" -eq 0 ]; then
    echo "All contexts are already registered."
  fi
  echo ""
  echo "Current aliases:"
  _k_list
}

# Switch namespace in the current isolated session
# Use `ks n -` to return to the previous namespace
_k_ns() {
  if [ -z "$1" ]; then
    echo "Usage: ks n <namespace>"
    echo "         ks n -   (return to previous namespace)"
    return 1
  fi
  local current
  current=$(kubectl config view --minify -o jsonpath='{..namespace}' 2>/dev/null)
  current="${current:-default}"
  if [ "$1" = "-" ]; then
    if [ -z "$_K_PREV_NS" ]; then
      echo "No previous namespace."
      return 1
    fi
    echo "Switching back to namespace: $_K_PREV_NS"
    kubectl config set-context --current --namespace="$_K_PREV_NS" >/dev/null
    export _K_PREV_NS="$current"
  else
    export _K_PREV_NS="$current"
    kubectl config set-context --current --namespace="$1" >/dev/null
    echo "Switched to namespace: $1"
  fi
}

# Show current context and namespace
_k_info() {
  local ctx ns
  ctx=$(kubectl config current-context 2>/dev/null)
  ns=$(kubectl config view --minify -o jsonpath='{..namespace}' 2>/dev/null)
  echo "Context:   ${ctx:-<none>}"
  echo "Namespace: ${ns:-default}"
}

# Main entry point for session management
ks() {
  case "$1" in
    help)
      echo "K8s-Sesh"
      echo ""
      echo "Sessions:"
      echo "  ks <env>             Spawn isolated shell for a cluster"
      echo "  ks n <namespace>     Switch namespace in current session"
      echo "  ks n -               Return to previous namespace"
      echo "  ks info              Show current context and namespace"
      echo ""
      echo "Alias management:"
      echo "  ks add <a> <c> [p]   Add alias (a=alias, c=context, p=optional AWS profile)"
      echo "  ks rm <alias>        Remove a cluster alias"
      echo "  ks sync              Interactively register unregistered kubectl contexts"
      echo ""
      echo "Safety:"
      echo "  ks clear             Clear global kubectl context"
      echo ""
      echo "Info:"
      echo "  ks                   List available environments"
      echo "  ks help              Show this help"
      echo ""
      echo "Kubectl:"
      echo "  k <args>             Alias for kubectl"
      return 0
      ;;
    add)   shift; _k_add "$@"; return $? ;;
    rm)    shift; _k_rm "$@"; return $? ;;
    sync)  _k_sync; return $? ;;
    clear) KUBECONFIG="$HOME/.kube/config" kubectl config unset current-context >/dev/null && echo "Global context cleared." ; return $? ;;
    n)     shift; _k_ns "$@"; return $? ;;
    info)  _k_info; return $? ;;
  esac

  if [ ! -f "$KUBE_ALIAS_FILE" ] || [ ! -s "$KUBE_ALIAS_FILE" ]; then
    echo "No cluster aliases configured. Run 'ks sync' to register your kubectl contexts."
    return 1
  fi
  if [ -z "$1" ]; then
    echo "Usage: ks <environment>"
    echo ""
    _k_list
    echo ""
    echo "Run 'ks sync' to register new contexts or 'ks help' for all commands."
    return 0
  fi

  # Spawn session for the given alias
  if ! _k_session "$1"; then
    echo "Unknown environment: $1"
    echo "Run 'ks' to list available environments."
    return 1
  fi
}

# Kubectl alias
# Kubectl alias
alias k=kubectl
