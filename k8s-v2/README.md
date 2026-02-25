# AlgoHive - K8S v2 (GitOps / ArgoCD / AWS)

## Architecture

```
k8s-v2/
├── base/                         # Manifestes template (DRY)
│   ├── namespace.yaml
│   ├── config/
│   │   └── configmap.yaml
│   ├── infrastructure/
│   │   ├── postgres/
│   │   └── redis/
│   └── apps/
│       ├── backend/
│       ├── client/
│       ├── beehub/
│       └── beeapi/               # Template unique pour tous les campus
├── overlays/
│   ├── production/               # 4 BeeAPIs + backend x2
│   └── staging/                  # 1 BeeAPI + config allégée
├── secrets/
│   ├── secret-template.yaml      # NE PAS COMMITER (gitignore)
│   └── sealed-secret.yaml        # Chiffré - safe à commiter
└── argocd/
    ├── projects/
    │   └── algohive-project.yaml
    └── applications/
        ├── sealed-secrets.yaml   # Bootstrap (wave -1)
        ├── algohive-production.yaml
        └── algohive-staging.yaml
```

---

## Prérequis

- Cluster EKS opérationnel (ou autre)
- ArgoCD installé (`kubectl create namespace argocd && kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml`)
- `kubectl`, `kubeseal` installés en local

---

## 1. Bootstrap - Sealed Secrets

### Installer kubeseal (Mac)
```bash
brew install kubeseal
```

### Déployer le controller via ArgoCD
```bash
kubectl apply -f argocd/applications/sealed-secrets.yaml
```

### Récupérer le certificat public du cluster (après installation du controller)
```bash
kubeseal --fetch-cert \
  --controller-name=sealed-secrets-controller \
  --controller-namespace=kube-system \
  > pub-cert.pem
# ⚠️  pub-cert.pem est PUBLIC, vous pouvez le commiter si vous le souhaitez
```

---

## 2. Configurer les secrets

### Éditer le template
```bash
cp secrets/secret-template.yaml secrets/secret-template.local.yaml
# Éditer secret-template.local.yaml avec les vraies valeurs
```

### Générer le SealedSecret
```bash
kubeseal --format yaml \
  --cert pub-cert.pem \
  < secrets/secret-template.local.yaml \
  > secrets/sealed-secret.yaml
```

### Vérifier le .gitignore
```bash
echo "secrets/secret-template.local.yaml" >> .gitignore
echo "pub-cert.pem" >> .gitignore   # optionnel, le cert est public
```

---

## 3. Déployer avec le pattern App of Apps

C'est **la seule commande manuelle** à faire une fois ArgoCD installé :

```bash
kubectl apply -f argocd/root-app.yaml
```

ArgoCD déroule ensuite tout automatiquement dans l'ordre suivant grâce aux sync waves :

| Wave | Application | Rôle |
|------|-------------|------|
| `-1` | `sealed-secrets` | Controller Sealed Secrets (bootstrap) |
| `0`  | `algohive-project` | AppProject ArgoCD (RBAC) |
| `1`  | `algohive-production` | Stack complète production |
| `1`  | `algohive-staging` | Stack staging |

### Structure App of Apps

```
argocd/
├── root-app.yaml          ← kubectl apply -f (unique commande manuelle)
├── projects/
│   └── algohive-project.yaml
└── apps/                  ← découvert et géré automatiquement par root-app
    ├── sealed-secrets.yaml
    ├── algohive-project.yaml
    ├── algohive-production.yaml
    └── algohive-staging.yaml
```

---

## 4. Vérifier le déploiement

```bash
# État des Applications ArgoCD
kubectl get applications -n argocd

# État des pods AlgoHive
kubectl get pods -n algohive

# Logs d'un pod
kubectl logs -n algohive deployment/algohive-server

# Accès ArgoCD UI (port-forward)
kubectl port-forward svc/argocd-server -n argocd 8080:443
```

---

## 5. Ajouter un nouveau campus BeeAPI

1. Copier `overlays/production/beeapi-toulouse.yaml`
2. Remplacer `toulouse` par le nom du campus
3. Changer la valeur de `SERVER_NAME`
4. Ajouter le fichier dans `overlays/production/kustomization.yaml` (resources)
5. Ajouter l'URL dans `base/config/configmap.yaml` (BEE_APIS et DISCOVERY_URLS)
6. Commit + push → ArgoCD sync automatique ✅

---

## 6. Tester en local avec kind

```bash
# Créer un cluster kind
kind create cluster --name algohive

# Installer ArgoCD
kubectl create namespace argocd
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

# Tester le rendu kustomize sans appliquer
kubectl kustomize overlays/production

# Appliquer directement (sans ArgoCD)
kubectl apply -k overlays/production
```

---

## Améliorations futures (v3)

- [ ] Ingress + AWS Load Balancer Controller + cert-manager (TLS)
- [ ] HorizontalPodAutoscaler sur le backend
- [ ] NetworkPolicies (isolation réseau entre services)
- [ ] PodDisruptionBudget pour la haute dispo
- [ ] Monitoring : Prometheus + Grafana via ArgoCD
- [ ] Image tag pinning (éviter `:latest` en production)
