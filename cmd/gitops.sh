#!/bin/bash

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Paths to component scripts
K3S_SCRIPT="./k3s.sh"
ESO_SCRIPT="./manifest.sh"

# Function to print header
print_header() {
    echo -e "${BLUE}"
    echo "===================================================================="
    echo "$1"
    echo "===================================================================="
    echo -e "${NC}"
}

# Function to print usage information
usage() {
    print_header "Master Deployment Control Script"
    
    echo "Usage: $0 [options]"
    echo ""
    echo "Options:"
    echo "  --install               Install all components (K3s + ESO)"
    echo "  --uninstall             Uninstall all components"
    echo "  --install-k3s           Install only K3s cluster"
    echo "  --uninstall-k3s         Uninstall only K3s cluster"
    echo "  --install-eso           Install only External Secrets Operator"
    echo "  --uninstall-eso         Uninstall only External Secrets Operator"
    echo "  -h, --help              Show this help message"
    echo ""
    echo "Examples:"
    echo "  # Install everything"
    echo "  sudo $0 --install"
    echo ""
    echo "  # Uninstall everything"
    echo "  sudo $0 --uninstall"
    echo ""
    echo "  # Install only K3s"
    echo "  sudo $0 --install-k3s"
    exit 1
}

# Function to verify script exists
verify_script() {
    if [ ! -f "$1" ]; then
        echo -e "${RED}Error: Script $1 not found${NC}"
        exit 1
    fi
    if [ ! -x "$1" ]; then
        chmod +x "$1"
    fi
}

# Function to run component script
run_component() {
    local script=$1
    local operation=$2
    local args=("${@:3}")
    
    print_header "Executing $script $operation"
    
    if [ "$VERBOSE" = true ]; then
        echo -e "${YELLOW}Command: $script $operation ${args[@]}${NC}"
    fi
    
    if ! "$script" "$operation" "${args[@]}"; then
        echo -e "${RED}Error executing $script $operation${NC}"
        return 1
    fi
    return 0
}

# Main function
main() {
    # Verify both scripts exist
    verify_script "$K3S_SCRIPT"
    verify_script "$ESO_SCRIPT"
    
    # Parse arguments
    case "$1" in
        --install)
            print_header "Starting Complete Installation"
            if ! run_component "$K3S_SCRIPT" "install"; then
                exit 1
            fi
            if ! run_component "$ESO_SCRIPT" "install"; then
                echo -e "${YELLOW}Continuing despite ESO installation issue${NC}"
            fi
            ;;
        --uninstall)
            print_header "Starting Complete Uninstallation"
            run_component "$ESO_SCRIPT" "uninstall"
            run_component "$K3S_SCRIPT" "uninstall"
            ;;
        --install-k3s)
            print_header "Installing K3s Only"
            run_component "$K3S_SCRIPT" "install"
            ;;
        --uninstall-k3s)
            print_header "Uninstalling K3s Only"
            run_component "$K3S_SCRIPT" "uninstall"
            ;;
        --install-eso)
            print_header "Installing ESO Only"
            run_component "$ESO_SCRIPT" "install"
            ;;
        --uninstall-eso)
            print_header "Uninstalling ESO Only"
            run_component "$ESO_SCRIPT" "uninstall"
            ;;
        -h|--help)
            usage
            ;;
        *)
            echo -e "${RED}Unknown option: $1${NC}"
            usage
            ;;
    esac
    
    print_header "Operation Completed"
    echo -e "${GREEN}Successfully executed: $1${NC}"
}

# Execute main function
main "$@"

#export SSH_PRIVATE_KEY_B64=$(awk 'NR==1{print $0; next} {print "    " $0}' ~/.ssh/id_ed25519)
#export SSH_PRIVATE_KEY_B64=$(sed '1!s/^/    /' ~/.ssh/id_ed25519)