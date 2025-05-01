#!/bin/bash

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Default configurations
DEFAULT_K3S_VERSION="v1.32.3+k3s1"
DEFAULT_CLUSTER_NAME="development"
DEFAULT_ARGO_VERSION="v2.14.10"
DEFAULT_ARGO_NS="argocd"
DEFAULT_ARGO_PORT="8080"
DEFAULT_ESO_VERSION="0.16.1"
DEFAULT_ESO_NS="external-secrets"
DEFAULT_ESO_NAME="external-secrets"

# Initialize variables
K3S_VERSION=$DEFAULT_K3S_VERSION
CLUSTER_NAME=$DEFAULT_CLUSTER_NAME
NODE_IP=""
ARGO_VERSION=$DEFAULT_ARGO_VERSION
ARGO_NS=$DEFAULT_ARGO_NS
ARGO_PORT=$DEFAULT_ARGO_PORT
SKIP_ARGO=false
ESO_VERSION=$DEFAULT_ESO_VERSION
ESO_NS=$DEFAULT_ESO_NS
ESO_NAME=$DEFAULT_ESO_NAME
SKIP_ESO=false
VERBOSE=false
FORCE=false
EXTERNAL_IP=""

# Dependency checks
REQUIRED_CMDS=("kubectl" "helm" "curl" "jq")
MISSING_CMDS=()

# --- Helper Functions ---

# Print usage information
usage() {
    echo -e "${BLUE}Usage: $0 [install|uninstall] [OPTIONS]${NC}"
    echo
    echo -e "${BLUE}Options:${NC}"
    echo "  --k3s-version VERSION     Specify K3s version (default: $DEFAULT_K3S_VERSION)"
    echo "  --cluster-name NAME       Specify cluster name (default: $DEFAULT_CLUSTER_NAME)"
    echo "  --node-ip IP              Specify node IP address (auto-detected if not provided)"
    echo "  --argocd-version VERSION  Specify ArgoCD version (default: $DEFAULT_ARGO_VERSION)"
    echo "  --argocd-port PORT        Specify ArgoCD dashboard port (default: $DEFAULT_ARGO_PORT)"
    echo "  --argocd-ns NAMESPACE     Specify ArgoCD namespace (default: $DEFAULT_ARGO_NS)"
    echo "  --skip-argocd             Skip ArgoCD installation"
    echo "  --eso-version VERSION     Specify ESO version (default: $DEFAULT_ESO_VERSION)"
    echo "  --eso-ns NAMESPACE        Specify ESO namespace (default: $DEFAULT_ESO_NS)"
    echo "  --eso-name NAME           Specify ESO name (default: $DEFAULT_ESO_NAME)"
    echo "  --skip-eso                Skip ESO installation"
    echo "  -v, --verbose             Enable verbose output"
    echo "  -f, --force               Skip confirmation prompts"
    echo "  -h, --help                Show this help message"
    exit 1
}

# Get preferred IP address
get_preferred_ip() {
   #curl http://checkip.amazonaws.com
    local ip
    ip=$(hostname -I | awk '{print $1}')
    echo "$ip"
}

# Convert version to v-prefix format
to_v_prefix() {
    [[ "$1" == v* ]] && echo "$1" || echo "v$1"
}

# Check if a command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Check for required dependencies
check_dependencies() {
    for cmd in "${REQUIRED_CMDS[@]}"; do
        if ! command_exists "$cmd"; then
            MISSING_CMDS+=("$cmd")
        fi
    done

    if [ ${#MISSING_CMDS[@]} -gt 0 ]; then
        echo -e "${RED}Missing dependencies: ${MISSING_CMDS[*]}${NC}"
        return 1
    fi
    return 0
}

# Install missing dependencies
install_dependencies() {
    echo -e "${YELLOW}Installing missing dependencies...${NC}"

    # Package manager detection
    if command_exists apt-get; then
        PKG_MANAGER="apt-get"
    elif command_exists yum; then
        PKG_MANAGER="yum"
    else
        echo -e "${RED}Could not detect package manager${NC}"
        return 1
    fi

    for cmd in "${MISSING_CMDS[@]}"; do
        case "$cmd" in
            kubectl)
                if ${COMMAND} == "uninstall"; then
                    echo -e "${YELLOW}kubectl not found. Aborting uninstall command${NC}"
                    return 1
                fi
                ;;
            helm)
                echo -e "${YELLOW}Installing Helm...${NC}"
                curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
                ;;
            *)
                echo -e "${YELLOW}Installing $cmd...${NC}"
                sudo $PKG_MANAGER install -y "$cmd"
                ;;
        esac
    done
}

