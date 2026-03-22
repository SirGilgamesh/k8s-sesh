# k8s-sesh

Isolated Kubernetes cluster sessions for zsh. Spawn subshells with scoped kubeconfig and AWS profile — no more accidental cross-cluster operations.

## Features

- **Isolated sessions**: Each cluster session runs in its own subshell with a dedicated kubeconfig
- **AWS profile coupling**: Optionally bind AWS profiles to clusters for seamless EKS authentication
- **Clean exit**: Temp kubeconfigs are automatically cleaned up when you exit
- **Dynamic prompt**: Shows current context, namespace, AWS profile, and region
- **No dependencies**: Just kubectl and zsh

## Installation

```bash
git clone https://github.com/SirGilgamesh/k8s-sesh ~/.k8s-sesh
echo 'source ~/.k8s-sesh/k8s-sesh.zsh' >> ~/.zshrc
source ~/.zshrc
```

To update:
```bash
cd ~/.k8s-sesh && git pull
```

## Quick Start

```bash
# Register your existing kubectl contexts
k sync

# Spawn an isolated session
k dev

# You're now in an isolated subshell
# Your prompt shows: (ctx:dev | ns:default) | aws:dev-profile | us-east-1)

# Switch namespace
k n kube-system

# Exit the session (cleanup is automatic)
exit
```

## Configuration

Aliases are stored in `~/.k8s-sesh/cluster-aliases`:

```
# Format: alias=context|aws-profile
dev=user@dev-cluster.us-east-1.eksctl.io|dev-profile
staging=user@staging-cluster.eu-west-1.eksctl.io|staging-profile

# Without AWS profile coupling:
local=docker-desktop
```

## Commands

### Sessions

| Command | Description |
|---------|-------------|
| `k <env>` | Spawn isolated shell for a cluster |
| `k <kubectl args>` | Pass through to kubectl (e.g., `k get pods`) |
| `k n <namespace>` | Switch namespace in current session |
| `k n -` | Return to previous namespace |
| `k info` | Show current context and namespace |

### Alias Management

| Command | Description |
|---------|-------------|
| `k add <alias> <context> [profile]` | Add a cluster alias |
| `k rm <alias>` | Remove a cluster alias |
| `k sync` | Interactively register unregistered kubectl contexts |

### Info

| Command | Description |
|---------|-------------|
| `k` | List available environments |
| `k help` | Show all commands |

## How It Works

1. `k <env>` looks up the alias in the config file
2. Extracts the context into a temp kubeconfig via `kubectl config view --raw --minify`
3. Spawns a new zsh subshell with `KUBECONFIG` pointing to the temp file
4. Sets `AWS_PROFILE` and `AWS_DEFAULT_REGION` if configured
5. On `exit`, a trap cleans up the temp kubeconfig

The parent shell remains untouched — you can have multiple isolated sessions running simultaneously.

## License

MIT
