# Kubernetes Kind + Traefik Setup Guide

## Overview

This README documents how to set up a local Kubernetes cluster using **kind** with **Traefik** as an ingress controller, and how to deploy applications with ingress routing.

---

## Architecture Diagram

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                                    HOST                                     │
│  ┌─────────────┐     ┌──────────────────────────────────────────────────┐  │
│  │   Browser  │────▶│  /etc/hosts                                        │  │
│  │            │     │  127.0.0.1 app.local traefik.local argocd.local   │  │
│  └─────────────┘     └──────────────────────────────────────────────────┘  │
│                              │                   │                             │
│                              ▼                   ▼                             │
│                       ┌──────────┐       ┌──────────┐                       │
│                       │ :30080  │       │ :30443  │                       │
│                       │ (HTTP)  │       │ (HTTPS) │                       │
│                       └────┬─────┘       └────┬─────┘                       │
└──────────────────────────────┼──────────────────┼──────────────────────────────┘
                               │                  │
                               ▼                  ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                            KIND CLUSTER                                    │
│  ┌────────────────────────────────────────────────────────────────────┐    │
│  │                    kind-control-plane (Docker)                      │    │
│  │  ┌──────────────────────────────────────────────────────────────┐  │    │
│  │  │              Traefik Pod (Ingress Controller)                │  │    │
│  │  │                                                              │  │    │
│  │  │  ┌──────────────┐  ┌──────────────┐  ┌──────────────────┐  │  │    │
│  │  │  │ :80 (web)  │  │ :443(websecure)│  │ :8080 (dashboard)│  │  │    │
│  │  │  │ HTTP       │  │ HTTPS+TLS    │  │ API              │  │  │    │
│  │  │  └──────────────┘  └──────────────┘  └──────────────────┘  │  │    │
│  │  └──────────────────────────────────────────────────────────────┘  │    │
│  └────────────────────────────────────────────────────────────────────┘    │
│                                                                              │
│  ┌────────────────────────────────────────────────────────────────────┐    │
│  │                    kind-worker (Docker)                              │    │
│  │  ┌──────────────────────────────────────────────────────────────┐  │    │
│  │  │              App Pods                                      │  │    │
│  │  │  ┌──────────────────┐  ┌──────────────────────────────┐  │    │
│  │  │  │ fe-boilerplate   │  │ argocd-server                 │  │    │
│  │  │  │ (your app)      │  │ (ArgoCD)                    │  │    │
│  │  │  └──────────────────┘  └──────────────────────────────┘  │    │
│  │  └──────────────────────────────────────────────────────────────┘  │    │
│  │                                                                      │    │
└───┴────────────────────────────────────────────────────────────────────┘
```

---

## Prerequisites

1. **Docker Desktop** installed and running
2. **kubectl** installed (`brew install kubectl`)
3. **helm** installed (`brew install helm`)
4. **kind** installed (`brew install kind`)
5. Access to your TLS certificate and key files

---

## Step-by-Step Setup

### Step 1: Create Kind Cluster

```bash
# Delete existing cluster (if any)
kind delete cluster --name kind

# Create cluster
kind create cluster --name kind
```

Or with port mappings (to use ports 80/443 directly):

```bash
cat > kind-config.yaml <<EOF
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
- role: control-plane
  extraPortMappings:
  - containerPort: 80
    hostPort: 80
    protocol: TCP
  - containerPort: 443
    hostPort: 443
    protocol: TCP
EOF

kind create cluster --name kind --config kind-config.yaml
```

### Step 2: Install Traefik (Ingress Controller)

```bash
# Add Traefik Helm repository
helm repo add traefik https://traefik.github.io/charts
helm repo update

# Create values file (traefik-values.yaml)
cat > traefik-values.yaml <<EOF
# Traefik ingress configuration
ports:
  web:
    port: 80
    http:
      redirections:
        entryPoint:
          to: websecure
          scheme: https
          permanent: true

  websecure:
    port: 443

