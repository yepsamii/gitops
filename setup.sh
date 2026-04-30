#!/bin/bash

# =============================================================================
# GitOps Setup Script
# =============================================================================
# This script sets up:
# - Traefik (ingress controller)
# - Your app (fe-boilerplate)
# - ArgoCD
# =============================================================================

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Functions
log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Check prerequisites
check_prerequisites() {
    log_info "Checking prerequisites..."

    if ! command -v kind &> /dev/null; then
        log_error "kind is not installed. Install with: brew install kind"
        exit 1
    fi

    if ! command -v kubectl &> /dev/null; then
        log_error "kubectl is not installed. Install with: brew install kubectl"
        exit 1
    fi

    if ! command -v helm &> /dev/null; then
        log_error "helm is not installed. Install with: brew install helm"
        exit 1
    fi

    log_info "All prerequisites satisfied"
}

# Pre-pull Docker images for faster setup
prepull_images() {
    log_info "Pre-pulling Docker images..."

    IMAGES=(
        "docker.io/traefik:v3.6.13"
        "docker.io/argoproj/argocd:v2.14.2"
        "docker.io/library/redis:7.4-alpine"
        "docker.io/dexidp/dex:v2.53.1"
    )

    for image in "${IMAGES[@]}"; do
        log_info "Pulling $image..."
        docker pull "$image" 2>/dev/null || true
    done

    log_info "Images pre-pulled"
}

# Add host entries
setup_hosts() {
    log_info "Setting up /etc/hosts entries..."

    HOSTS_ENTRY="127.0.0.1 app.local traefik.local argocd.local"

    if ! grep -q "app.local" /etc/hosts; then
        echo "$HOSTS_ENTRY" | sudo tee -a /etc/hosts > /dev/null
        log_info "Host entries added"
    else
        log_warn "Host entries already exist"
    fi
}

# Setup kind cluster
setup_kind() {
    log_info "Setting up kind cluster..."

    if kind get clusters | grep -q "kind"; then
        log_warn "Kind cluster already exists"
    else
        kind create cluster --name kind
        log_info "Kind cluster created"
    fi
}

# Install Traefik
setup_traefik() {
    log_info "Installing Traefik..."

    # Add repo if not exists
    helm repo add traefik https://traefik.github.io/charts 2>/dev/null || true
    helm repo update

    # Create namespace
    kubectl create namespace traefik 2>/dev/null || true

    # Install or upgrade Traefik
    if helm list -n traefik | grep -q "traefik"; then
        log_warn "Traefik already installed, upgrading..."
        helm upgrade traefik traefik/traefik --namespace traefik -f traefik-values.yaml
    else
        helm install traefik traefik/traefik --namespace traefik -f traefik-values.yaml
    fi

    log_info "Traefik installed"
}

# Deploy your app
setup_app() {
    log_info "Deploying your app..."

    # Create namespace
    kubectl create namespace frontend 2>/dev/null || true

    # Create TLS secret
    kubectl create secret tls app-tls --cert=tls.crt --key=tls.key -n frontend 2>/dev/null || true

    # Deploy app
    kubectl apply -f fe-boilerplate/

    log_info "App deployed"
}

# Install ArgoCD
setup_argocd() {
    log_info "Installing ArgoCD..."

    # Install ArgoCD (the CRD annotation warning can be ignored)
    kubectl create namespace argocd 2>/dev/null || true
    kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml 2>/dev/null || true

    # Create TLS secret
    kubectl create secret tls argocd-tls --cert=tls.crt --key=tls.key -n argocd 2>/dev/null || true

    # Create IngressRoute
    mkdir -p argocd 2>/dev/null || true
    rm -f argocd/ingress.yaml
    cat > argocd/ingress.yaml <<'INGRESS'
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: argocd
  namespace: argocd
spec:
  entryPoints:
    - websecure
  routes:
    - match: Host(`argocd.local`)
      kind: Rule
      services:
        - name: argocd-server
          port: 80
  tls:
    secretName: argocd-tls
INGRESS

    kubectl apply -f argocd/ingress.yaml

    # Apply ArgoCD Application manifest (if file exists)
    if [ -f argocd/manifest.yaml ]; then
        kubectl apply -f argocd/manifest.yaml
    fi

    log_info "ArgoCD installed"
}

# Create ArgoCD Application
setup_argocd_app() {
    log_info "Creating ArgoCD Application..."

    # Check if ArgoCD is installed
    if ! kubectl get namespace argocd &>/dev/null; then
        log_error "ArgoCD is not installed. Run '$0 argocd' first"
        exit 1
    fi

    # Apply ArgoCD Application manifest (if file exists)
    if [ -f argocd/manifest.yaml ]; then
        kubectl apply -f argocd/manifest.yaml
    else
        log_warn "argocd/manifest.yaml not found"
    fi

    log_info "ArgoCD Application created"
}

# Start port-forward
setup_port_forward() {
    log_info "Starting port-forward..."

    # Kill existing port-forward
    pkill -f "port-forward.*traefik" 2>/dev/null || true
    pkill -f "port-forward.*argocd" 2>/dev/null || true

    # Start Traefik port-forward in background
    kubectl port-forward -n traefik svc/traefik 30080:80 30443:443 &

    # Start ArgoCD port-forward in background (to 8080)
    kubectl port-forward -n argocd svc/argocd-server 8080:80 &

    log_info "Port-forward started: Traefik (30080/30443), ArgoCD (8080)"
}

# Wait for pods
wait_for_pods() {
    log_info "Waiting for all pods to be ready..."

    echo "Checking Traefik..."
    kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=traefik -n traefik --timeout=120s || true

    echo "Checking fe-boilerplate..."
    kubectl wait --for=condition=ready pod -l app=fe-boilerplate -n frontend --timeout=120s || true

    echo "Checking ArgoCD..."
    kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=argocd-server -n argocd --timeout=180s || true

    log_info "All pods should be ready"
}

# Get ArgoCD password
get_argocd_password() {
    log_info "ArgoCD admin password:"
    argocd admin initial-password -n argocd
}

# Print access info
print_access_info() {
    echo ""
    echo "============================================"
    echo "         Setup Complete! 🎉"
    echo "============================================"
    echo ""
    echo "Access your services at:"
    echo "  - Your App:      https://app.local:30443"
    echo "  - Traefik:      https://traefik.local:30443"
    echo "  - ArgoCD:       http://localhost:8080"
    echo ""
    echo "ArgoCD login:"
    echo "  - Username: admin"
    echo "  - Password: Run 'argocd admin initial-password -n argocd'"
    echo ""
    echo "============================================"
}

# Main
main() {
    log_info "Starting GitOps setup..."

    check_prerequisites
    prepull_images
    setup_hosts
    setup_kind
    setup_traefik
    setup_app
    setup_argocd
    setup_port_forward
    wait_for_pods
    print_access_info

    log_info "Setup complete!"
}

# Run based on argument
case "${1:-all}" in
    all)
        main
        ;;
    kind)
        setup_kind
        ;;
    traefik)
        setup_traefik
        ;;
    app)
        setup_app
        ;;
    argocd)
        setup_argocd
        ;;
    argocd-app)
        setup_argocd_app
        ;;
    prepull)
        prepull_images
        ;;
    port-forward)
        setup_port_forward
        ;;
    hosts)
        setup_hosts
        ;;
    password)
        get_argocd_password
        ;;
    *)
        echo "Usage: $0 {all|prepull|kind|traefik|app|argocd|argocd-app|port-forward|hosts|password}"
        exit 1
        ;;
esac