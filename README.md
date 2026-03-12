# AlgoHive — Infrastructure K8s v2 (GitOps / ArgoCD)

---

## Structure du repo

```
k8s-v2/
├── argocd/
│   ├── app-of-apps.yaml          # Application racine ArgoCD (à appliquer manuellement 1 fois)
│   └── apps/
│       ├── infrastructure.yaml   # Postgres + Redis (wave -2)
│       ├── core.yaml             # Backend + Client + BeeHub (wave -1)
│       └── beeapi.yaml           # Tous les BeeAPI campus (wave 0)
│
├── base/                         # Templates génériques réutilisables
│   ├── namespace/
│   ├── configmap/
│   ├── secrets/                  # SealedSecret (chiffré)
│   ├── beeapi/                   # Template unique BeeAPI ← le cœur du refactoring
│   ├── core/{backend,client,beehub}/
│   └── infrastructure/{postgres,redis}/
│
└── overlays/
    ├── production/
    │   ├── beeapi/{toulouse,montpellier,lyon,staging}/
    │   ├── core/                 # + Ingress AWS ALB
    │   └── infrastructure/
    └── staging/
```

---

## Prérequis locaux

```bash
# kubectl (connexion au cluster EKS)
curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"

# kubeseal (CLI Sealed Secrets)
KUBESEAL_VERSION=0.36.0
curl -L "https://github.com/bitnami-labs/sealed-secrets/releases/download/v${KUBESEAL_VERSION}/kubeseal-${KUBESEAL_VERSION}-linux-amd64.tar.gz" | tar xz
sudo mv kubeseal /usr/local/bin/

# kustomize (pour tester les manifestes localement)
curl -s "https://raw.githubusercontent.com/kubernetes-sigs/kustomize/master/hack/install_kustomize.sh" | bash
```

---

## Procédure Sealed Secrets

### 1. Installer le contrôleur sur le cluster EKS

```bash
# Le contrôleur génère une paire de clés RSA au démarrage.
# Il déchiffre les SealedSecrets à la volée dans le cluster.
kubectl apply -f https://github.com/bitnami-labs/sealed-secrets/releases/download/v0.36.0/controller.yaml

# Vérifier que le contrôleur est up
kubectl get pods -n kube-system -l name=sealed-secrets-controller
```

### 2. Générer le SealedSecret algohive-secret

```bash
# ⚠️  NE JAMAIS commiter ce fichier temporaire dans Git !
kubectl create secret generic algohive-secret \
  --namespace algohive \
  --from-literal=POSTGRES_PASSWORD='CHANGE_ME_strong_password' \
  --from-literal=JWT_SECRET='CHANGE_ME_very_long_random_string_min_32_chars' \
  --from-literal=DEFAULT_PASSWORD='CHANGE_ME_default_user_password' \
  --from-literal=MAIL_PASSWORD='CHANGE_ME_smtp_app_password' \
  --from-literal=CACHE_PASSWORD='' \
  --from-literal=SECRET_KEY='CHANGE_ME_another_random_secret' \
  --from-literal=ADMIN_PASSWORD='CHANGE_ME_admin_password' \
  --dry-run=client -o yaml | \
kubeseal \
  --controller-name=sealed-secrets-controller \
  --controller-namespace=kube-system \
  --format yaml \
  > base/secrets/sealed-secret.yaml

# Vérifier que le fichier généré contient bien "encryptedData"
cat base/secrets/sealed-secret.yaml

# Commiter le SealedSecret (safe, chiffré avec la clé du cluster)
git add base/secrets/sealed-secret.yaml
git commit -m "feat: add sealed secrets for algohive"
git push
```

### 3. Vérifier que K8s déchiffre correctement

```bash
# Après que ArgoCD ait synchro le SealedSecret :
kubectl get secret algohive-secret -n algohive
# Doit afficher le Secret (pas le SealedSecret)

# Pour voir les valeurs déchiffrées (attention, base64) :
kubectl get secret algohive-secret -n algohive -o jsonpath='{.data.POSTGRES_PASSWORD}' | base64 -d
```

---

## Bootstrap ArgoCD (1 seule fois)

```bash
# 1. Installer ArgoCD sur le cluster
kubectl create namespace argocd
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

# 2. Attendre que ArgoCD soit prêt
kubectl wait --for=condition=available deployment/argocd-server -n argocd --timeout=120s

# 3. Récupérer le mot de passe admin initial
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d && echo

# 4. Appliquer l'App of Apps (la seule commande kubectl apply manuelle)
kubectl apply -f argocd/app-of-apps.yaml

# ArgoCD va automatiquement créer les 3 Applications enfants
# et déployer toute la stack dans l'ordre (sync waves).
```

---

## Tester les manifestes localement (sans cluster)

```bash
# Vérifier que Kustomize génère les bons manifestes pour chaque overlay
kustomize build overlays/production/infrastructure
kustomize build overlays/production/core
kustomize build overlays/production/beeapi

# Compter les ressources générées (doit être cohérent)
kustomize build overlays/production/beeapi | grep "^kind:" | sort | uniq -c
```

---

## Ajouter un nouveau campus BeeAPI

1. Copier un overlay existant :
```bash
cp -r overlays/production/beeapi/lyon overlays/production/beeapi/bordeaux
```

2. Éditer `overlays/production/beeapi/bordeaux/kustomization.yaml` :
   - Changer `nameSuffix: "-bordeaux"`
   - Changer `SERVER_NAME: "Ynov-Bordeaux"`
   - Changer `claimName: puzzles-pvc-bordeaux`
   - Changer le selector `app: beeapi-server-bordeaux`

3. Ajouter `bordeaux` dans `overlays/production/beeapi/kustomization.yaml`

4. Ajouter `http://beeapi-server-bordeaux:5000` dans `base/configmap/configmap.yaml`
   (champs `BEE_APIS` et `DISCOVERY_URLS`)

5. Commiter et pousser → ArgoCD déploie automatiquement.

---

## Récupérer une clé API BeeAPI

```bash
# Remplacer "tlse" par le campus voulu : mpl, lyon, staging
kubectl logs -n algohive \
  $(kubectl get pod -n algohive -l app=beeapi-server-tlse -o jsonpath='{.items[0].metadata.name}') \
  | grep "API key initialized"
```