ingressRoute:
  dashboard:
    enabled: true
    matchRule: Host(\`traefik.local\`)
    entryPoints:
      - websecure
EOF

# Install Traefik
kubectl create namespace traefik
helm install traefik traefik/traefik --namespace traefik -f traefik-values.yaml
```

### Step 3: Set Up Host Entries

```bash
# Add host entries for local development
echo "127.0.0.1 app.local traefik.local argocd.local" | sudo tee -a /etc/hosts
```

### Step 4: Deploy Your Application

```bash
# Create namespace
kubectl create namespace frontend

# Create TLS secret (from your certificate files)
kubectl create secret tls app-tls --cert=tls.crt --key=tls.key -n frontend

# Deploy the app
kubectl apply -f fe-boilerplate/
```

### Step 5: Install ArgoCD

```bash
# Install ArgoCD
kubectl create namespace argocd
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

# Wait for pods to be ready
kubectl get pods -n argocd -w
```

### Step 6: Create ArgoCD IngressRoute

```bash
# Create argocd directory
mkdir -p argocd

# Create TLS secret for ArgoCD
kubectl create secret tls argocd-tls --cert=tls.crt --key=tls.key -n argocd

# Create IngressRoute (argocd/ingress.yaml)
cat > argocd/ingress.yaml <<EOF
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: argocd
  namespace: argocd
spec:
  entryPoints:
    - websecure
  routes:
    - match: Host(\`argocd.local\`)
      kind: Rule
      services:
        - name: argocd-server
          port: 80
  tls:
    secretName: argocd-tls
EOF

# Apply IngressRoute
kubectl apply -f argocd/ingress.yaml
```

### Step 7: Start Port-Forward (Required)

Since kind doesn't expose ports 30080/30443 by default, you need port-forward:

```bash
# Setup port-forward for Traefik (run in background)
kubectl port-forward -n traefik svc/traefik 30080:80 30443:443 &

# Setup port-forward for ArgoCD (run in background)
kubectl port-forward -n argocd svc/argocd-server 8080:80 &
```

Or use the script:
```bash
make port-forward
```

### Step 8: Create ArgoCD Application (Optional)

If you have an ArgoCD Application manifest:

```bash
kubectl apply -f argocd/manifest.yaml
```

### Step 9: Access Services

| Service       | URL                          | Login |
|--------------|-----------------------------|-------|
| Your App     | https://app.local:30443     | - |
| Traefik Dash | https://traefik.local:30443 | - |
| ArgoCD       | http://localhost:8080       | `admin` + password |

### Get ArgoCD Admin Password

```bash
argocd admin initial-password -n argocd
```

---

## How Services Are Connected

### Request Flow: Browser → Your App

```
1. User visits: https://app.local:30443

2. /etc/hosts resolves: app.local → 127.0.0.1

3. Request goes to:
   - localhost:30443 → port-forward → Traefik pod (port 443)

4. Traefik receives request:
   - Reads IngressRoute for app.local
   - Finds matching service: fe-boilerplate
   - TLS termination (using app-tls secret)

5. Forwards to: fe-boilerplate service → pod

6. Your app responds with content
```

### Kubernetes Resources Relationship

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                        INGRESS ROUTE                              │
│  match: Host(`app.local`)                                          │
│  entryPoints: [websecure] (HTTPS)                                 │
│  tls: app-tls                                                    │
└─────────────────────────────────┬───────────────────────────────┘
                                  │
                                  │ resolves to
                                  ▼
┌───────────────────────────────────────────────────────────────────┐
│                           SERVICE                                │
│  name: fe-boilerplate                                            │
│  type: NodePort                                                 │
│  selector: app=fe-boilerplate                                   │
��  port: 80 → targetPort: 80                                      │
└─────────────────────────────────┬───────────────────────────────┘
                                  │
                                  │ routes to
                                  ▼
┌───────────────────────────────────────────────────────────────────┐
│                              POD                                  │
│  name: fe-boilerplate-xxxxx                                      │
│  image: yepsamii/fe-boilerplate:v1.10                           │
│  containerPort: 80                                             │
└───────────────────────────────────────────────────────────────────┘
```

### Key Configuration Files

| File | Purpose |
|------|---------|
| `traefik-values.yaml` | Traefik Helm values (ports, routing) |
| `fe-boilerplate/namespace.yaml` | Creates `frontend` namespace |
| `fe-boilerplate/deployment.yaml` | Deploys your app pods |
| `fe-boilerplate/service.yaml` | Exposes app as Kubernetes service |
| `fe-boilerplate/ingress.yaml` | Defines ingress routing rules |
| `argocd/ingress.yaml` | ArgoCD ingress route |
| `tls.crt` / `tls.key` | TLS certificate files |

---

## Common Commands

```bash
# Check pods
kubectl get pods -A

# Check services
kubectl get svc -A

# Check ingress routes
kubectl get ingressroute -A

# View Traefik logs
kubectl logs -n traefik deploy/traefik -f

# Port-forward for Traefik
kubectl port-forward -n traefik svc/traefik 30080:80 30443:443 &

# Port-forward for ArgoCD
kubectl port-forward -n argocd svc/argocd-server 8080:80 &

# Or restart all port-forwards
make restart-port-forward

# Get ArgoCD password
argocd admin initial-password -n argocd

# Delete a namespace (cleanup)
kubectl delete namespace <name>
```

---

## Troubleshooting

### Issue: "Connection Refused" in Browser

1. Check if port-forward is running:
   ```bash
   ps aux | grep port-forward
   ```

2. Restart port-forward if needed:
   ```bash
   kubectl port-forward -n traefik svc/traefik 30080:80 30443:443 &
   ```

### Issue: "Site Can't Be Reached"

1. Verify host entries:
   ```bash
   cat /etc/hosts | grep app.local
   ```

2. Check Traefik is running:
   ```bash
   kubectl get pods -n traefik
   ```

3. Test from command line:
   ```bash
   curl -sk -H "Host: app.local" https://localhost:30443
   ```

4. Restart port-forward:
   ```bash
   make restart-port-forward
   ```

---

## Full YAML Examples

### fe-boilerplate/ingress.yaml

```yaml
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: fe-boilerplate
  namespace: frontend
spec:
  entryPoints:
    - websecure
  routes:
    - match: Host(`app.local`)
      kind: Rule
      services:
        - name: fe-boilerplate
          port: 80
  tls:
    secretName: app-tls
```

### fe-boilerplate/deployment.yaml

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: fe-boilerplate
  namespace: frontend
spec:
  replicas: 1
  selector:
    matchLabels:
      app: fe-boilerplate
  template:
    metadata:
      labels:
        app: fe-boilerplate
    spec:
      containers:
        - name: fe-boilerplate
          image: yepsamii/fe-boilerplate:v1.10
          ports:
            - containerPort: 80
```

### argocd/ingress.yaml

```yaml
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
```

---

## Access URLs Summary

| Service       | HTTP              | HTTPS             |
|--------------|------------------|------------------|
| App          | app.local:30080   | app.local:30443  |
| Traefik Dash  | traefik.local:30080 | traefik.local:30443 |
| ArgoCD       | localhost:8080    | -               |

*Replace ports 30080/30443 with 80/443 if using kind with extraPortMappings*

---

## Project Structure

```
gitops/
├── README.md                 # This file
├── traefik-values.yaml       # Traefik Helm values
├── tls.crt                  # TLS certificate
├── tls.key                  # TLS private key
├── kind-config.yaml          # Kind cluster config (optional)
├── fe-boilerplate/          # Your app manifests
│   ├── namespace.yaml
│   ├── deployment.yaml
│   ├── service.yaml
│   └── ingress.yaml
└── argocd/                # ArgoCD manifests
    └── ingress.yaml
```

---

## Using Makefile

Quick commands to manage your setup:

```bash
# Full setup (pre-pull images, install everything)
make setup
# or
make all

# Individual commands
make prepull               # Pre-pull Docker images
make install-traefik      # Install Traefik only
make install-app          # Deploy your app only
make install-argocd      # Install ArgoCD only

# Access
make info                # Show access URLs
make password            # Show ArgoCD password
make test               # Test all services

# Utility
make status             # Show pod status
make logs              # Show Traefik logs
make restart-port-forward # Restart all port-forwards
make delete-all        # Delete everything
make help             # Show help
```

---

**End of Document**