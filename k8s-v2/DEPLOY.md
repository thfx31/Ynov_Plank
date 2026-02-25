# AlgoHive — Guide de déploiement

> **À lire avant tout.** Ce guide est destiné à la personne qui déploie AlgoHive sur le cluster AWS. Il suffit de suivre les étapes dans l'ordre.

---

## Ce que tu vas déployer

AlgoHive est une plateforme d'apprentissage du code. Elle se compose de :

| Service | Rôle | Port interne |
|---------|------|-------------|
| `algohive-client` | Interface web étudiants | 80 |
| `algohive-server` | API backend (auth, scores) | 8080 |
| `beehub` | Back-office professeurs | 8081 |
| `beeapi-toulouse/lyon/montpellier/staging` | Catalogues d'exercices par campus | 5000 |
| `algohive-db` | PostgreSQL (données persistantes) | 5432 |
| `algohive-cache` | Redis (sessions, cache) | 6379 |

Le déploiement est entièrement **GitOps** : ArgoCD surveille ce repo Git et applique automatiquement toute modification poussée sur `main`.

---

## Prérequis

Vérifier que tu as :

- [ ] `kubectl` installé et configuré sur le cluster AWS (`kubectl get nodes` doit répondre)
- [ ] ArgoCD installé sur le cluster (namespace `argocd` existant)
- [ ] Accès à ce repo Git
- [ ] `git` installé en local

---

## Déploiement — 2 options

### Option A — Script automatique (recommandé)

Un script fait tout à ta place : installe kubeseal, te demande les mots de passe, chiffre les secrets, et surveille le déploiement.

```bash
# Cloner le repo
git clone https://github.com/thfx31/Plank.git
cd Plank/k8s-v2

# Lancer le bootstrap
chmod +x bootstrap.sh
./bootstrap.sh
```

Le script te guidera étape par étape. Il te demandera de confirmer le cluster cible avant de faire quoi que ce soit.

---

### Option B — Pas à pas manuel

Si tu préfères comprendre chaque étape ou que le script échoue.

#### Étape 1 — Installer kubeseal

```bash
# Mac
brew install kubeseal

# Linux (amd64)
curl -sSL https://github.com/bitnami-labs/sealed-secrets/releases/download/v0.27.0/kubeseal-0.27.0-linux-amd64.tar.gz | tar -xz
sudo mv kubeseal /usr/local/bin/
```

#### Étape 2 — Déployer la root-app ArgoCD

Cette commande unique déclenche tout le reste :

```bash
kubectl apply -f argocd/root-app.yaml
```

ArgoCD va déployer automatiquement dans cet ordre :

```
wave -1 → Sealed Secrets controller  (chiffrement des secrets)
wave  0 → AlgoHive AppProject        (permissions ArgoCD)
wave  1 → algohive-production        (toute la stack)
wave  1 → algohive-staging           (environnement de test)
```

#### Étape 3 — Attendre le controller Sealed Secrets

```bash
# Attendre que ce pod soit Running
kubectl get pods -n kube-system | grep sealed-secrets
# → sealed-secrets-controller-xxxx   1/1   Running
```

#### Étape 4 — Récupérer le certificat du cluster

```bash
kubeseal --fetch-cert \
  --controller-name=sealed-secrets-controller \
  --controller-namespace=kube-system \
  > pub-cert.pem
```

#### Étape 5 — Générer les secrets chiffrés

Éditer `secrets/secret-template.yaml` avec les vraies valeurs, puis :

```bash
kubeseal --format yaml \
  --cert pub-cert.pem \
  < secrets/secret-template.yaml \
  > secrets/sealed-secret.yaml
```

#### Étape 6 — Commiter et pousser

```bash
git add secrets/sealed-secret.yaml
git commit -m "chore: sealed secret"
git push
```

ArgoCD détecte le push et finalise le déploiement automatiquement.

---

## Vérification post-déploiement

```bash
# 1. État des Applications ArgoCD (tout doit être Synced/Healthy)
kubectl get applications -n argocd

# 2. État des pods (tout doit être Running)
kubectl get pods -n algohive

# 3. État des volumes (tout doit être Bound)
kubectl get pvc -n algohive
```

**Résultat attendu :**

```
NAME                           READY   STATUS    
algohive-client-xxxx           1/1     Running
algohive-server-xxxx           1/1     Running   ← x2 en production
algohive-db-xxxx               1/1     Running
algohive-cache-xxxx            1/1     Running
beehub-xxxx                    1/1     Running
beeapi-server-toulouse-xxxx    1/1     Running
beeapi-server-lyon-xxxx        1/1     Running
beeapi-server-montpellier-xxxx 1/1     Running
beeapi-server-staging-xxxx     1/1     Running
```

### Accéder à l'UI ArgoCD

```bash
kubectl port-forward svc/argocd-server -n argocd 8080:443
# Ouvrir https://localhost:8080 (accepter le certificat auto-signé)

# Mot de passe admin :
kubectl get secret argocd-initial-admin-secret -n argocd \
  -o jsonpath="{.data.password}" | base64 -d && echo
```

### Tester les services

```bash
# Backend
kubectl port-forward svc/algohive-server -n algohive 8080:8080
curl http://localhost:8080/health

# Frontend
kubectl port-forward svc/algohive-client -n algohive 3000:80
# Ouvrir http://localhost:3000
```

---

## Résolution des problèmes fréquents

### Pods en `Pending`

Les volumes ne se bindent pas. Sur EKS, vérifier le StorageClass disponible :

```bash
kubectl get storageclass
```

Si tu vois `gp2` ou `gp3`, décommenter la ligne `storageClassName` dans les fichiers PVC (`base/infrastructure/postgres/pvc.yaml`, etc.) et pousser.

### Pods en `CrashLoopBackOff`

Regarder les logs :

```bash
kubectl logs -n algohive deployment/algohive-server --previous
kubectl logs -n algohive deployment/algohive-db --previous
```

Souvent : mauvais mot de passe dans les secrets → régénérer `sealed-secret.yaml` avec les bonnes valeurs.

### ArgoCD ne sync pas

```bash
# Vérifier que le repo est accessible
kubectl get applications -n argocd algohive-root -o yaml | grep -A5 conditions

# Forcer un sync manuel
kubectl patch application algohive-root -n argocd \
  --type merge -p '{"operation":{"sync":{}}}'
```

### Sealed Secrets : `no key could decrypt`

Le `sealed-secret.yaml` a été généré avec le certificat d'un autre cluster. Reprendre depuis l'étape 4 (récupérer le cert du bon cluster).

---

## Gestion quotidienne

### Modifier la configuration

Éditer `base/config/configmap.yaml`, commiter, pousser → ArgoCD sync automatiquement.

### Mettre à jour une image

Les déploiements utilisent `:latest`. Pour forcer le rechargement :

```bash
kubectl rollout restart deployment/algohive-server -n algohive
```

### Ajouter un campus BeeAPI

1. Copier `overlays/production/beeapi-toulouse.yaml` → `beeapi-<campus>.yaml`
2. Changer `toulouse` → nom du campus et `SERVER_NAME`
3. Ajouter dans `overlays/production/kustomization.yaml`
4. Ajouter l'URL dans `base/config/configmap.yaml` (champs `BEE_APIS` et `DISCOVERY_URLS`)
5. Commit + push → déployé automatiquement

---

## Contacts

Projet livré par : **[ton nom]**
Repo : https://github.com/thfx31/Plank
Questions : [ton contact]