# Check if operator is installed
is_operator_installed() {
    local ns="$1"
    local name="$2"
    local label="$3"

    kubectl get deployments -n "$ns" -l "$label" &>/dev/null
}

# Check if CRD is installed
is_crd_installed() {
    kubectl get crd "$1" >/dev/null 2>&1
}

# Get newest chart version for app version
get_chart_version_for_app_version() {
    local chart_name="$1"
    local target_app_version="$2"

    helm search repo "$chart_name" --versions --output json | \
    jq -r --arg av "$target_app_version" '
        [.[] | select(.app_version == $av) |
        {version: .version, chunks: (.version | split(".") | map(tonumber))}] |
        sort_by(.chunks) | reverse | .[0].version // empty'
}

# Parse command line arguments
parse_args() {
    if [[ $# -lt 1 ]]; then
      usage
    fi

    local cmd="$1"
    if [[ "$cmd" != "install" && "$cmd" != "uninstall"  ]]; then
        echo -e "${RED}Error: Invalid Command '$1' (install/uninstall) is required${NC}"
        usage
    fi
    while [[ $# -gt 0 ]]; do
        case "$1" in
            install|uninstall)
                COMMAND="$1"
                shift
                ;;
            --k3s-version=*)
                K3S_VERSION="${1#*=}"
                shift
                ;;
            --k3s-version)
                K3S_VERSION="$2"
                shift 2
                ;;
            --cluster-name=*)
                CLUSTER_NAME="${1#*=}"
                shift
                ;;
            --cluster-name)
                CLUSTER_NAME="$2"
                shift 2
                ;;
            --node-ip=*)
                NODE_IP="${1#*=}"
                shift
                ;;
            --node-ip)
                NODE_IP="$2"
                shift 2
                ;;
            --argocd-version=*)
                ARGO_VERSION="${1#*=}"
                ARGO_VERSION=$(to_v_prefix "$ARGO_VERSION")
                shift
                ;;
            --argocd-version)
                ARGO_VERSION=$(to_v_prefix "$2")
                shift 2
                ;;
            --argocd-port=*)
                ARGO_PORT="${1#*=}"
                if ! [[ "$ARGO_PORT" =~ ^[0-9]+$ ]]; then
                    echo -e "${RED}Error: ArgoCD port must be a number${NC}"
                    usage
                fi
                shift
                ;;
            --argocd-port)
                ARGO_PORT="$2"
                if ! [[ "$ARGO_PORT" =~ ^[0-9]+$ ]]; then
                    echo -e "${RED}Error: ArgoCD port must be a number${NC}"
                    usage
                fi
                shift 2
                ;;
            --argocd-ns=*)
                ARGO_NS="${1#*=}"
                shift
                ;;
            --argocd-ns)
                ARGO_NS="$2"
                shift 2
                ;;
            --skip-argocd)
                SKIP_ARGO=true
                shift
                ;;
            --eso-version=*)
                ESO_VERSION="${1#*=}"
                ESO_VERSION=$(to_v_prefix "$ESO_VERSION")
                shift
                ;;
            --eso-version)
                ESO_VERSION=$(to_v_prefix "$2")
                shift 2
                ;;
            --eso-ns=*)
                ESO_NS="${1#*=}"
                shift
                ;;
            --eso-ns)
                ESO_NS="$2"
                shift 2
                ;;
            --eso-name=*)
                ESO_NAME="${1#*=}"
                shift
                ;;
            --eso-name)
                ESO_NAME="$2"
                shift 2
                ;;
            --skip-eso)
                SKIP_ESO=true
                shift
                ;;
            -v|--verbose)
                VERBOSE=true
                shift
                ;;
            -f|--force)
                FORCE=true
                shift
                ;;
            -h|--help)
                usage
                ;;
            *)
                echo -e "${RED}Error: Unknown option $1${NC}"
                usage
                ;;
        esac
    done

    if [[ -z "$COMMAND" ]]; then
        echo -e "${RED}Error: Command (install/uninstall) is required${NC}"
        usage
    fi

    # Auto-detect node IP if not provided
    EXTERNAL_IP=$(curl -s ifconfig.me) || {
                echo -e "${RED}Error: Could not get external IP${NC}"
            }
    if [[ -z "$NODE_IP" ]]; then
        NODE_IP=$(get_preferred_ip)
        if [[ -z "$NODE_IP" ]]; then
            echo -e "${RED}Error: Could not auto-detect node IP. Please specify with --node-ip${NC}"
            exit 1
        fi
        echo -e "${YELLOW}Using auto-detected node IP: $NODE_IP${NC}"
    fi
}

