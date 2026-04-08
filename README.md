# 🐝 Plank — AlgoHive on Kubernetes

> Projet académique — Mastère Infrastructures, Sécurité & Cloud  
> Migration d'une architecture microservices Docker Compose vers Kubernetes avec GitOps (ArgoCD) sur AWS EKS.

---

## Contexte

**AlgoHive** est une plateforme d'apprentissage du code basée sur une architecture microservices. Ce projet part du [code source officiel AlgoHive](https://github.com/AlgoHive-Coding-Puzzles/AlgoHive-Infra) et a pour objectif de :

1. Transformer les fichiers `docker-compose` en manifestes Kubernetes production-ready
2. Implémenter un workflow **GitOps** avec ArgoCD (pattern App of Apps)
3. Déployer l'ensemble sur un cluster **AWS EKS**
4. Sécuriser les secrets via **Sealed Secrets** (Bitnami)

---

## Architecture globale

```
                        ┌─────────────────────────────────────────┐
                        │         AWS EKS — eu-west-3              │
                        │         Namespace: algohive               │
                        │                                           │
   Internet ──── ALB ──►│  algohive-client (React/Nginx :80)       │
                        │  algohive-server (API Go :8080)          │
                        │  beehub (Admin :8081)                    │
                        │                                           │
                        │  BeeAPI Toulouse    (:5000)              │
                        │  BeeAPI Montpellier (:5000)              │
                        │  BeeAPI Lyon        (:5000)              │
                        │  BeeAPI Staging     (:5000)              │
                        │                                           │
                        │  Postgres (:5432)   Redis (:6379)        │
                        └─────────────────────────────────────────┘
                                        ▲
                                        │ GitOps sync
                                        │
                              ┌─────────────────┐
                              │  ArgoCD          │
                              │  App of Apps     │
                              └────────┬─────────┘
                                       │
                              ┌────────▼─────────┐
                              │  GitHub Repo      │
                              │  (k8s-v2/)        │
                              └──────────────────┘
```

### Services

| Service | Rôle | Port |
|---|---|---|
| `algohive-client` | Interface étudiant (React) | 80 |
| `algohive-server` | API backend, auth JWT, scores | 8080 |
| `beehub` | Back-office professeurs | 8081 |
| `beeapi-server-tlse` | Catalogue puzzles Toulouse | 5000 |
| `beeapi-server-mpl` | Catalogue puzzles Montpellier | 5000 |
| `beeapi-server-lyon` | Catalogue puzzles Lyon | 5000 |
| `beeapi-server-staging` | Catalogue puzzles Staging | 5000 |
| `algohive-db` | PostgreSQL (données, auth) | 5432 |
| `algohive-cache` | Redis (sessions, cache) | 6379 |

---

## Stack technique

| Couche | Technologie |
|---|---|
| Cloud | AWS EKS (eu-west-3) |
| Orchestration | Kubernetes 1.35 |
| GitOps | ArgoCD — App of Apps pattern |
| Config management | Kustomize (base/overlays) |
| Secret management | Bitnami Sealed Secrets v0.36.0 |
| Exposition | AWS Load Balancer Controller + ALB Ingress |
| Stockage | AWS EBS via CSI Driver (gp2) |

---

## Structure du repo

```
Plank/
├── README.md                   ← Ce fichier
├── docs/
│   ├── README-AWS.md           ← Déploiement AWS EKS pas à pas
│   └── README-TECH.md          ← Architecture k8s-v2, Kustomize, ArgoCD
├── k8s-v1/                     ← PoC initial (Docker Compose → K8s basique)
│   └── ...
└── k8s-v2/                     ← Version production (Kustomize + ArgoCD)
    ├── argocd/                 ← App of Apps ArgoCD
    ├── base/                   ← Manifestes de base (templates)
    └── overlays/               ← Configurations par environnement
```

---

## Itérations du projet

### v1 — PoC Kind (local)
Première migration Docker Compose → Kubernetes, déployée sur un cluster local `kind`. Objectif : valider la faisabilité. Voir [`k8s-v1/`](k8s-v1/).

**Limitations identifiées :**
- Duplication massive des manifestes BeeAPI (x4)
- Secrets en clair dans le repo Git
- Pas de resource limits ni health probes
- Pas d'Ingress, accès uniquement via port-forward
- Pas de structure GitOps

### v2 — Production EKS + GitOps
Refactoring complet adressant toutes les limitations de la v1. Voir [`k8s-v2/`](k8s-v2/).

**Améliorations apportées :**
- Template BeeAPI unique via Kustomize (zéro duplication)
- Secrets chiffrés via Sealed Secrets (safe à commiter dans Git)
- Resource limits + readiness/liveness probes sur tous les containers
- Ingress AWS ALB (exposition publique)
- ArgoCD App of Apps avec sync waves (déploiement ordonné)

---

## Démarrage rapide

### Prérequis
- Cluster EKS opérationnel + `kubectl` configuré
- ArgoCD installé dans le namespace `argocd`
- Sealed Secrets controller installé dans `kube-system`

### Bootstrap en une commande

```bash
kubectl apply -f k8s-v2/argocd/app-of-apps.yaml
```

ArgoCD prend en charge le reste : il déploie l'infrastructure, puis les apps core, puis les BeeAPIs — dans le bon ordre grâce aux sync waves.

### Vérification

```bash
# État des applications ArgoCD
kubectl get applications -n argocd

# État des pods AlgoHive
kubectl get pods -n algohive
```

---

## Documentation

| Document | Description |
|---|---|
| [docs/README-AWS.md](docs/README-AWS.md) | Déploiement complet AWS EKS : IAM, VPC, EKS, EBS, ALB, ArgoCD — toutes les commandes et tous les problèmes rencontrés |
| [docs/README-TECH.md](docs/README-TECH.md) | Architecture technique k8s-v2 : Kustomize, ArgoCD, Sealed Secrets, structure des fichiers |
| [k8s-v1/README.md](k8s-v1/README.md) | Documentation du PoC v1 (Kind local) |
| [k8s-v1/docs/SETUP_POC_kind.md](k8s-v1/docs/SETUP_POC_kind.md) | Procédure de déploiement du PoC v1 |