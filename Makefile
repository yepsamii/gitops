# =============================================================================
# Makefile for GitOps Setup
# =============================================================================

# Script location
SETUP_SH := ./setup.sh

# Colors
GREEN := \033[0;32m
YELLOW := \033[1;33m
NC := \033[0m

# Default target
.PHONY: all
all: info setup

# =============================================================================
# Setup Targets
# =============================================================================

.PHONY: setup
setup: setup-hosts setup-kind setup-traefik setup-app setup-argocd setup-argocd-app port-forward wait

.PHONY: setup-hosts
setup-hosts:
	@echo "$(GREEN)[INFO]$(NC) Setting up host entries..."
	@bash $(SETUP_SH) hosts

.PHONY: setup-kind
setup-kind:
	@echo "$(GREEN)[INFO]$(NC) Setting up kind cluster..."
	@bash $(SETUP_SH) kind

.PHONY: setup-traefik
setup-traefik:
	@echo "$(GREEN)[INFO]$(NC) Installing Traefik..."
	@bash $(SETUP_SH) traefik

.PHONY: setup-app
setup-app:
	@echo "$(GREEN)[INFO]$(NC) Deploying your app..."
	@bash $(SETUP_SH) app

.PHONY: setup-argocd
setup-argocd:
	@echo "$(GREEN)[INFO]$(NC) Installing ArgoCD..."
	@bash $(SETUP_SH) argocd

.PHONY: setup-argocd-app
setup-argocd-app:
	@echo "$(GREEN)[INFO]$(NC) Creating ArgoCD Application..."
	@bash $(SETUP_SH) argocd-app

.PHONY: port-forward
port-forward:
	@echo "$(GREEN)[INFO]$(NC) Starting port-forward..."
	@bash $(SETUP_SH) port-forward

.PHONY: wait
wait:
	@echo "$(GREEN)[INFO]$(NC) Waiting for pods..."
	@kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=traefik -n traefik --timeout=120s || true
	@kubectl wait --for=condition=ready pod -l app=fe-boilerplate -n frontend --timeout=120s || true
	@kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=argocd-server -n argocd --timeout=180s || true

# =============================================================================
# Individual Targets
# =============================================================================

.PHONY: install-traefik
install-traefik: setup-hosts setup-kind setup-traefik port-forward

.PHONY: install-app
install-app: setup-hosts setup-kind setup-traefik setup-app

.PHONY: install-argocd
install-argocd: setup-hosts setup-kind setup-traefik setup-argocd port-forward

# =============================================================================
# Access Targets
# =============================================================================

.PHONY: info
info:
	@echo ""
	@echo "============================================"
	@echo "         GitOps - Access URLs"
	@echo "============================================"
	@echo ""
	@echo "  Your App:      https://app.local:30443"
	@echo "  Traefik:       https://traefik.local:30443"
	@echo "  ArgoCD:        https://argocd.local:30443"
	@echo ""
	@echo "  ArgoCD Login:  admin / (run 'make password')"
	@echo ""
	@echo "============================================"

.PHONY: password
password:
	@echo "ArgoCD admin password:"
	@argocd admin initial-password -n argocd

.PHONY: test
test:
	@echo "Testing all services..."
	@curl -Isk https://app.local:30443 | head -1
	@curl -Isk https://traefik.local:30443/api/overview | head -1
	@curl -Isk https://argocd.local:30443 | head -1

# =============================================================================
# Utility Targets
# =============================================================================

.PHONY: status
status:
	@echo "Pod Status:"
	@kubectl get pods -A -o wide

.PHONY: logs
logs:
	@kubectl logs -n traefik deploy/traefik --tail=20

.PHONY: restart-port-forward
restart-port-forward:
	@pkill -f "port-forward.*traefik" || true
	@kubectl port-forward -n traefik svc/traefik 30080:80 30443:443 &
	@echo "Port-forward restarted"

.PHONY: delete-all
delete-all:
	@echo "Deleting all resources..."
	@kubectl delete namespace argocd frontend traefik --ignore-not-found=true
	@kind delete cluster --name kind

.PHONY: help
help:
	@echo ""
	@echo "GitOps Makefile Commands:"
	@echo ""
	@echo "  Setup:"
	@echo "    make setup              - Full setup (all services)"
	@echo "    make install-traefik    - Install Traefik only"
	@echo "    make install-app       - Deploy your app only"
	@echo "    make install-argocd    - Install ArgoCD only"
	@echo "    make argocd-app         - Create ArgoCD Application only"
	@echo ""
	@echo "  Access:"
	@echo "    make info              - Show access URLs"
	@echo "    make password          - Show ArgoCD password"
	@echo "    make test              - Test all services"
	@echo ""
	@echo "  Utility:"
	@echo "    make status            - Show pod status"
	@echo "    make logs              - Show Traefik logs"
	@echo "    make restart-port-forward - Restart port-forward"
	@echo "    make delete-all        - Delete everything"
	@echo "    make help             - Show this help"
	@echo ""