parse_argsx() {
   if [[ $# -lt 1 ]]; then
      usage
    fi

    if [[ "$1" != "install" && "$1" != "uninstall"  ]]; then
        echo -e "${RED}Error: Invalid Command '$1' (install/uninstall) is required${NC}"
        usage
    fi

    while [[ $# -gt 0 ]]; do
        case "$1" in
            install|uninstall)
                COMMAND="$1"
                shift
                ;;
            --k3s-version=*)
                K3S_VERSION="${1#*=}"
                shift
                ;;
            --cluster-name=*)
                CLUSTER_NAME="${1#*=}"
                shift
                ;;
            --node-ip=*)
                NODE_IP="${1#*=}"
                shift
                ;;
            --argocd-version=*)
                ARGO_VERSION="${1#*=}"
                ARGO_VERSION=$(to_v_prefix "$ARGO_VERSION")
                shift
                ;;
            --argocd-port=*)
                ARGO_PORT="${1#*=}"
                if ! [[ "$ARGO_PORT" =~ ^[0-9]+$ ]]; then
                    echo -e "${RED}Error: ArgoCD port must be a number${NC}"
                    usage
                fi
                shift
                ;;
            --argocd-ns=*)
                ARGO_NS="${1#*=}"
                shift
                ;;
            --skip-argocd)
                SKIP_ARGO=true
                shift
                ;;
            --eso-version=*)
                ESO_VERSION="${1#*=}"
                ESO_VERSION=$(to_v_prefix "$ESO_VERSION")
                shift
                ;;
            --eso-ns=*)
                ESO_NS="${1#*=}"
                shift
                ;;
            --eso-name=*)
                ESO_NAME="${1#*=}"
                shift
                ;;
            --skip-eso)
                SKIP_ESO=true
                shift
                ;;
            -v|--verbose)
                VERBOSE=true
                shift
                ;;
            -f|--force)
                FORCE=true
                shift
                ;;
            -h|--help)
                usage
                ;;
            *)
                echo -e "${RED}Error: Unknown option $1${NC}"
                usage
                ;;
        esac
    done

    # Auto-detect node IP if not provided
    if [[ -z "$NODE_IP" ]]; then
        NODE_IP=$(get_preferred_ip)
        if [[ -z "$NODE_IP" ]]; then
            echo -e "${RED}Error: Could not auto-detect node IP. Please specify with --node-ip${NC}"
            exit 1
        fi
        echo -e "${YELLOW}Using auto-detected node IP: $NODE_IP${NC}"
    fi
}

# Print current configuration
print_config() {
    echo -e "${BLUE}Current Configuration:${NC}"
    echo -e "  K3s Version: ${GREEN}$K3S_VERSION${NC}"
    echo -e "  Cluster Name: ${GREEN}$CLUSTER_NAME${NC}"
    echo -e "  Node IP: ${GREEN}$NODE_IP${NC}"
    echo -e "  External IP: ${GREEN}$EXTERNAL_IP${NC}"
    if ! $SKIP_ARGO; then
        echo -e "  ArgoCD Version: ${GREEN}$ARGO_VERSION${NC}"
        echo -e "  ArgoCD Namespace: ${GREEN}$ARGO_NS${NC}"
        echo -e "  ArgoCD Port: ${GREEN}$ARGO_PORT${NC}"
    else
        echo -e "  ArgoCD: ${YELLOW}SKIPPED${NC}"
    fi
    if ! $SKIP_ESO; then
        echo -e "  ESO Version: ${GREEN}$ESO_VERSION${NC}"
        echo -e "  ESO Namespace: ${GREEN}$ESO_NS${NC}"
        echo -e "  ESO Name: ${GREEN}$ESO_NAME${NC}"
    else
        echo -e "  ESO: ${YELLOW}SKIPPED${NC}"
    fi
    echo
}

