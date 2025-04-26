#!/bin/bash

set -eo pipefail

# Default variables
DEFAULT_ESO_VERSION="0.16.1"
DEFAULT_NAMESPACE="default"
DEFAULT_AWS_REGION="us-east-1"
DEFAULT_SKIP_PARAM_STORE="false"
DEFAULT_SKIP_ECR="false"
DEFAULT_REFRESH_INTERVAL="12h"


# Initialize variables
NAME_PREFIX=""
ESO_VERSION=""
NAMESPACE=""
AWS_REGION=""
AWS_ACCESS_KEY_ID=""
AWS_SECRET_ACCESS_KEY=""
REFRESH_INTERVAL=""
ACTION=""
SKIP_PARAM_STORE=""
SKIP_ECR=""
INSTALL_ESO=""
OUTPUT_DIR=""

# Usage help
usage() {
    echo "Usage: $0 <install|uninstall> [options]"
    echo ""
    echo "Options:"
    echo "  -p,  --name-prefix          Unique name prefix for all resources (default: namespace)"
    echo "  -e,  --eso-version          External Secrets Operator version (default: $DEFAULT_ESO_VERSION)"
    echo "  -n,  --namespace            Kubernetes namespace (default: $DEFAULT_NAMESPACE)"
    echo "  -r,  --region               AWS region (default: $DEFAULT_AWS_REGION)"
    echo "  -a,  --access-key           AWS Access Key ID (default: from env AWS_ACCESS_KEY_ID)"
    echo "  -s,  --secret-key           AWS Secret Access Key (default: from env AWS_SECRET_ACCESS_KEY)"
    echo "  -xp, --skip-param-store     Skip Parameter Store secret creation (default: false)"
    echo "  -xe, --skip-ecr             Skip ECR secret creation (default: false)"
    echo "  -h,  --help                 Show this help message"
    exit 1
}

