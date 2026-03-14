# Déploiement AWS EKS — AlgoHive (Plank v2)

Ce document retrace **toutes les étapes** réalisées pour déployer l'architecture AlgoHive sur AWS EKS, avec ArgoCD en mode GitOps. Il inclut les commandes utilisées, les problèmes rencontrés et leurs solutions.

La prochaine étape sera le déploiement automatisé via Terraform.

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
15. [Destruction de l'infrastructure](#15-destruction-de-linfrastructure)
16. [Problèmes rencontrés et solutions](#16-problèmes-rencontrés-et-solutions)

---

## 1. Prérequis

Outils nécessaires sur le poste de travail :

| Outil | Usage |
|---|---|
| `aws` CLI | Interaction avec AWS |
| `kubectl` | Gestion du cluster K8s |
| `eksctl` | Gestion avancée EKS (OIDC, addons) |
| `helm` | Installation de charts (ArgoCD, ALB Controller) |
| `kubeseal` | Chiffrement des secrets (Sealed Secrets) |
| `git` | Gestion du repo GitOps |

Installation de `kubectl` :
```bash
curl -LO "https://dl.k8s.io/release/$(curl -Ls https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl
```

Installation de `eksctl` :
```bash
ARCH=amd64
PLATFORM=$(uname -s)_$ARCH
curl -sLO "https://github.com/eksctl-io/eksctl/releases/latest/download/eksctl_${PLATFORM}.tar.gz"
tar -xzf eksctl_${PLATFORM}.tar.gz -C /tmp
sudo install -m 755 /tmp/eksctl /usr/local/bin/eksctl

# Vérification
eksctl version
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

---

## 3. IAM — Rôles EKS

### Principe des rôles IAM

Dans AWS, un **rôle IAM** est une identité à laquelle on attache des permissions. Un rôle n'a pas de mot de passe — il est **assumé** temporairement par un service ou une entité.

La **trust policy** définit **qui a le droit d'assumer ce rôle**. La **permission policy** définit **ce que ce rôle peut faire**.

Nous créons deux rôles :
- **AlgoHiveEKSClusterRole** : assumé par le service EKS lui-même pour gérer les ressources réseau et de sécurité du control plane
- **AlgoHiveEKSNodeRole** : assumé par les instances EC2 (nodes) pour s'enregistrer auprès du cluster et puller les images de containers

### 3.1 Rôle pour le Control Plane EKS

Créer un fichier `eks-trust-policy.json` :
```bash
cat > eks-trust-policy.json << 'EOF'
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
EOF
```

Créer le rôle et lui attacher la policy EKS :
```bash
# Créer le rôle avec sa trust policy
aws iam create-role \
  --role-name AlgoHiveEKSClusterRole \
  --assume-role-policy-document file://eks-trust-policy.json

# Attacher la policy AWS managée qui donne les droits EKS au rôle
aws iam attach-role-policy \
  --role-name AlgoHiveEKSClusterRole \
  --policy-arn arn:aws:iam::aws:policy/AmazonEKSClusterPolicy
```

### 3.2 Rôle pour les Nodes (EC2)

Créer un fichier `node-trust-policy.json` :
```bash
cat > node-trust-policy.json << 'EOF'
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
EOF
```

Créer le rôle et lui attacher les 3 policies nécessaires aux nodes :
```bash
# Créer le rôle
aws iam create-role \
  --role-name AlgoHiveEKSNodeRole \
  --assume-role-policy-document file://node-trust-policy.json

# Worker node policy (enregistrement auprès du cluster)
aws iam attach-role-policy \
  --role-name AlgoHiveEKSNodeRole \
  --policy-arn arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy

# CNI policy (gestion réseau des pods)
aws iam attach-role-policy \
  --role-name AlgoHiveEKSNodeRole \
  --policy-arn arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy

# ECR policy (pull des images de containers)
aws iam attach-role-policy \
  --role-name AlgoHiveEKSNodeRole \
  --policy-arn arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly
```

---

## 4. VPC — CloudFormation

### Pourquoi CloudFormation ?

CloudFormation est le service d'Infrastructure as Code natif d'AWS. On l'utilise ici car le template officiel AWS crée exactement la bonne combinaison de subnets publics/privés avec les bons tags (`kubernetes.io/role/elb: 1`) que le ALB Controller recherche pour placer les load balancers. Faire ça à la main est risqué.

Les templates officiels sont disponibles sur : https://docs.aws.amazon.com/eks/latest/userguide/creating-a-vpc.html

```bash
aws cloudformation create-stack \
  --stack-name algohive-vpc \
  --template-url https://s3.us-west-2.amazonaws.com/amazon-eks/cloudformation/2020-10-29/amazon-eks-vpc-private-subnets.yaml \
  --capabilities CAPABILITY_IAM

# Attendre la fin du déploiement
aws cloudformation wait stack-create-complete --stack-name algohive-vpc
```

Récupérer les IDs des ressources créées (nécessaires pour les étapes suivantes) :
```bash
aws cloudformation describe-stacks \
  --stack-name algohive-vpc \
  --query "Stacks[0].Outputs"
```

Distinguer les subnets publics et privés :
```bash
# Subnets publics (pour l'ALB)
aws cloudformation describe-stacks \
  --stack-name algohive-vpc \
  --query "Stacks[0].Outputs[?OutputKey=='SubnetsPublic'].OutputValue" \
  --output text

# Subnets privés (pour les nodes)
aws cloudformation describe-stacks \
  --stack-name algohive-vpc \
  --query "Stacks[0].Outputs[?OutputKey=='SubnetsPrivate'].OutputValue" \
  --output text
```

> **Ressources créées :** VPC, 2 subnets publics, 2 subnets privés, Internet Gateway, NAT Gateway, Route Tables.

---

## 5. EKS — Cluster

### Via la console AWS

Console AWS → EKS → **Create cluster** :

- **Nom :** `algohive`
- **Version Kubernetes :** `1.35`
- **Région :** `eu-west-3`
- **Rôle IAM :** `AlgoHiveEKSClusterRole`
- **VPC :** stack `algohive-vpc`
- **Subnets :** publics + privés
- **Accès API :** Public

> La création du cluster prend environ 10-15 minutes.

### Via CLI (alternative)
Remplacer `<ACCOUNT_ID>` par l'ID AWS :

```bash
# Récupérer les IDs des subnets et security group
SUBNETS=$(aws cloudformation describe-stacks \
  --stack-name algohive-vpc \
  --query "Stacks[0].Outputs[?OutputKey=='SubnetIds'].OutputValue" \
  --output text | tr ',' ' ')

SG=$(aws cloudformation describe-stacks \
  --stack-name algohive-vpc \
  --query "Stacks[0].Outputs[?OutputKey=='SecurityGroups'].OutputValue" \
  --output text)

aws eks create-cluster \
  --name algohive \
  --kubernetes-version 1.35 \
  --role-arn arn:aws:iam::<ACCOUNT_ID>:role/AlgoHiveEKSClusterRole \
  --resources-vpc-config subnetIds=${SUBNETS},securityGroupIds=${SG},endpointPublicAccess=true,endpointPrivateAccess=false

# Attendre que le cluster soit actif (~10-15 min)
aws eks wait cluster-active --name algohive
```

---

## 6. EKS — Node Group

### Via la console AWS

Console AWS → EKS → Clusters → `algohive` → onglet **Compute** → **Add node group** :

- **Nom :** `algohive-nodes`
- **Rôle IAM :** `AlgoHiveEKSNodeRole`
- **Type d'instance :** `t3.medium`
- **Nombre de nodes :** 2 (min: 1, max: 3)
- **Disque :** 20 GB gp2
- **Subnets :** privés uniquement (les nodes ne sont pas exposés directement)

> La création du node group prend environ 5-10 minutes.

### Via CLI (alternative)
Remplacer `<ACCOUNT_ID>` par l'ID AWS :

```bash
# Récupérer les subnets privés
PRIVATE_SUBNETS=$(aws cloudformation describe-stacks \
  --stack-name algohive-vpc \
  --query "Stacks[0].Outputs[?OutputKey=='SubnetsPrivate'].OutputValue" \
  --output text)

aws eks create-nodegroup \
  --cluster-name algohive \
  --nodegroup-name algohive-nodes \
  --node-role arn:aws:iam::<ACCOUNT_ID>:role/AlgoHiveEKSNodeRole \
  --subnets $(echo $PRIVATE_SUBNETS | tr ',' ' ') \
  --instance-types t3.medium \
  --scaling-config minSize=1,maxSize=3,desiredSize=2 \
  --disk-size 20 \
  --ami-type AL2_x86_64

# Attendre que le node group soit actif (~5-10 min)
aws eks wait nodegroup-active \
  --cluster-name algohive \
  --nodegroup-name algohive-nodes
```

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
ip-192-168-x-x.eu-west-3.compute.internal  Ready    <none>   Xm    v1.35.x
ip-192-168-x-x.eu-west-3.compute.internal  Ready    <none>   Xm    v1.35.x
```

---

## 8. EBS CSI Driver

EKS 1.23+ nécessite l'installation explicite du driver EBS CSI pour que les `PersistentVolumeClaims` fonctionnent. Sans ce driver, les PVCs restent bloqués en `Pending`.

### 8.1 Activer l'OIDC Provider

L'OIDC Provider permet à Kubernetes de déléguer l'authentification IAM aux service accounts (mécanisme IRSA). La méthode recommandée utilise `eksctl` qui récupère automatiquement le thumbprint TLS :

```bash
eksctl utils associate-iam-oidc-provider \
  --cluster algohive \
  --region eu-west-3 \
  --approve
```

Sans `eksctl`, version CLI pure :
```bash
# Récupérer l'URL OIDC
OIDC_URL=$(aws eks describe-cluster \
  --name algohive \
  --query "cluster.identity.oidc.issuer" \
  --output text)

# Calculer le thumbprint automatiquement
OIDC_HOST=$(echo $OIDC_URL | sed 's|https://||' | cut -d'/' -f1)
THUMBPRINT=$(echo | openssl s_client -connect ${OIDC_HOST}:443 -servername ${OIDC_HOST} 2>/dev/null \
  | openssl x509 -fingerprint -noout -sha1 \
  | sed 's/://g' | cut -d'=' -f2 | tr '[:upper:]' '[:lower:]')

# Créer l'OIDC provider
aws iam create-open-id-connect-provider \
  --url $OIDC_URL \
  --client-id-list sts.amazonaws.com \
  --thumbprint-list $THUMBPRINT
```

> ⚠️ Si l'erreur `EntityAlreadyExists` apparaît, l'OIDC provider existe déjà (d'un cluster précédent). Tu peux continuer directement à l'étape 8.2 — mais vérifie que l'OIDC ID correspond bien au nouveau cluster (voir section 15.6 pour supprimer l'ancien si besoin).

Récupérer l'OIDC ID pour les étapes suivantes :
```bash
aws eks describe-cluster \
  --name algohive \
  --query "cluster.identity.oidc.issuer" \
  --output text
# → https://oidc.eks.eu-west-3.amazonaws.com/id/<OIDC_ID>
```

### 8.2 Créer le rôle IAM pour EBS CSI
Remplacer `<ACCOUNT_ID>` par l'ID AWS.
Remplacer `<OIDC_ID>` par l'ID récupéré à l'étape précédente.

```bash
cat > ebs-trust-policy.json << 'EOF'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "arn:aws:iam::<ACCOUNT_ID>:oidc-provider/oidc.eks.eu-west-3.amazonaws.com/id/<OIDC_ID>"
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
EOF
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
Remplacer `<ACCOUNT_ID>` par l'ID AWS :

Via la console AWS EKS :
- Cluster `algohive` → **Add-ons** → **aws-ebs-csi-driver**
- Sélectionner le rôle IAM : `AmazonEKS_EBS_CSI_DriverRole`

Ou via CLI :
```bash
aws eks create-addon \
  --cluster-name algohive \
  --addon-name aws-ebs-csi-driver \
  --service-account-role-arn arn:aws:iam::<ACCOUNT_ID>:role/AmazonEKS_EBS_CSI_DriverRole
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
Remplacer `<ACCOUNT_ID>` par l'ID AWS.
Remplacer `<OIDC_ID>` par l'ID récupéré en section 8.1.

```bash
cat > alb-trust-policy.json << 'EOF'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "arn:aws:iam::<ACCOUNT_ID>:oidc-provider/oidc.eks.eu-west-3.amazonaws.com/id/<OIDC_ID>"
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
EOF
```

```bash
aws iam create-role \
  --role-name AmazonEKSLoadBalancerControllerRole \
  --assume-role-policy-document file://alb-trust-policy.json

aws iam attach-role-policy \
  --role-name AmazonEKSLoadBalancerControllerRole \
  --policy-arn arn:aws:iam::<ACCOUNT_ID>:policy/AWSLoadBalancerControllerIAMPolicy
```

### 9.3 Installer via Helm
Remplacer `<ACCOUNT_ID>` par l'ID AWS :

```bash
helm repo add eks https://aws.github.io/eks-charts
helm repo update

helm install aws-load-balancer-controller eks/aws-load-balancer-controller \
  -n kube-system \
  --set clusterName=algohive \
  --set serviceAccount.create=true \
  --set serviceAccount.name=aws-load-balancer-controller \
  --set serviceAccount.annotations."eks\.amazonaws\.com/role-arn"=arn:aws:iam::<ACCOUNT_ID>:role/AmazonEKSLoadBalancerControllerRole

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

> ℹ️ Un warning `The CustomResourceDefinition "applicationsets.argoproj.io" is invalid: metadata.annotations: Too long` peut apparaître — c'est une limitation d'annotation Kubernetes sans impact fonctionnel, ArgoCD s'installe correctement.

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

> ⚠️ Un SealedSecret est lié à un cluster spécifique. Il faut le régénérer si le cluster est recréé (nouvelle clé de chiffrement).

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

### 13.2 Test du client React

```bash
kubectl port-forward svc/algohive-client 7002:80 -n algohive
```

Interface étudiant : `http://localhost:7002`

### 13.3 Test de l'API backend

```bash
kubectl port-forward svc/algohive-server 8001:8080 -n algohive
```

Swagger UI : `http://localhost:8001/swagger/index.html`

### 13.4 Test de BeeHub

```bash
kubectl port-forward svc/beehub 8002:8081 -n algohive
```

Interface admin : `http://localhost:8002`
Login : `admin` / `admin`

### 13.5 Récupérer les clés API BeeAPI

Les clés API sont générées au démarrage de chaque pod BeeAPI :

```bash
kubectl logs -n algohive -l app=beeapi-server-tlse | grep "API key initialized"
kubectl logs -n algohive -l app=beeapi-server-mpl | grep "API key initialized"
kubectl logs -n algohive -l app=beeapi-server-lyon | grep "API key initialized"
kubectl logs -n algohive -l app=beeapi-server-staging | grep "API key initialized"
```

> ⚠️ Si les commandes ne retournent rien, le pod tourne depuis trop longtemps et la ligne de log a été écrasée. Forcer un redémarrage :

```bash
kubectl rollout restart deployment/beeapi-server-tlse deployment/beeapi-server-mpl \
  deployment/beeapi-server-lyon deployment/beeapi-server-staging -n algohive

sleep 15 && \
echo "=== TLSE ===" && kubectl logs -n algohive -l app=beeapi-server-tlse | grep "API key" && \
echo "=== MPL ===" && kubectl logs -n algohive -l app=beeapi-server-mpl | grep "API key" && \
echo "=== LYON ===" && kubectl logs -n algohive -l app=beeapi-server-lyon | grep "API key" && \
echo "=== STAGING ===" && kubectl logs -n algohive -l app=beeapi-server-staging | grep "API key"
```

Ces clés sont à saisir dans BeeHub pour connecter les catalogues.

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

Les deux retournent du HTML → routing ALB fonctionnel

### 14.3 Accès navigateur

Pour tester depuis le navigateur sans domaine réel, le port-forward est la méthode recommandée :

```bash
kubectl port-forward svc/algohive-client 7002:80 -n algohive
# → http://localhost:7002
```

Pour tester via l'URL ALB, ajouter une entrée dans `/etc/hosts` :
```bash
echo "$(dig +short k8s-algohive-algohive-xxx.eu-west-3.elb.amazonaws.com | head -1) algohive.dev beehub.algohive.dev" | sudo tee -a /etc/hosts
# → http://algohive.dev
```

### 14.4 Limitation connue — HTTPS et domaine réel

Le routing ALB fonctionne par **hostname**. Sans domaine réel ni certificat HTTPS, le client React accessible via l'URL ALB ne peut pas contacter l'API backend depuis le navigateur (mixed content HTTP/HTTPS). Le port-forward reste la méthode de démonstration recommandée.

Pour une mise en production complète il faudrait :
1. Un domaine réel configuré en DNS vers l'URL ALB
2. Un certificat ACM gratuit AWS (décommenter les annotations HTTPS dans `ingress.yaml`)
3. Éventuellement rebuild du client React si l'URL d'API est hardcodée

---

## 15. Destruction de l'infrastructure

À exécuter dans l'ordre — certaines ressources dépendent d'autres.

### 15.1 Supprimer les namespaces K8s

```bash
kubectl delete namespace algohive
kubectl delete namespace argocd
```

### 15.2 Désinstaller le ALB Controller

```bash
helm uninstall aws-load-balancer-controller -n kube-system
```

### 15.3 Supprimer le Node Group EKS

Via la console : EKS → Clusters → `algohive` → onglet **Compute** → Node groups → `algohive-nodes` → **Delete**

Ou via CLI :
```bash
aws eks delete-nodegroup \
  --cluster-name algohive \
  --nodegroup-name algohive-nodes

aws eks wait nodegroup-deleted \
  --cluster-name algohive \
  --nodegroup-name algohive-nodes
```

> Attendre la suppression complète avant de continuer.

### 15.4 Supprimer le Cluster EKS

Via la console : EKS → Clusters → `algohive` → **Delete cluster**

Ou via CLI :
```bash
aws eks delete-cluster --name algohive
aws eks wait cluster-deleted --name algohive
```

### 15.5 Supprimer l'ALB résiduel et le VPC CloudFormation

Le ALB Controller peut laisser un Load Balancer AWS actif après la suppression des namespaces. Il faut le supprimer manuellement avant de pouvoir supprimer le VPC.
```bash
# Vérifier si un ALB résiduel existe
aws elbv2 describe-load-balancers \
  --query "LoadBalancers[?contains(LoadBalancerName, 'k8s-algohive')].LoadBalancerArn" \
  --output text

# Si un ARN apparaît, supprimer le load balancer
aws elbv2 delete-load-balancer \
  --load-balancer-arn ""

aws elbv2 wait load-balancers-deleted \
  --load-balancer-arns ""

# Supprimer le VPC
aws cloudformation delete-stack --stack-name algohive-vpc
aws cloudformation wait stack-delete-complete --stack-name algohive-vpc
```

> ⚠️ Si la suppression du VPC échoue avec "network interfaces in use", vérifier les ENIs résiduelles :
> ```bash
> aws ec2 describe-network-interfaces \
>   --filters "Name=vpc-id,Values=<VPC_ID>" \
>   --query "NetworkInterfaces[*].{ID:NetworkInterfaceId,Description:Description,Status:Status}"
> ```

### 15.6 Supprimer l'OIDC Provider
Remplacer `<ACCOUNT_ID>` par l'ID AWS.
Remplacer `<OIDC_ID>` par l'ID récupéré en section 8.1.

```bash
# Récupérer l'ARN
aws iam list-open-id-connect-providers

# Supprimer
aws iam delete-open-id-connect-provider \
  --open-id-connect-provider-arn arn:aws:iam::<ACCOUNT_ID>:oidc-provider/oidc.eks.eu-west-3.amazonaws.com/id/<OIDC_ID>
```

### 15.7 Supprimer les rôles IAM
Remplacer `<ACCOUNT_ID>` par l'ID AWS.
Remplacer `<OIDC_ID>` par l'ID récupéré en section 8.1.

```bash
# Rôle Control Plane
aws iam detach-role-policy \
  --role-name AlgoHiveEKSClusterRole \
  --policy-arn arn:aws:iam::aws:policy/AmazonEKSClusterPolicy
aws iam delete-role --role-name AlgoHiveEKSClusterRole

# Rôle Nodes
aws iam detach-role-policy \
  --role-name AlgoHiveEKSNodeRole \
  --policy-arn arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy
aws iam detach-role-policy \
  --role-name AlgoHiveEKSNodeRole \
  --policy-arn arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy
aws iam detach-role-policy \
  --role-name AlgoHiveEKSNodeRole \
  --policy-arn arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly
aws iam delete-role --role-name AlgoHiveEKSNodeRole

# Rôle ALB Controller
aws iam detach-role-policy \
  --role-name AmazonEKSLoadBalancerControllerRole \
  --policy-arn arn:aws:iam::<ACCOUNT_ID>:policy/AWSLoadBalancerControllerIAMPolicy
aws iam delete-role --role-name AmazonEKSLoadBalancerControllerRole

# Rôle EBS CSI Driver
aws iam detach-role-policy \
  --role-name AmazonEKS_EBS_CSI_DriverRole \
  --policy-arn arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy
aws iam delete-role --role-name AmazonEKS_EBS_CSI_DriverRole
```

### 15.8 Supprimer la policy ALB
Remplacer `<ACCOUNT_ID>` par l'ID AWS :

Si la policy a plusieurs versions (suite à une mise à jour) :
```bash
# Lister les versions
aws iam list-policy-versions \
  --policy-arn arn:aws:iam::<ACCOUNT_ID>:policy/AWSLoadBalancerControllerIAMPolicy

# Supprimer les versions non-default (ex: v1 si v2 est la default)
aws iam delete-policy-version \
  --policy-arn arn:aws:iam::<ACCOUNT_ID>:policy/AWSLoadBalancerControllerIAMPolicy \
  --version-id v1

# Supprimer la policy
aws iam delete-policy \
  --policy-arn arn:aws:iam::<ACCOUNT_ID>:policy/AWSLoadBalancerControllerIAMPolicy
```

### 15.9 Vérification finale

```bash
# Aucun cluster ne doit apparaître
aws eks list-clusters

# Aucune stack CREATE_COMPLETE ne doit apparaître
aws cloudformation list-stacks --stack-status-filter CREATE_COMPLETE

# Vérifier qu'il ne reste pas d'instances EC2 tournantes
aws ec2 describe-instances \
  --filters "Name=instance-state-name,Values=running" \
  --query "Reservations[*].Instances[*].[InstanceId,InstanceType,Tags[?Key=='eks:cluster-name'].Value|[0]]" \
  --output table
```

---

## 16. Problèmes rencontrés et solutions

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

**Cause :** La probe ciblait `/health` qui n'existe pas sur l'API.

**Solution :** Changer l'endpoint de probe vers `/api/v1/metrics` :
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

**Solution :** Remplacement par des patches JSON6902 avec `target:` explicite :
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

**Cause :** La policy IAM était une version ancienne ne contenant pas cette permission ajoutée dans les versions récentes du controller.

**Solution :** Télécharger la policy à jour depuis le repo officiel (section 9.1) — la version v2.11.0 contient déjà cette permission.

---

### 🐛 P7 — `base/namespace/kustomization.yaml` manquant

**Symptôme :** ArgoCD signalait une erreur de build Kustomize sur l'application `algohive-core`.

**Cause :** Le fichier `kustomization.yaml` dans `base/namespace/` avait été oublié lors de la génération initiale.

**Solution :** Créer le fichier manquant :
```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - namespace.yaml
```