# Confirm before proceeding
confirm_action() {
    if $FORCE; then
        return 0
    fi

    print_config
    read -rp "Do you want to proceed with ${COMMAND}? [y/N] " confirm
    if [[ ! "$confirm" =~ ^[yY]$ ]]; then
        echo -e "${YELLOW}Operation cancelled${NC}"
        exit 0
    fi
}

# --- Installation Functions ---

install_k3s() {
    echo -e "${GREEN}Installing K3s cluster...${NC}"

    local install_cmd="curl -sfL https://get.k3s.io | "
    install_cmd+="INSTALL_K3S_VERSION=$K3S_VERSION "
    install_cmd+="K3S_CLUSTER_NAME=$CLUSTER_NAME "
    install_cmd+="K3S_NODE_IP=$NODE_IP "
    install_cmd+="sh -s - --write-kubeconfig-mode 644"
#    install_cmd+="sh -s - --disable traefik --write-kubeconfig-mode 644"
    #install_cmd+=" --kubelet-arg 'node-ip=$NODE_IP'"

    if $VERBOSE; then
        echo -e "${YELLOW}Running: $install_cmd${NC}"
    fi

    eval "$install_cmd"

    # Wait for K3s to be ready
    echo -e "${YELLOW}Waiting for K3s to be ready...${NC}"
    timeout 600 bash -c '
      until kubectl get nodes >/dev/null 2>&1; do
        sleep 5
      done
    '
    local k3s_status=$?
    if [[ $k3s_status -ne 0 ]]; then
        echo -e "${RED}Error: K3s did not start within the expected time${NC}"
        echo -e "${YELLOW}Please check the logs for more information and try again${NC}"
        return 1
    fi

    # Set up kubectl configuration
    mkdir -p "$HOME"/.kube
    sudo cp /etc/rancher/k3s/k3s.yaml "$HOME"/.kube/config
    sudo chown "$(id -u)":"$(id -g)" "$HOME"/.kube/config
    sed -i "s/127.0.0.1/$NODE_IP/g" "$HOME"/.kube/config

    echo -e "${GREEN}K3s cluster installed successfully!${NC}"
}

install_argocd() {
    if $SKIP_ARGO; then
        echo -e "${YELLOW}Skipping ArgoCD installation as requested${NC}"
        return 0
    fi

    echo -e "${GREEN}Installing ArgoCD...${NC}"

    # Check for existing installation
    if is_operator_installed "$ARGO_NS" "argocd" "app.kubernetes.io/name=argocd-server"; then
        echo -e "${YELLOW}ArgoCD is already installed in namespace $ARGO_NS${NC}"
        if ! $FORCE; then
            read -rp "Do you want to upgrade? [y/N] " confirm
            [[ ! "$confirm" =~ ^[yY]$ ]] && return 0
        fi
    fi

    # Add Helm repo
    helm repo add argo https://argoproj.github.io/argo-helm
    helm repo update

    # Determine service type
    local service_type="NodePort"

    if [[ "$ARGO_PORT" -lt 30000 ]] || [[ "$ARGO_PORT" -gt 32767 ]]; then
        service_type="LoadBalancer"

        echo -e "${YELLOW}Port $ARGO_PORT is outside NodePort range, using LoadBalancer${NC}"
    fi

    # Get chart version
    local chart_version
    chart_version=$(get_chart_version_for_app_version "argo/argo-cd" "$ARGO_VERSION")
    if [[ -z "$chart_version" ]]; then
        echo -e "${RED}Error: Could not find chart version for ArgoCD $ARGO_VERSION${NC}"
        return 1
    fi

    # Install/Upgrade ArgoCD
    local install_cmd="helm upgrade --install argocd argo/argo-cd "
    install_cmd+="--namespace $ARGO_NS "
    install_cmd+="--create-namespace "
    install_cmd+="--version $chart_version "
    install_cmd+="--set server.service.type=$service_type "

    if [[ "$service_type" == "NodePort" ]]; then
        install_cmd+="--set server.service.nodePort=$ARGO_PORT"
        install_cmd+=" --set server.service.externalIPs={\"$EXTERNAL_IP\"}"
    else
        install_cmd+="--set server.service.port=$ARGO_PORT"
#        if [[ "$EXTERNAL_IP" ]]; then
#          install_cmd+=" --set server.service.externalIPs=$externalIP"
#        fi
    fi

    if $VERBOSE; then
        echo -e "${YELLOW}Running: $install_cmd${NC}"
    fi

    eval "$install_cmd" || {
        echo -e "${RED}Error installing ArgoCD${NC}"
        return 1
    }

    # Wait for ArgoCD
    echo -e "${YELLOW}Waiting for ArgoCD to be ready...${NC}"
    kubectl wait --for=condition=available deployment/argocd-server -n "$ARGO_NS" --timeout=300s

    # install argocd CLI
    install_argocd_cli

    # Get admin password
    local argocd_password
    argocd_password=$(kubectl -n "$ARGO_NS" get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d)
# kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d
    echo -e "${GREEN}ArgoCD installed successfully!${NC}"
    echo -e "${YELLOW}Dashboard URL: http://$NODE_IP:$ARGO_PORT${NC}"
    echo -e "${YELLOW}Username: admin${NC}"
    echo -e "${YELLOW}Password: $argocd_password${NC}"
}

