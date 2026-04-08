# Documentation technique — k8s-v2

Architecture Kubernetes production-ready avec Kustomize et GitOps ArgoCD.

---

## Sommaire

1. [Structure des fichiers](#1-structure-des-fichiers)
2. [Kustomize — base/overlays](#2-kustomize--baseoverlays)
3. [ArgoCD — App of Apps](#3-argocd--app-of-apps)
4. [Sealed Secrets](#4-sealed-secrets)
5. [Ingress ALB](#5-ingress-alb)
6. [Resource limits et Health Probes](#6-resource-limits-et-health-probes)
7. [Bootstrap depuis zéro](#7-bootstrap-depuis-zéro)
8. [Opérations courantes](#8-opérations-courantes)

---

## 1. Structure des fichiers

```
k8s-v2/
├── argocd/
│   ├── app-of-apps.yaml              # Application racine ArgoCD
│   └── apps/
│       ├── infrastructure.yaml       # App ArgoCD — Postgres + Redis (wave -2)
│       ├── core.yaml                 # App ArgoCD — Backend + Client + BeeHub (wave -1)
│       └── beeapi.yaml               # App ArgoCD — BeeAPI toutes villes (wave 0)
│
├── base/
│   ├── namespace/
│   │   ├── namespace.yaml
│   │   └── kustomization.yaml
│   ├── configmap/
│   │   ├── configmap.yaml
│   │   └── kustomization.yaml
│   ├── secrets/
│   │   ├── sealed-secret.yaml        # Secret chiffré (safe à commiter)
│   │   └── kustomization.yaml
│   ├── beeapi/                       # Template BeeAPI générique
│   │   ├── deployment.yaml
│   │   ├── service.yaml
│   │   ├── pvc.yaml
│   │   └── kustomization.yaml
│   ├── core/
│   │   ├── backend/
│   │   │   ├── deployment.yaml
│   │   │   ├── service.yaml
│   │   │   └── kustomization.yaml
│   │   ├── client/
│   │   │   ├── deployment.yaml
│   │   │   ├── service.yaml
│   │   │   └── kustomization.yaml
│   │   └── beehub/
│   │       ├── deployment.yaml
│   │       ├── service-pvc.yaml
│   │       └── kustomization.yaml
│   └── infrastructure/
│       ├── postgres/
│       │   ├── postgres.yaml         # Deployment + Service + PVC
│       │   └── kustomization.yaml
│       └── redis/
│           ├── redis.yaml
│           └── kustomization.yaml
│
└── overlays/
    ├── production/
    │   ├── beeapi/
    │   │   ├── toulouse/
    │   │   │   └── kustomization.yaml  # Patch JSON6902 Toulouse
    │   │   ├── montpellier/
    │   │   │   └── kustomization.yaml
    │   │   ├── lyon/
    │   │   │   └── kustomization.yaml
    │   │   └── staging/
    │   │       └── kustomization.yaml
    │   ├── core/
    │   │   ├── kustomization.yaml
    │   │   └── ingress.yaml            # Ingress AWS ALB
    │   └── infrastructure/
    │       └── kustomization.yaml
    └── staging/
        └── kustomization.yaml
```

---

## 2. Kustomize — base/overlays

### Principe

Le pattern `base/overlays` permet d'avoir un template unique par type de ressource, puis de le spécialiser par environnement ou par instance via des **patches**.

```
base/beeapi/         ← template générique (nom: beeapi-server)
      ↓
overlays/production/beeapi/toulouse/   ← patch → beeapi-server-tlse
overlays/production/beeapi/montpellier/ ← patch → beeapi-server-mpl
```

### Patches BeeAPI — JSON6902

Chaque ville utilise des patches JSON6902 pour personnaliser le template de base. Cette approche est nécessaire car `spec.selector.matchLabels` est **immutable** sur un Deployment — on ne peut pas le modifier via Strategic Merge Patch avec `nameSuffix`.

Exemple pour Toulouse (`overlays/production/beeapi/toulouse/kustomization.yaml`) :

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

resources:
  - ../../../base/beeapi

patches:
  - target:
      kind: Deployment
      name: beeapi-server
    patch: |-
      - op: replace
        path: /metadata/name
        value: beeapi-server-tlse
      - op: replace
        path: /spec/selector/matchLabels/app
        value: beeapi-server-tlse
      - op: replace
        path: /spec/template/metadata/labels/app
        value: beeapi-server-tlse
      - op: replace
        path: /spec/template/spec/containers/0/env/0/value
        value: "Ynov-Toulouse"
      - op: replace
        path: /spec/template/spec/volumes/0/persistentVolumeClaim/claimName
        value: puzzles-tlse-pvc

  - target:
      kind: Service
      name: beeapi-server
    patch: |-
      - op: replace
        path: /metadata/name
        value: beeapi-server-tlse
      - op: replace
        path: /spec/selector/app
        value: beeapi-server-tlse

  - target:
      kind: PersistentVolumeClaim
      name: beeapi-pvc
    patch: |-
      - op: replace
        path: /metadata/name
        value: puzzles-tlse-pvc
```

### Pourquoi pas `nameSuffix` ?

`nameSuffix` renomme les ressources mais **ne met pas à jour** `spec.selector.matchLabels`. Or ce champ est immutable sur un Deployment : une fois créé, il ne peut plus être modifié. Les patches JSON6902 avec `target:` explicite permettent de tout contrôler.

---

## 3. ArgoCD — App of Apps

### Principe

Le pattern **App of Apps** consiste à avoir une Application ArgoCD racine qui crée elle-même les autres Applications ArgoCD. Tout est géré depuis le repo Git.

```
app-of-apps.yaml
    └── crée ──► infrastructure.yaml  (wave -2)
                 core.yaml            (wave -1)
                 beeapi.yaml          (wave 0)
```

### Sync Waves

Les sync waves garantissent l'ordre de déploiement :

| Wave | Application | Raison |
|---|---|---|
| `-2` | Infrastructure (Postgres, Redis) | La DB doit être prête avant le backend |
| `-1` | Core (Backend, Client, BeeHub) | Le backend doit être prêt avant les BeeAPIs |
| `0` | BeeAPI (toutes villes) | Dépend du backend pour l'enregistrement |

L'annotation de wave est posée sur chaque Application ArgoCD :
```yaml
metadata:
  annotations:
    argocd.argoproj.io/sync-wave: "-2"
```

### Application racine

```yaml
# k8s-v2/argocd/app-of-apps.yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: algohive-root
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/thfx31/Plank
    targetRevision: HEAD
    path: k8s-v2/argocd/apps
  destination:
    server: https://kubernetes.default.svc
    namespace: argocd
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
```

---

## 4. Sealed Secrets

### Pourquoi Sealed Secrets ?

Les Secrets Kubernetes sont encodés en base64, **pas chiffrés**. Les commiter dans Git expose les mots de passe. Sealed Secrets chiffre les secrets avec la clé publique du controller dans le cluster — seul ce cluster peut les déchiffrer.

### Fonctionnement

```
Secret K8s (plaintext)
    │
    ▼ kubeseal (chiffrement avec clé publique du cluster)
    │
SealedSecret (chiffré, safe à commiter dans Git)
    │
    ▼ controller sealed-secrets (déchiffrement dans le cluster)
    │
Secret K8s (recréé automatiquement dans le cluster)
```

### Régénérer le SealedSecret

Si les secrets changent ou si le cluster est recréé, il faut régénérer le SealedSecret avec la clé publique du nouveau cluster :

```bash
kubectl create secret generic algohive-secret \
  --namespace algohive \
  --from-literal=POSTGRES_PASSWORD="<valeur>" \
  --from-literal=JWT_SECRET="<valeur>" \
  --from-literal=DEFAULT_PASSWORD="<valeur>" \
  --from-literal=MAIL_PASSWORD="<valeur>" \
  --from-literal=CACHE_PASSWORD="<valeur>" \
  --from-literal=SECRET_KEY="<valeur>" \
  --from-literal=ADMIN_PASSWORD="<valeur>" \
  --dry-run=client -o yaml | \
kubeseal \
  --controller-name=sealed-secrets-controller \
  --controller-namespace=kube-system \
  --format yaml \
  > k8s-v2/base/secrets/sealed-secret.yaml

git add k8s-v2/base/secrets/sealed-secret.yaml
git commit -m "chore: update sealed secret"
git push
```

> ⚠️ Un SealedSecret est lié à un cluster spécifique. Il faut le régénérer si le cluster est recréé.

---

## 5. Ingress ALB

L'Ingress expose les services sur internet via un Application Load Balancer AWS.

```yaml
# k8s-v2/overlays/production/core/ingress.yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: algohive-ingress
  namespace: algohive
  annotations:
    kubernetes.io/ingress.class: alb
    alb.ingress.kubernetes.io/scheme: internet-facing
    alb.ingress.kubernetes.io/target-type: ip
    alb.ingress.kubernetes.io/healthcheck-path: /
    alb.ingress.kubernetes.io/healthcheck-interval-seconds: "30"
spec:
  rules:
    - host: algohive.dev
      http:
        paths:
          - path: /api
            pathType: Prefix
            backend:
              service:
                name: algohive-server
                port:
                  number: 8080
          - path: /
            pathType: Prefix
            backend:
              service:
                name: algohive-client
                port:
                  number: 80
    - host: beehub.algohive.dev
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: beehub
                port:
                  number: 8081
```

### Routing par hostname

L'ALB route les requêtes selon le header `Host` :
- `algohive.dev` → client React (port 80) + API backend sur `/api` (port 8080)
- `beehub.algohive.dev` → BeeHub admin (port 8081)

### Pour aller en production (HTTPS)

Décommenter les annotations dans `ingress.yaml` et renseigner l'ARN du certificat ACM :
```yaml
alb.ingress.kubernetes.io/certificate-arn: arn:aws:acm:eu-west-3:ACCOUNT_ID:certificate/CERT_ID
alb.ingress.kubernetes.io/listen-ports: '[{"HTTP":80},{"HTTPS":443}]'
alb.ingress.kubernetes.io/ssl-redirect: "443"
```

---

## 6. Resource limits et Health Probes

Tous les containers disposent de resource limits et de probes en v2.

### Exemple — Backend

```yaml
resources:
  requests:
    memory: "128Mi"
    cpu: "100m"
  limits:
    memory: "512Mi"
    cpu: "500m"
readinessProbe:
  httpGet:
    path: /api/v1/metrics
    port: 8080
  initialDelaySeconds: 15
  periodSeconds: 10
livenessProbe:
  httpGet:
    path: /api/v1/metrics
    port: 8080
  initialDelaySeconds: 30
  periodSeconds: 20
```

> **Note :** L'endpoint `/health` n'existe pas sur l'API algohive-server. L'endpoint fonctionnel pour les probes est `/api/v1/metrics`.

### Tableau des limites par service

| Service | CPU request | CPU limit | Mem request | Mem limit |
|---|---|---|---|---|
| algohive-server | 100m | 500m | 128Mi | 512Mi |
| algohive-client | 50m | 200m | 64Mi | 128Mi |
| beehub | 50m | 200m | 64Mi | 256Mi |
| beeapi-server | 50m | 200m | 64Mi | 256Mi |
| algohive-db | 100m | 500m | 256Mi | 512Mi |
| algohive-cache | 50m | 200m | 64Mi | 128Mi |

---

## 7. Bootstrap depuis zéro

### Prérequis cluster

- EKS opérationnel avec node group actif
- `kubectl` configuré (`aws eks update-kubeconfig --name algohive --region eu-west-3`)
- AWS Load Balancer Controller installé (voir [README-AWS.md](README-AWS.md))
- EBS CSI Driver installé (voir [README-AWS.md](README-AWS.md))

### Étape 1 — Installer ArgoCD

```bash
kubectl create namespace argocd
kubectl apply -n argocd -f \
  https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
kubectl wait --for=condition=available deployment -l app.kubernetes.io/name=argocd-server \
  -n argocd --timeout=300s
```

### Étape 2 — Installer Sealed Secrets controller

```bash
kubectl apply -f \
  https://github.com/bitnami-labs/sealed-secrets/releases/download/v0.36.0/controller.yaml
```

### Étape 3 — Générer et pousser le SealedSecret

```bash
# (voir section 4 pour la commande complète)
git push
```

### Étape 4 — Bootstrap ArgoCD

```bash
kubectl apply -f k8s-v2/argocd/app-of-apps.yaml
```

### Étape 5 — Vérifier

```bash
# Applications ArgoCD
kubectl get applications -n argocd

# Pods AlgoHive (attendre ~3-5 min)
kubectl get pods -n algohive -w
```

---

## 8. Opérations courantes

### Accéder à ArgoCD UI

```bash
kubectl port-forward svc/argocd-server -n argocd 8888:443
# https://localhost:8888
# Login: admin / $(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d)
```

### Accéder au backend (Swagger)

```bash
kubectl port-forward svc/algohive-server 8001:8080 -n algohive
# http://localhost:8001/swagger/index.html
```

### Accéder à BeeHub

```bash
kubectl port-forward svc/beehub 8002:8081 -n algohive
# http://localhost:8002
# Login: admin / admin
```

### Récupérer les clés API BeeAPI

Les clés API sont générées au démarrage de chaque pod BeeAPI et apparaissent dans les logs :

```bash
kubectl logs -n algohive -l app=beeapi-server-tlse | grep "API key initialized"
kubectl logs -n algohive -l app=beeapi-server-mpl | grep "API key initialized"
kubectl logs -n algohive -l app=beeapi-server-lyon | grep "API key initialized"
kubectl logs -n algohive -l app=beeapi-server-staging | grep "API key initialized"
```

> ⚠️ Si les commandes ne retournent rien, le pod tourne depuis trop longtemps et la ligne de log a été écrasée. Il faut forcer un redémarrage pour régénérer les clés :

```bash
kubectl rollout restart deployment/beeapi-server-tlse deployment/beeapi-server-mpl deployment/beeapi-server-lyon deployment/beeapi-server-staging -n algohive

# Attendre 15 secondes puis récupérer toutes les clés
sleep 15 && \
echo "=== TLSE ===" && kubectl logs -n algohive -l app=beeapi-server-tlse | grep "API key" && \
echo "=== MPL ===" && kubectl logs -n algohive -l app=beeapi-server-mpl | grep "API key" && \
echo "=== LYON ===" && kubectl logs -n algohive -l app=beeapi-server-lyon | grep "API key" && \
echo "=== STAGING ===" && kubectl logs -n algohive -l app=beeapi-server-staging | grep "API key"
```

Ces clés sont à saisir dans BeeHub pour connecter les catalogues.

### Forcer une resynchronisation ArgoCD

```bash
# Via kubectl
kubectl -n argocd patch application algohive-root \
  --type merge \
  -p '{"metadata":{"annotations":{"argocd.argoproj.io/refresh":"hard"}}}'

# Toutes les apps d'un coup
for app in algohive-root algohive-infrastructure algohive-core algohive-beeapi; do
  kubectl -n argocd patch application $app \
    --type merge \
    -p '{"metadata":{"annotations":{"argocd.argoproj.io/refresh":"hard"}}}'
done
```

### Vérifier l'URL ALB publique

```bash
kubectl get ingress -n algohive
# ADDRESS = URL publique de l'ALB
```

### Détruire le namespace (reset complet)

```bash
kubectl delete namespace algohive
# ArgoCD recrée tout automatiquement via selfHeal
```