# Check dependencies
check_dependencies() {
    local deps=("kubectl" "envsubst")
    local missing=()

    for dep in "${deps[@]}"; do
        if ! command -v "$dep" &>/dev/null; then
            missing+=("$dep")
        fi
    done

    if [ ${#missing[@]} -gt 0 ]; then
        echo "Missing dependencies: ${missing[*]}"

        # Install envsubst if missing (usually comes with gettext package)
        if [[ " ${missing[*]} " =~ " envsubst " ]]; then
            echo "Attempting to install envsubst..."
            if command -v apt-get &>/dev/null; then
                sudo apt-get update && sudo apt-get install -y gettext-base
            elif command -v yum &>/dev/null; then
                sudo yum install -y gettext
            elif command -v brew &>/dev/null; then
                brew install gettext
            else
                echo "Could not automatically install envsubst. Please install it manually."
                exit 1
            fi

            # Verify installation
            if ! command -v envsubst &>/dev/null; then
                echo "envsubst installation failed. Please install it manually."
                exit 1
            fi
            echo "envsubst installed successfully."
        fi

        # After attempted installations, check again
        missing=()
        for dep in "${deps[@]}"; do
            if ! command -v "$dep" &>/dev/null; then
                missing+=("$dep")
            fi
        done

        if [ ${#missing[@]} -gt 0 ]; then
            echo "Still missing dependencies: ${missing[*]}"
            echo "Please install them before running this script."
            exit 1
        fi
    fi
}

# Install ESO
install_eso() {
    if [ "$INSTALL_ESO" = "false" ]; then
        echo "Skipping ESO installation as it's not required."
        return 0
    fi

    echo "Installing External Secrets Operator version $ESO_VERSION..."
    kubectl apply -f https://raw.githubusercontent.com/external-secrets/external-secrets/v${ESO_VERSION}/deploy/crds/bundle.yaml || {
        echo "Failed to apply ESO CRDs"
        return 1
    }
    kubectl apply -f https://raw.githubusercontent.com/external-secrets/external-secrets/v${ESO_VERSION}/deploy/bundle.yaml || {
        echo "Failed to apply ESO bundle"
        return 1
    }

    echo "Waiting for ESO pods to be ready..."
    kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=external-secrets -n external-secrets --timeout=300s
}

# Uninstall ESO
uninstall_eso() {
    echo "Uninstalling External Secrets Operator..."
    kubectl delete -f https://raw.githubusercontent.com/external-secrets/external-secrets/v${ESO_VERSION}/deploy/bundle.yaml --ignore-not-found
    kubectl delete -f https://raw.githubusercontent.com/external-secrets/external-secrets/v${ESO_VERSION}/deploy/crds/bundle.yaml --ignore-not-found
}

# Process template file
process_template() {
    local template_file=$1

    # Create output directory if it doesn't exist
    if [ ! -d "$OUTPUT_DIR" ]; then
        mkdir -p "$OUTPUT_DIR"
    fi

    local output_file="${OUTPUT_DIR}/$(basename ${template_file%.template.yaml}).yaml"

    # Check file exists
    if [ ! -f "$template_file" ]; then
        echo "Template file $template_file not found!"
        return 1
    fi

    # Interpolate variables
    echo "Processing template $template_file..."
    envsubst <"$template_file" >"$output_file"
    if [ $? -ne 0 ]; then
        echo "Failed to process template $template_file"
        return 1
    fi
    echo "Generated manifest: $output_file"

    # Dry-run validation
    if ! kubectl apply -f "$output_file" --dry-run=client; then
        echo "Dry-run validation failed for $output_file"
        return 1
    fi

    # Actual application
    if [ "$ACTION" = "install" ]; then
        echo "Applying manifest: $output_file"
        kubectl apply -f "$output_file"
    elif [ "$ACTION" = "uninstall" ]; then
        echo "Deleting resources from: $output_file"
        kubectl delete -f "$output_file" --ignore-not-found
    fi
}

# Create AWS credentials secret
create_aws_credentials_secret() {
    local secret_name="${AWS_SECRET_NAME}"

    if [ "$ACTION" = "install" ]; then
        echo "Creating AWS credentials secret..."
        kubectl create secret generic "$secret_name" \
            --from-literal=access-key="$AWS_ACCESS_KEY_ID" \
            --from-literal=secret-key="$AWS_SECRET_ACCESS_KEY" \
            -n "$NAMESPACE" \
            --dry-run=client -o yaml | kubectl apply -f -
    elif [ "$ACTION" = "uninstall" ]; then
        echo "Deleting AWS credentials secret..."
        kubectl delete secret "$secret_name" -n "$NAMESPACE" --ignore-not-found
    fi
}

# Function to create AWS credentials secret
aws_credentials_secret() {
    if [[ "$SKIP_AWS_SECRET" == "true" ]]; then
        echo "Skipping AWS credentials secret action."
        return
    fi

    local templates=(
        "./manifests/aws-credentials-secret.template.yaml"
    )
    export NAME_PREFIX NAMESPACE AWS_REGION AWS_SECRET_NAME
    export AWS_ACCESS_KEY_B64=$(echo -n "$AWS_ACCESS_KEY_ID" | base64 -w0)
    export AWS_SECRET_KEY_B64=$(echo -n "$AWS_SECRET_ACCESS_KEY" | base64 -w0)

    for template in "${templates[@]}"; do
        process_template "$template" || exit 1
    done
    echo "Created/updated secret: ${AWS_SECRET_NAME}"

}

# Create/delete Parameter Store external secret
parameter_store_external_secret() {
    if [ "$SKIP_PARAM_STORE" = "true" ]; then
        echo "Skipping Parameter Store external secret action as requested."
        return 0
    fi

    local template_file="./manifests/param-store-secret.template.yaml"

    export NAME_PREFIX NAMESPACE REFRESH_INTERVAL AWS_REGION AWS_SECRET_NAME
    export PARAM_STORE_SECRET_NAME="${NAME_PREFIX}-param-store-secret"
    export PARAM_STORE_SECRET_STORE_NAME="${NAME_PREFIX}-aws-parameter-store"

    process_template "$template_file" || exit 1
    echo "Created/updated secret: ${PARAM_STORE_SECRET_NAME}"
    echo "Created/updated secret store: ${PARAM_STORE_SECRET_STORE_NAME}"
}

# Create/delete ECR external secret
ecr_external_secret() {
    if [ "$SKIP_ECR" = "true" ]; then
        echo "Skipping ECR external secret creation as requested."
        return 0
    fi

    local template_file="./manifests/ecr-secret.template.yaml"

    export NAME_PREFIX NAMESPACE REFRESH_INTERVAL AWS_REGION AWS_SECRET_NAME
    export ECR_SECRET_NAME="${NAME_PREFIX}-ecr-secret"
    export ECR_SECRET_STORE_NAME="${NAME_PREFIX}-aws-ecr"
    export ECR_AUTH_TOKEN_NAME="${NAME_PREFIX}-aws-ecr"

    process_template "$template_file" || exit 1
    echo "ECR_SECRET_NAME: ${ECR_SECRET_NAME}"
    echo "ECR_AUTH_TOKEN_NAME: ${ECR_AUTH_TOKEN_NAME}"
}

# Function to create namespace if needed
create_namespace() {
    if ! kubectl get namespace "$NAMESPACE" &>/dev/null; then
        echo "Creating namespace ${NAMESPACE}..."
        kubectl create namespace "$NAMESPACE"
    fi
}

# Print configuration
print_config() {
    echo ""
    echo "Current configuration:"
    echo "======================"
    echo "Action:                $ACTION"
    echo "Name prefix:           $NAME_PREFIX"
    echo "ESO version:           $ESO_VERSION"
    echo "Namespace:             $NAMESPACE"
    echo "AWS Region:            $AWS_REGION"
    echo "Install ESO:           $INSTALL_ESO"
    echo "Skip Parameter Store:  $SKIP_PARAM_STORE"
    echo "Skip ECR:              $SKIP_ECR"
    echo "AWS Secret Name:       $AWS_SECRET_NAME"
    echo "AWS Access Key ID:     ${AWS_ACCESS_KEY_ID:0:4}... (truncated)"
    echo "AWS Secret Access Key: ${AWS_SECRET_ACCESS_KEY:0:4}... (truncated)"
    if [ -n "$OUTPUT_DIR" ]; then
        echo "Output Directory:      $OUTPUT_DIR"
    fi
    echo ""
}

# Prompt for confirmation
confirm() {
    print_config

    read -p "Do you want to proceed with these settings? (y/n) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "Aborting..."
        exit 0
    fi
}

# Parse arguments
parse_args() {
    if [ $# -lt 1 ]; then
        usage
    fi

    ACTION=$1
    shift

    if [ "$ACTION" != "install" ] && [ "$ACTION" != "uninstall" ]; then
        echo "Invalid action: $ACTION"
        usage
    fi

    while [ $# -gt 0 ]; do
        case $1 in
        -p | --name-prefix)
            NAME_PREFIX="$2"
            shift 2
            ;;
        -e | --eso-version)
            ESO_VERSION="$2"
            shift 2
            ;;
        -n | --namespace)
            NAMESPACE="$2"
            shift 2
            ;;
        -r | --region)
            AWS_REGION="$2"
            shift 2
            ;;
        -a | --access-key)
            AWS_ACCESS_KEY_ID="$2"
            shift 2
            ;;
        -s | --secret-key)
            AWS_SECRET_ACCESS_KEY="$2"
            shift 2
            ;;
        -xp | --skip-param-store)
            SKIP_PARAM_STORE="true"
            shift
            ;;
        -xe | --skip-ecr)
            SKIP_ECR="true"
            shift
            ;;
        -h | --help)
            usage
            ;;
        *)
            echo "Unknown option: $1"
            usage
            ;;
        esac
    done

    # Set defaults if not provided
    ESO_VERSION=${ESO_VERSION:-$DEFAULT_ESO_VERSION}
    NAMESPACE=${NAMESPACE:-$DEFAULT_NAMESPACE}
    AWS_REGION=${AWS_REGION:-$DEFAULT_AWS_REGION}
    SKIP_PARAM_STORE=${SKIP_PARAM_STORE:-$DEFAULT_SKIP_PARAM_STORE}
    SKIP_ECR=${SKIP_ECR:-$DEFAULT_SKIP_ECR}
    REFRESH_INTERVAL=${REFRESH_INTERVAL:-$DEFAULT_REFRESH_INTERVAL}

    # Set name prefix to namespace if not provided
    NAME_PREFIX=${NAME_PREFIX:-$NAMESPACE}

    # Set AWS secret name
    AWS_SECRET_NAME="${NAME_PREFIX}-aws-credentials"

    # Get AWS credentials from env if not provided
    AWS_ACCESS_KEY_ID=${AWS_ACCESS_KEY_ID:-$AWS_ACCESS_KEY_ID}
    AWS_SECRET_ACCESS_KEY=${AWS_SECRET_ACCESS_KEY:-$AWS_SECRET_ACCESS_KEY}

    # Determine if ESO needs to be installed
    INSTALL_ESO="false"
    if [ "$ACTION" = "install" ] && { [ "$SKIP_PARAM_STORE" = "false" ] || [ "$SKIP_ECR" = "false" ]; }; then
        INSTALL_ESO="true"
    fi

    # Set output directory
    TIMESTAMP=$(date +%Y%m%d%H%M%S)
    OUTPUT_DIR="./manifests/${ACTION}/${TIMESTAMP}"

    # Validate required arguments
    if [ -z "$AWS_ACCESS_KEY_ID" ] || [ -z "$AWS_SECRET_ACCESS_KEY" ]; then
        echo "Error: AWS credentials must be provided either via arguments or environment variables"
        usage
    fi
}

main() {
    check_dependencies
    parse_args "$@"
    confirm

    if [ "$ACTION" = "install" ]; then
        install_eso
        create_namespace
        aws_credentials_secret
        parameter_store_external_secret
        ecr_external_secret
        echo "Installation completed successfully!"
        echo "Manifests saved in: $OUTPUT_DIR"
    elif [ "$ACTION" = "uninstall" ]; then
        ecr_external_secret
        parameter_store_external_secret
        aws_credentials_secret
        if [ "$INSTALL_ESO" = "true" ]; then
            echo "Uninstalling External Secrets Operator version $ESO_VERSION skipped. Please do it manually."
            #uninstall_eso
        fi
        echo "Uninstallation completed successfully!"
        echo "Manifests saved in: $OUTPUT_DIR"
    fi
}

main "$@"