# Function to install ArgoCD CLI
install_argocd_cli() {
  if command_exists argocd; then
    echo -e "${GREEN}ArgoCD CLI is already installed${NC}"
    return
  fi

  echo -e "${YELLOW}Installing ArgoCD CLI...${NC}"
  #curl -sSL -o argocd-linux-amd64 https://github.com/argoproj/argo-cd/releases/download/"$ARGO_VERSION"/argocd-linux-amd64
  curl -sSL -o argocd-linux-amd64 https://github.com/argoproj/argo-cd/releases/latest/download/argocd-linux-amd64
  sudo install -m 555 argocd-linux-amd64 /usr/local/bin/argocd
  rm argocd-linux-amd64
  echo -e "${GREEN}ArgoCD CLI installed successfully${NC}"
}

install_eso() {
    if $SKIP_ESO; then
        echo -e "${YELLOW}Skipping ESO installation as requested${NC}"
        return 0
    fi

    echo -e "${GREEN}Installing External Secrets Operator...${NC}"

    # Check for existing installation
    if is_operator_installed "$ESO_NS" "$ESO_NAME" "app.kubernetes.io/name=$ESO_NAME"; then
        echo -e "${YELLOW}ESO is already installed in namespace $ESO_NS${NC}"
        if ! $FORCE; then
            read -rp "Do you want to upgrade? [y/N] " confirm
            [[ ! "$confirm" =~ ^[yY]$ ]] && return 0
        fi
    fi

    # Add Helm repo
    helm repo add external-secrets https://charts.external-secrets.io
    helm repo update

    # Install/Upgrade ESO
    local install_cmd="helm upgrade --install $ESO_NAME external-secrets/external-secrets "
    install_cmd+="--namespace $ESO_NS "
    install_cmd+="--create-namespace "
    install_cmd+="--version $ESO_VERSION "
    install_cmd+="--set installCRDs=true"

    if $VERBOSE; then
        echo -e "${YELLOW}Running: $install_cmd${NC}"
    fi

    eval "$install_cmd" || {
        echo -e "${RED}Error installing ESO${NC}"
        return 1
    }

    # Wait for ESO
    echo -e "${YELLOW}Waiting for ESO to be ready...${NC}"
    kubectl wait --for=condition=available deployment/"$ESO_NAME" -n "$ESO_NS" --timeout=300s

    echo -e "${GREEN}External Secrets Operator installed successfully!${NC}"
}

# --- Uninstallation Functions ---

uninstall_k3s() {
    echo -e "${YELLOW}Uninstalling K3s...${NC}"
    if command_exists k3s-uninstall.sh; then
        /usr/local/bin/k3s-uninstall.sh
    else
        echo -e "${YELLOW}K3s uninstall script not found${NC}"
    fi
    echo -e "${GREEN}K3s uninstalled successfully!${NC}"
}

