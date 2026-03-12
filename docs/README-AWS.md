# Déploiement AWS EKS — AlgoHive (Plank v2)

Ce document retrace **toutes les étapes** réalisées pour déployer l'architecture AlgoHive sur AWS EKS, avec ArgoCD en mode GitOps. Il inclut les commandes utilisées, les problèmes rencontrés et leurs solutions.

---

## Sommaire

1. [Prérequis](#1-prérequis)
2. [Configuration AWS CLI](#2-configuration-aws-cli)
3. [IAM — Rôles EKS](#3-iam--rôles-eks)
4. [VPC — CloudFormation](#4-vpc--cloudformation)
5. [EKS — Cluster](#5-eks--cluster)
6. [EKS — Node Group](#6-eks--node-group)
7. [kubectl — Connexion au cluster](#7-kubectl--connexion-au-cluster)
8. [EBS CSI Driver](#8-ebs-csi-driver)
9. [AWS Load Balancer Controller](#9-aws-load-balancer-controller)
10. [ArgoCD](#10-argocd)
11. [Sealed Secrets](#11-sealed-secrets)
12. [Bootstrap — App of Apps ArgoCD](#12-bootstrap--app-of-apps-argocd)
13. [Vérification du déploiement](#13-vérification-du-déploiement)
14. [Accès public via ALB](#14-accès-public-via-alb)
15. [Problèmes rencontrés et solutions](#15-problèmes-rencontrés-et-solutions)

---

## 1. Prérequis

Outils nécessaires sur le poste de travail :

| Outil | Usage |
|---|---|
| `aws` CLI | Interaction avec AWS |
| `kubectl` | Gestion du cluster K8s |
| `helm` | Installation de charts (ArgoCD, ALB Controller) |
| `kubeseal` | Chiffrement des secrets (Sealed Secrets) |
| `git` | Gestion du repo GitOps |

Installation de `kubectl` :
```bash
curl -LO "https://dl.k8s.io/release/$(curl -Ls https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl
```

---

## 2. Configuration AWS CLI

```bash
aws configure
# AWS Access Key ID: <votre_access_key>
# AWS Secret Access Key: <votre_secret_key>
# Default region name: eu-west-3
# Default output format: json
```

Vérification :
```bash
aws sts get-caller-identity
```

> **Compte utilisé :** `302263045490` — région `eu-west-3` (Paris)

---

## 3. IAM — Rôles EKS

### 3.1 Rôle pour le Control Plane EKS

Créer un fichier `eks-trust-policy.json` :
```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": { "Service": "eks.amazonaws.com" },
      "Action": "sts:AssumeRole"
    }
  ]
}
```

```bash
aws iam create-role \
  --role-name AlgoHiveEKSClusterRole \
  --assume-role-policy-document file://eks-trust-policy.json

aws iam attach-role-policy \
  --role-name AlgoHiveEKSClusterRole \
  --policy-arn arn:aws:iam::aws:policy/AmazonEKSClusterPolicy
```

### 3.2 Rôle pour les Nodes (EC2)

Créer un fichier `node-trust-policy.json` :
```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": { "Service": "ec2.amazonaws.com" },
      "Action": "sts:AssumeRole"
    }
  ]
}
```

```bash
aws iam create-role \
  --role-name AlgoHiveEKSNodeRole \
  --assume-role-policy-document file://node-trust-policy.json

aws iam attach-role-policy \
  --role-name AlgoHiveEKSNodeRole \
  --policy-arn arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy

aws iam attach-role-policy \
  --role-name AlgoHiveEKSNodeRole \
  --policy-arn arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy

aws iam attach-role-policy \
  --role-name AlgoHiveEKSNodeRole \
  --policy-arn arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly
```

---

## 4. VPC — CloudFormation

Déploiement du VPC via le template officiel AWS pour EKS (subnets privés + publics) :

```bash
aws cloudformation create-stack \
  --stack-name algohive-vpc \
  --template-url https://s3.us-west-2.amazonaws.com/amazon-eks/cloudformation/2020-10-29/amazon-eks-vpc-private-subnets.yaml \
  --capabilities CAPABILITY_IAM

# Attendre la fin du déploiement
aws cloudformation wait stack-create-complete --stack-name algohive-vpc
```

Récupérer les IDs créés :
```bash
aws cloudformation describe-stacks \
  --stack-name algohive-vpc \
  --query "Stacks[0].Outputs"
```

> **Ressources créées :** VPC, 2 subnets publics, 2 subnets privés, Internet Gateway, NAT Gateway, Route Tables.

---

## 5. EKS — Cluster

Créé via la console AWS EKS :

- **Nom :** `algohive`
- **Version Kubernetes :** `1.31`
- **Région :** `eu-west-3`
- **Rôle IAM :** `AlgoHiveEKSClusterRole`
- **VPC :** stack `algohive-vpc`
- **Subnets :** publics + privés
- **Accès API :** Public

> La création du cluster prend environ 10-15 minutes.

---

## 6. EKS — Node Group

Créé via la console AWS EKS, dans le cluster `algohive` :

- **Nom :** `algohive-nodes`
- **Rôle IAM :** `AlgoHiveEKSNodeRole`
- **Type d'instance :** `t3.medium`
- **Nombre de nodes :** 2 (min: 1, max: 3)
- **Disque :** 20 GB gp2
- **Subnets :** privés (les nodes ne sont pas exposés directement)

> La création du node group prend environ 5-10 minutes.

---

## 7. kubectl — Connexion au cluster

```bash
aws eks update-kubeconfig \
  --region eu-west-3 \
  --name algohive

# Vérification
kubectl get nodes
```

Résultat attendu :
```
NAME                                        STATUS   ROLES    AGE   VERSION
ip-192-168-x-x.eu-west-3.compute.internal  Ready    <none>   Xm    v1.31.x
ip-192-168-x-x.eu-west-3.compute.internal  Ready    <none>   Xm    v1.31.x
```

---

## 8. EBS CSI Driver

EKS 1.23+ nécessite l'installation explicite du driver EBS CSI pour que les `PersistentVolumeClaims` fonctionnent. Sans ce driver, les PVCs restent bloqués en `Pending`.

### 8.1 Activer l'OIDC Provider

```bash
# Récupérer l'OIDC ID du cluster
aws eks describe-cluster \
  --name algohive \
  --query "cluster.identity.oidc.issuer" \
  --output text

# Associer l'OIDC provider IAM
aws iam create-open-id-connect-provider \
  --url https://oidc.eks.eu-west-3.amazonaws.com/id/<OIDC_ID> \
  --client-id-list sts.amazonaws.com \
  --thumbprint-list <thumbprint>
```

### 8.2 Créer le rôle IAM pour EBS CSI

Créer un fichier `ebs-trust-policy.json` :
```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "arn:aws:iam::302263045490:oidc-provider/oidc.eks.eu-west-3.amazonaws.com/id/<OIDC_ID>"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "oidc.eks.eu-west-3.amazonaws.com/id/<OIDC_ID>:sub": "system:serviceaccount:kube-system:ebs-csi-controller-sa"
        }
      }
    }
  ]
}
```

```bash
aws iam create-role \
  --role-name AmazonEKS_EBS_CSI_DriverRole \
  --assume-role-policy-document file://ebs-trust-policy.json

aws iam attach-role-policy \
  --role-name AmazonEKS_EBS_CSI_DriverRole \
  --policy-arn arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy
```

### 8.3 Installer l'addon EKS

Via la console AWS EKS :
- Cluster `algohive` → Add-ons → **aws-ebs-csi-driver**
- Sélectionner le rôle IAM : `AmazonEKS_EBS_CSI_DriverRole`

Ou via CLI :
```bash
aws eks create-addon \
  --cluster-name algohive \
  --addon-name aws-ebs-csi-driver \
  --service-account-role-arn arn:aws:iam::302263045490:role/AmazonEKS_EBS_CSI_DriverRole
```

---

## 9. AWS Load Balancer Controller

Permet de provisionner automatiquement un ALB AWS à partir des ressources `Ingress` Kubernetes.

### 9.1 Créer la policy IAM

```bash
curl -O https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/v2.11.0/docs/install/iam_policy.json

aws iam create-policy \
  --policy-name AWSLoadBalancerControllerIAMPolicy \
  --policy-document file://iam_policy.json
```

### 9.2 Créer le rôle IAM IRSA

Créer un fichier `alb-trust-policy.json` :
```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "arn:aws:iam::302263045490:oidc-provider/oidc.eks.eu-west-3.amazonaws.com/id/<OIDC_ID>"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "oidc.eks.eu-west-3.amazonaws.com/id/<OIDC_ID>:sub": "system:serviceaccount:kube-system:aws-load-balancer-controller"
        }
      }
    }
  ]
}
```

```bash
aws iam create-role \
  --role-name AmazonEKSLoadBalancerControllerRole \
  --assume-role-policy-document file://alb-trust-policy.json

aws iam attach-role-policy \
  --role-name AmazonEKSLoadBalancerControllerRole \
  --policy-arn arn:aws:iam::302263045490:policy/AWSLoadBalancerControllerIAMPolicy
```

### 9.3 Installer via Helm

```bash
helm repo add eks https://aws.github.io/eks-charts
helm repo update

helm install aws-load-balancer-controller eks/aws-load-balancer-controller \
  -n kube-system \
  --set clusterName=algohive \
  --set serviceAccount.create=true \
  --set serviceAccount.name=aws-load-balancer-controller \
  --set serviceAccount.annotations."eks\.amazonaws\.com/role-arn"=arn:aws:iam::302263045490:role/AmazonEKSLoadBalancerControllerRole

# Vérification
kubectl get pods -n kube-system | grep load-balancer
```

---

## 10. ArgoCD

### 10.1 Installation

```bash
kubectl create namespace argocd

kubectl apply -n argocd -f \
  https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

# Attendre que tous les pods soient Running
kubectl wait --for=condition=available deployment -l app.kubernetes.io/name=argocd-server \
  -n argocd --timeout=300s
```

### 10.2 Accès à l'UI

```bash
# Port-forward (dans un terminal dédié)
kubectl port-forward svc/argocd-server -n argocd 8888:443

# Récupérer le mot de passe admin initial
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d
```

UI accessible sur : `https://localhost:8888`  
Login : `admin` / `<mot_de_passe_récupéré>`

### 10.3 Fix CRD ApplicationSet

Le controller `argocd-applicationset-controller` crashait au démarrage car le CRD `ApplicationSet` n'était pas installé :

```bash
kubectl apply -f \
  https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/crds/applicationset-crd.yaml

kubectl rollout restart deployment/argocd-applicationset-controller -n argocd
```

---

## 11. Sealed Secrets

Permet de stocker des secrets chiffrés dans Git. Seul le controller dans le cluster peut les déchiffrer.

### 11.1 Installation du controller

```bash
kubectl apply -f \
  https://github.com/bitnami-labs/sealed-secrets/releases/download/v0.36.0/controller.yaml

# Vérification
kubectl get pods -n kube-system | grep sealed-secrets
```

### 11.2 Installation de kubeseal (CLI)

```bash
KUBESEAL_VERSION=0.36.0
curl -OL "https://github.com/bitnami-labs/sealed-secrets/releases/download/v${KUBESEAL_VERSION}/kubeseal-${KUBESEAL_VERSION}-linux-amd64.tar.gz"
tar -xvzf kubeseal-${KUBESEAL_VERSION}-linux-amd64.tar.gz kubeseal
sudo install -m 755 kubeseal /usr/local/bin/kubeseal
```

### 11.3 Générer le SealedSecret

Créer d'abord un secret K8s classique en mémoire (ne pas appliquer dans le cluster) :

```bash
kubectl create secret generic algohive-secret \
  --namespace algohive \
  --from-literal=POSTGRES_PASSWORD="algohive" \
  --from-literal=JWT_SECRET="algohive" \
  --from-literal=DEFAULT_PASSWORD="algohive" \
  --from-literal=MAIL_PASSWORD="" \
  --from-literal=CACHE_PASSWORD="" \
  --from-literal=SECRET_KEY="superSecretPassword" \
  --from-literal=ADMIN_PASSWORD="admin" \
  --dry-run=client -o yaml | \
kubeseal \
  --controller-name=sealed-secrets-controller \
  --controller-namespace=kube-system \
  --format yaml \
  > k8s-v2/base/secrets/sealed-secret.yaml

# Pousser dans Git
git add k8s-v2/base/secrets/sealed-secret.yaml
git commit -m "feat: add sealed secret"
git push
```

---

## 12. Bootstrap — App of Apps ArgoCD

Le pattern **App of Apps** permet à ArgoCD de se gérer lui-même à partir du repo Git.

### 12.1 Structure ArgoCD dans le repo

```
k8s-v2/argocd/
├── app-of-apps.yaml          # Application racine
└── apps/
    ├── infrastructure.yaml   # Wave -2 (Postgres, Redis)
    ├── core.yaml             # Wave -1 (Backend, Client, BeeHub)
    └── beeapi.yaml           # Wave 0  (BeeAPI par ville)
```

### 12.2 Appliquer l'App racine

```bash
# Une seule commande pour tout bootstrapper
kubectl apply -f k8s-v2/argocd/app-of-apps.yaml

# Vérifier la synchronisation
kubectl get applications -n argocd
```

### 12.3 Forcer une synchronisation

Via CLI :
```bash
kubectl -n argocd patch application algohive-root \
  --type merge \
  -p '{"metadata":{"annotations":{"argocd.argoproj.io/refresh":"hard"}}}'
```

Via UI : Application → **SYNC** → cocher **FORCE** → **SYNCHRONIZE**

---

## 13. Vérification du déploiement

### 13.1 État des pods

```bash
kubectl get pods -n algohive
```

Résultat attendu (tous `Running`) :
```
NAME                                    READY   STATUS    RESTARTS
algohive-cache-xxx                      1/1     Running   0
algohive-client-xxx                     1/1     Running   0
algohive-db-xxx                         1/1     Running   0
algohive-server-xxx                     1/1     Running   0
beeapi-server-lyon-xxx                  1/1     Running   0
beeapi-server-mpl-xxx                   1/1     Running   0
beeapi-server-staging-xxx               1/1     Running   0
beeapi-server-tlse-xxx                  1/1     Running   0
beehub-xxx                              1/1     Running   0
```

### 13.2 Test de l'API backend

```bash
kubectl port-forward svc/algohive-server 8001:8080 -n algohive
```

Swagger UI : `http://localhost:8001/swagger/index.html`

### 13.3 Test de BeeHub

```bash
kubectl port-forward svc/beehub 8002:8081 -n algohive
```

Interface admin : `http://localhost:8002`  
Login : `admin` / `admin`

---

## 14. Accès public via ALB

L'Ingress AWS ALB expose les services publiquement sans port-forward.

### 14.1 Récupérer l'URL ALB

```bash
kubectl get ingress -n algohive
```

```
NAME               CLASS    HOSTS                              ADDRESS
algohive-ingress   <none>   algohive.dev,beehub.algohive.dev   k8s-algohive-algohive-xxx.eu-west-3.elb.amazonaws.com
```

### 14.2 Test de routing par hostname

```bash
# Test frontend client
curl -H "Host: algohive.dev" \
  http://k8s-algohive-algohive-xxx.eu-west-3.elb.amazonaws.com

# Test BeeHub
curl -H "Host: beehub.algohive.dev" \
  http://k8s-algohive-algohive-xxx.eu-west-3.elb.amazonaws.com/
```

Les deux retournent du HTML → routing ALB fonctionnel ✅

### 14.3 Accès navigateur sans domaine réel

Ajouter une entrée dans `/etc/hosts` :
```bash
echo "$(dig +short k8s-algohive-algohive-xxx.eu-west-3.elb.amazonaws.com | head -1) algohive.dev beehub.algohive.dev" | sudo tee -a /etc/hosts
```

Puis ouvrir `http://algohive.dev` dans le navigateur.

### 14.4 Limitation connue — Client React

Le client React est buildé avec une URL d'API hardcodée (`https://algohive.dev`). Sans HTTPS et sans DNS réel pointant vers l'ALB, le frontend ne peut pas contacter le backend depuis le navigateur. L'application est fonctionnelle mais nécessiterait un rebuild de l'image client avec la bonne `API_URL` pour être pleinement opérationnelle en production.

Pour une mise en production complète, il faudrait :
1. Un domaine réel configuré en DNS vers l'URL ALB
2. Un certificat ACM pour HTTPS
3. Rebuild du client React avec l'URL de production

---

## 15. Problèmes rencontrés et solutions

### 🐛 P1 — PVCs bloqués en `Pending`

**Symptôme :** Les PersistentVolumeClaims restaient indéfiniment en `Pending`.

**Cause :** EKS 1.23+ ne fournit plus le driver EBS in-tree par défaut. Sans le addon `aws-ebs-csi-driver`, aucun volume EBS ne peut être provisionné.

**Solution :** Installer l'addon EBS CSI Driver avec son rôle IRSA (voir section 8).

**Fix as-code :** Ajout de `storageClassName: gp2` dans tous les PVCs :
```yaml
spec:
  storageClassName: gp2
  accessModes: ["ReadWriteOnce"]
  resources:
    requests:
      storage: 500Mi
```

---

### 🐛 P2 — Postgres crashe au démarrage (`lost+found`)

**Symptôme :** Le pod `algohive-db` crashait en boucle. Les logs montraient une erreur Postgres refusant de démarrer car le répertoire de données n'était pas vide.

**Cause :** EBS monte un volume avec un répertoire `lost+found` à la racine, que Postgres interprète comme une corruption.

**Solution :** Surcharger `PGDATA` pour utiliser un sous-répertoire :
```yaml
env:
  - name: PGDATA
    value: /var/lib/postgresql/data/pgdata
```

---

### 🐛 P3 — Health probe du backend en `404`

**Symptôme :** Le pod `algohive-server` démarrait mais était marqué `Unhealthy` par la readiness probe.

**Cause :** La probe ciblait `/health` qui n'existe pas sur l'API. Les probes K8s du fichier v2 initial utilisaient un endpoint incorrect.

**Solution :** Changer l'endpoint de probe vers `/api/v1/metrics` (confirmé fonctionnel dans les logs du pod) :
```yaml
readinessProbe:
  httpGet:
    path: /api/v1/metrics
    port: 8080
```

---

### 🐛 P4 — Kustomize `commonLabels` deprecated

**Symptôme :** `kubectl apply` échouait avec une erreur de validation Kustomize sur les overlays.

**Cause :** `commonLabels` est déprécié en Kustomize v5 et génère des patches incompatibles avec les sélecteurs de Deployment.

**Solution :** Supprimer `commonLabels` des `kustomization.yaml` des overlays.

---

### 🐛 P5 — BeeAPI patch Kustomize incompatible

**Symptôme :** Le template BeeAPI avec `nameSuffix` générait des manifests avec des labels incohérents, cassant les sélecteurs des Deployments.

**Cause :** `nameSuffix` + Strategic Merge Patch ne met pas à jour `spec.selector.matchLabels`, qui est immutable sur un Deployment.

**Solution :** Remplacement par des patches JSON6902 avec `target:` explicite qui mettent à jour toutes les références (name, labels, selector, claimName) :
```yaml
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
```

---

### 🐛 P6 — ALB Controller `AccessDenied` sur `DescribeListenerAttributes`

**Symptôme :** L'Ingress restait sans `ADDRESS`, les events montraient `AccessDenied: elasticloadbalancing:DescribeListenerAttributes`.

**Cause :** La policy IAM `AWSLoadBalancerControllerIAMPolicy` initialement créée était une version ancienne ne contenant pas la permission `DescribeListenerAttributes` ajoutée dans les versions récentes du controller.

**Solution :** Mettre à jour la policy IAM avec la version courante :
```bash
curl -O https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/v2.11.0/docs/install/iam_policy.json

aws iam create-policy-version \
  --policy-arn arn:aws:iam::302263045490:policy/AWSLoadBalancerControllerIAMPolicy \
  --policy-document file://iam_policy.json \
  --set-as-default

kubectl rollout restart deployment/aws-load-balancer-controller -n kube-system
```

---

### 🐛 P7 — `argocd-applicationset-controller` en CrashLoopBackOff

**Symptôme :** Le controller crashait avec `no matches for kind "ApplicationSet" in version "argoproj.io/v1alpha1"`.

**Cause :** Le CRD `ApplicationSet` n'était pas installé dans le cluster.

**Solution :**
```bash
kubectl apply -f \
  https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/crds/applicationset-crd.yaml

kubectl rollout restart deployment/argocd-applicationset-controller -n argocd
```

---

### 🐛 P8 — `base/namespace/kustomization.yaml` manquant

**Symptôme :** ArgoCD signalait une erreur de build Kustomize sur l'application `algohive-core`.

**Cause :** Le fichier `kustomization.yaml` dans `base/namespace/` avait été oublié lors de la génération initiale.

**Solution :** Créer le fichier manquant :
```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - namespace.yaml
```