uninstall_argocd() {
    if $SKIP_ARGO; then
        return 0
    fi

    echo -e "${YELLOW}Uninstalling ArgoCD...${NC}"
    if helm list -n "$ARGO_NS" | grep -q argocd; then
        helm uninstall argocd -n "$ARGO_NS"
        kubectl delete namespace "$ARGO_NS" --ignore-not-found=true
        echo -e "${GREEN}ArgoCD uninstalled successfully!${NC}"
    else
        echo -e "${YELLOW}ArgoCD not found in namespace $ARGO_NS${NC}"
    fi

    # Remove CLI if exists
    if command_exists argocd; then
        echo -e "${YELLOW}Removing ArgoCD CLI...${NC}"
        sudo rm -f /usr/local/bin/argocd
    fi
}

uninstall_eso() {
    if $SKIP_ESO; then
        return 0
    fi

    echo -e "${YELLOW}Uninstalling ESO...${NC}"
    if helm list -n "$ESO_NS" | grep -q "$ESO_NAME"; then
        helm uninstall "$ESO_NAME" -n "$ESO_NS"
        kubectl delete namespace "$ESO_NS" --ignore-not-found=true
        echo -e "${GREEN}ESO uninstalled successfully!${NC}"
    else
        echo -e "${YELLOW}ESO not found in namespace $ESO_NS${NC}"
    fi
}

# --- Verification Functions ---

verify_installation() {
    echo -e "${GREEN}Verifying installation...${NC}"
    local success=true

    # Verify K3s
    if ! kubectl get nodes >/dev/null 2>&1; then
        echo -e "${RED}Error: K3s cluster is not running${NC}"
        success=false
    else
        echo -e "${GREEN}✓ K3s cluster is running${NC}"
    fi

    # Verify ArgoCD if installed
    if ! $SKIP_ARGO; then
        if ! is_operator_installed "$ARGO_NS" "argocd" "app.kubernetes.io/name=argocd-server"; then
            echo -e "${RED}Error: ArgoCD is not installed${NC}"
            success=false
        elif ! is_crd_installed "applications.argoproj.io"; then
            echo -e "${RED}Error: ArgoCD CRDs are not installed${NC}"
            success=false
        else
            echo -e "${GREEN}✓ ArgoCD is installed and running${NC}"
        fi
    fi

    # Verify ESO if installed
    if ! $SKIP_ESO; then
        if ! is_operator_installed "$ESO_NS" "$ESO_NAME" "app.kubernetes.io/name=$ESO_NAME"; then
            echo -e "${RED}Error: ESO is not installed${NC}"
            success=false
        elif ! is_crd_installed "externalsecrets.external-secrets.io"; then
            echo -e "${RED}Error: ESO CRDs are not installed${NC}"
            success=false
        else
            echo -e "${GREEN}✓ ESO is installed and running${NC}"
        fi
    fi

    if $success; then
        echo -e "${GREEN}All components verified successfully!${NC}"
        return 0
    else
        echo -e "${RED}Verification failed${NC}"
        return 1
    fi
}

# --- Main Function ---

main() {
    parse_args "$@"

    # Check dependencies
    if ! check_dependencies; then
        if ! $FORCE; then
            read -rp "Attempt to install missing dependencies? [y/N] " confirm
            [[ "$confirm" =~ ^[yY]$ ]] || exit 1
        fi
        install_dependencies || exit 1
    fi

    confirm_action

    case "$COMMAND" in
        install)
            install_k3s || exit 1
            install_argocd
            install_eso
            verify_installation
            ;;
        uninstall)
            uninstall_argocd
            uninstall_eso
            uninstall_k3s
            ;;
        *)
            echo -e "${RED}Error: Unknown command $COMMAND${NC}"
            usage
            ;;
    esac
}

# Execute only if run directly
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
#
#./k3s.sh install \
#  --k3s-version=v1.32.3+k3s1 \
#  --cluster-name=development \
#  --node-ip=<NODE_IP> \
#  --argocd-version=v2.14.10 \
#  --argocd-port=8080 \
#  --argocd-ns=argocd \
#  --eso-version=0.16.1 \
#  --eso-ns=external-secrets \
#  --eso-name=external-secrets \
#  -v \
#  -f
