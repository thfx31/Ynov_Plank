# Stress Test & Autoscaling — AlgoHive

Ce document décrit la mise en place du scaling automatique sur le cluster AlgoHive et la procédure pour démontrer le comportement sous charge en simulant des connexions étudiantes.

---

## Sommaire

1. [Architecture du scaling](#1-architecture-du-scaling)
2. [Prérequis](#2-prérequis)
3. [Installation de metrics-server](#3-installation-de-metrics-server)
4. [Horizontal Pod Autoscaler (HPA)](#4-horizontal-pod-autoscaler-hpa)
5. [Cluster Autoscaler](#5-cluster-autoscaler)
6. [Installation de k6](#6-installation-de-k6)
7. [Script k6 — Simulation étudiants](#7-script-k6--simulation-étudiants)
8. [Déroulé de la démo](#8-déroulé-de-la-démo)
9. [Monitoring en live](#9-monitoring-en-live)
10. [Nettoyage](#10-nettoyage)

---

## 1. Architecture du scaling

### Deux niveaux de scaling

```
Charge croissante
      │
      ▼
┌─────────────────────────────────────┐
│  HPA (Horizontal Pod Autoscaler)    │
│  Scale les PODS dans un node        │
│  Réaction : ~30 secondes            │
│  Exemple : 1 pod → 5 pods           │
└────────────────┬────────────────────┘
                 │ Si les nodes sont saturés
                 ▼
┌─────────────────────────────────────┐
│  Cluster Autoscaler                 │
│  Scale les NODES (EC2)              │
│  Réaction : ~2-3 minutes            │
│  Exemple : 2 nodes → 4 nodes        │
└─────────────────────────────────────┘
```

### Chemin d'une requête étudiant

```
k6 (utilisateurs virtuels)
    │
    ▼
algohive-server (:8080)   ← cible du stress test
    │
    ├──► algohive-db (:5432)     lecture scores
    ├──► algohive-cache (:6379)  vérification session
    └──► beeapi-server (:5000)   récupération puzzle
```

`algohive-server` est le service central — tous les appels étudiants passent par lui. C'est lui qu'on cible pour le HPA.

---

## 2. Prérequis

- Cluster EKS opérationnel avec tous les pods AlgoHive en `Running`
- Node group configuré avec min=1, max=4 (ou plus)
- `kubectl` configuré
- `helm` installé

Vérifier la configuration du node group (important pour le Cluster Autoscaler) :
```bash
aws eks describe-nodegroup \
  --cluster-name algohive \
  --nodegroup-name algohive-nodes \
  --query "nodegroup.scalingConfig"
```

Résultat attendu :
```json
{
  "minSize": 1,
  "maxSize": 4,
  "desiredSize": 2
}
```

Si `maxSize` est insuffisant, le mettre à jour :
```bash
aws eks update-nodegroup-config \
  --cluster-name algohive \
  --nodegroup-name algohive-nodes \
  --scaling-config minSize=1,maxSize=4,desiredSize=2
```

---

## 3. Installation de metrics-server

`metrics-server` collecte les métriques CPU et mémoire des pods — indispensable pour que le HPA fonctionne.

```bash
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml

# Attendre que metrics-server soit prêt
kubectl wait --for=condition=available deployment/metrics-server \
  -n kube-system --timeout=120s

# Vérification
kubectl top nodes
kubectl top pods -n algohive
```

Résultat attendu de `kubectl top pods -n algohive` :
```
NAME                              CPU(cores)   MEMORY(bytes)
algohive-server-xxx               5m           64Mi
algohive-db-xxx                   8m           128Mi
...
```

> ⚠️ Si `kubectl top` retourne `error: Metrics API not available`, attendre 1-2 minutes que metrics-server collecte ses premières métriques.

---

## 4. Horizontal Pod Autoscaler (HPA)

Le HPA surveille le CPU du deployment `algohive-server` et crée des pods supplémentaires si la charge dépasse le seuil défini.

### 4.1 Vérifier les resource requests

Le HPA calcule l'utilisation CPU **en pourcentage des requests**. Il faut que `algohive-server` ait des `resources.requests` définis (déjà fait en v2).

Vérifier :
```bash
kubectl get deployment algohive-server -n algohive \
  -o jsonpath='{.spec.template.spec.containers[0].resources}'
```

Résultat attendu :
```json
{
  "limits": {"cpu": "500m", "memory": "512Mi"},
  "requests": {"cpu": "100m", "memory": "128Mi"}
}
```

### 4.2 Créer le HPA

```bash
cat > hpa-algohive-server.yaml << 'EOF'
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: algohive-server-hpa
  namespace: algohive
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: algohive-server
  minReplicas: 1
  maxReplicas: 5
  metrics:
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: 50
  behavior:
    scaleUp:
      stabilizationWindowSeconds: 30
      policies:
        - type: Pods
          value: 2
          periodSeconds: 30
    scaleDown:
      stabilizationWindowSeconds: 120
EOF

kubectl apply -f hpa-algohive-server.yaml
```

### 4.3 Vérifier le HPA

```bash
kubectl get hpa -n algohive
```

```
NAME                   REFERENCE                     TARGETS   MINPODS   MAXPODS   REPLICAS
algohive-server-hpa    Deployment/algohive-server    5%/50%    1         5         1
```

- `TARGETS` : utilisation actuelle / seuil
- `REPLICAS` : nombre de pods actifs

---

## 5. Cluster Autoscaler

Le Cluster Autoscaler surveille les pods en état `Pending` (pas de ressources disponibles) et provisionne de nouveaux nodes EC2.

### 5.1 Créer le rôle IAM

```bash
# Récupérer l'OIDC ID
OIDC_ID=$(aws eks describe-cluster \
  --name algohive \
  --query "cluster.identity.oidc.issuer" \
  --output text | cut -d'/' -f5)

cat > ca-trust-policy.json << EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "arn:aws:iam::<ACCOUNT_ID>:oidc-provider/oidc.eks.eu-west-3.amazonaws.com/id/${OIDC_ID}"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "oidc.eks.eu-west-3.amazonaws.com/id/${OIDC_ID}:sub": "system:serviceaccount:kube-system:cluster-autoscaler"
        }
      }
    }
  ]
}
EOF

aws iam create-role \
  --role-name AlgoHiveClusterAutoscalerRole \
  --assume-role-policy-document file://ca-trust-policy.json
```

### 5.2 Créer et attacher la policy IAM

```bash
cat > ca-policy.json << 'EOF'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "autoscaling:DescribeAutoScalingGroups",
        "autoscaling:DescribeAutoScalingInstances",
        "autoscaling:DescribeLaunchConfigurations",
        "autoscaling:DescribeScalingActivities",
        "autoscaling:DescribeTags",
        "autoscaling:SetDesiredCapacity",
        "autoscaling:TerminateInstanceInAutoScalingGroup",
        "ec2:DescribeImages",
        "ec2:DescribeInstanceTypes",
        "ec2:DescribeLaunchTemplateVersions",
        "ec2:GetInstanceTypesFromInstanceRequirements",
        "eks:DescribeNodegroup"
      ],
      "Resource": "*"
    }
  ]
}
EOF

aws iam create-policy \
  --policy-name AlgoHiveClusterAutoscalerPolicy \
  --policy-document file://ca-policy.json

aws iam attach-role-policy \
  --role-name AlgoHiveClusterAutoscalerRole \
  --policy-arn arn:aws:iam::<ACCOUNT_ID>:policy/AlgoHiveClusterAutoscalerPolicy
```

### 5.3 Installer le Cluster Autoscaler

```bash
helm repo add autoscaler https://kubernetes.github.io/autoscaler
helm repo update

helm install cluster-autoscaler autoscaler/cluster-autoscaler \
  -n kube-system \
  --set autoDiscovery.clusterName=algohive \
  --set awsRegion=eu-west-3 \
  --set rbac.serviceAccount.annotations."eks\.amazonaws\.com/role-arn"=arn:aws:iam::<ACCOUNT_ID>:role/AlgoHiveClusterAutoscalerRole \
  --set extraArgs.balance-similar-node-groups=true \
  --set extraArgs.skip-nodes-with-system-pods=false

# Vérification
kubectl get pods -n kube-system | grep cluster-autoscaler
```

### 5.4 Tagger le node group pour l'autodiscovery

```bash
# Récupérer le nom de l'Auto Scaling Group
ASG_NAME=$(aws autoscaling describe-auto-scaling-groups \
  --query "AutoScalingGroups[?contains(Tags[?Key=='eks:nodegroup-name'].Value, 'algohive-nodes')].AutoScalingGroupName" \
  --output text)

# Ajouter les tags requis par le Cluster Autoscaler
aws autoscaling create-or-update-tags \
  --tags \
    ResourceId=${ASG_NAME},ResourceType=auto-scaling-group,Key=k8s.io/cluster-autoscaler/enabled,Value=true,PropagateAtLaunch=true \
    ResourceId=${ASG_NAME},ResourceType=auto-scaling-group,Key=k8s.io/cluster-autoscaler/algohive,Value=owned,PropagateAtLaunch=true
```

---

## 6. Installation de k6

k6 est un outil de load testing moderne qui simule des utilisateurs virtuels avec des scénarios réalistes.

### Installation locale

**macOS :**
```bash
brew install k6
```

**Linux :**
```bash
sudo gpg -k
sudo gpg --no-default-keyring \
  --keyring /usr/share/keyrings/k6-archive-keyring.gpg \
  --keyserver hkp://keyserver.ubuntu.com:80 \
  --recv-keys C5AD17C747E3415A3642D57D77C6C491D6AC1D69

echo "deb [signed-by=/usr/share/keyrings/k6-archive-keyring.gpg] https://dl.k6.io/deb stable main" \
  | sudo tee /etc/apt/sources.list.d/k6.list

sudo apt-get update && sudo apt-get install k6
```

### Récupérer l'URL de l'API

Pour le stress test, on cible l'API backend directement via port-forward :
```bash
kubectl port-forward svc/algohive-server 8001:8080 -n algohive
# Laisser ce terminal ouvert pendant les tests
```

URL de base pour les tests : `http://localhost:8001`

---

## 7. Script k6 — Simulation étudiants

### 7.1 Script de base — Warmup

Ce script simule des étudiants qui appellent l'API de métriques (endpoint léger, bon pour valider que le test fonctionne) :

```bash
cat > stress-warmup.js << 'EOF'
import http from 'k6/http';
import { check, sleep } from 'k6';

export const options = {
  stages: [
    { duration: '30s', target: 10 },   // montée progressive à 10 utilisateurs
    { duration: '1m',  target: 10 },   // maintien 1 minute
    { duration: '30s', target: 0 },    // descente
  ],
};

export default function () {
  const res = http.get('http://localhost:8001/api/v1/metrics');
  check(res, { 'status 200': (r) => r.status === 200 });
  sleep(1);
}
EOF
```

Lancer :
```bash
k6 run stress-warmup.js
```

### 7.2 Script réaliste — Parcours étudiant

Ce script simule le parcours complet d'un étudiant : tentative de login puis appels API :

```bash
cat > stress-students.js << 'EOF'
import http from 'k6/http';
import { check, sleep } from 'k6';

const BASE_URL = 'http://localhost:8001';

export const options = {
  stages: [
    { duration: '1m',  target: 20  },  // 20 étudiants  → pas de scaling
    { duration: '2m',  target: 100 },  // 100 étudiants → HPA se déclenche
    { duration: '3m',  target: 300 },  // 300 étudiants → nodes saturent
    { duration: '2m',  target: 300 },  // maintien charge max
    { duration: '2m',  target: 0   },  // descente → scale down
  ],
  thresholds: {
    http_req_duration: ['p(95)<2000'],  // 95% des requêtes < 2 secondes
    http_req_failed: ['rate<0.1'],      // moins de 10% d'erreurs
  },
};

export default function () {
  // Étape 1 : l'étudiant se connecte
  const loginRes = http.post(`${BASE_URL}/api/v1/auth/login`, JSON.stringify({
    username: 'admin',
    password: 'admin',
  }), {
    headers: { 'Content-Type': 'application/json' },
  });

  check(loginRes, {
    'login status 200 ou 401': (r) => r.status === 200 || r.status === 401,
  });

  sleep(1);

  // Étape 2 : l'étudiant consulte les métriques / catalogue
  const metricsRes = http.get(`${BASE_URL}/api/v1/metrics`);
  check(metricsRes, { 'metrics status 200': (r) => r.status === 200 });

  sleep(2);
}
EOF
```

Lancer :
```bash
k6 run stress-students.js
```

### 7.3 Script de charge maximale — Spike test

Pour pousser jusqu'au scaling des nodes :

```bash
cat > stress-spike.js << 'EOF'
import http from 'k6/http';
import { check, sleep } from 'k6';

export const options = {
  stages: [
    { duration: '30s', target: 50  },
    { duration: '1m',  target: 200 },
    { duration: '1m',  target: 500 },
    { duration: '2m',  target: 500 },
    { duration: '1m',  target: 0   },
  ],
};

export default function () {
  const res = http.get('http://localhost:8001/api/v1/metrics');
  check(res, { 'status ok': (r) => r.status < 500 });
  sleep(0.5);
}
EOF
```

---

## 8. Déroulé de la démo

### Préparation (avant la démo)

```bash
# Terminal 1 — port-forward API
kubectl port-forward svc/algohive-server 8001:8080 -n algohive

# Terminal 2 — monitoring HPA en live
watch -n 2 kubectl get hpa -n algohive

# Terminal 3 — monitoring pods en live
watch -n 2 kubectl get pods -n algohive

# Terminal 4 — monitoring nodes en live
watch -n 5 kubectl get nodes
```

### Phase 1 — État initial (0 stress)

Montrer l'état de base :
```bash
kubectl get pods -n algohive        # 1 replica algohive-server
kubectl get hpa -n algohive         # TARGETS ~5%/50%
kubectl get nodes                   # 2 nodes Ready
```

### Phase 2 — Charge légère (20 utilisateurs)

```bash
k6 run stress-warmup.js
```

Observer : aucun scaling — la charge est absorbée par le pod existant.

### Phase 3 — Charge moyenne (100 utilisateurs) → HPA

```bash
k6 run stress-students.js
```

Observer dans le terminal de monitoring :
```
# HPA détecte CPU > 50%
algohive-server-hpa   Deployment/algohive-server   75%/50%   1   5   1

# ~30 secondes plus tard
algohive-server-hpa   Deployment/algohive-server   60%/50%   1   5   3

# Nouveaux pods qui apparaissent
algohive-server-xxx   0/1   Pending    0   2s
algohive-server-xxx   1/1   Running    0   15s
```

### Phase 4 — Charge maximale (500 utilisateurs) → Cluster Autoscaler

```bash
k6 run stress-spike.js
```

Observer :
```bash
# Des pods en Pending (plus de ressources sur les nodes existants)
kubectl get pods -n algohive | grep Pending

# Le Cluster Autoscaler détecte les pods Pending
kubectl logs -n kube-system -l app.kubernetes.io/name=cluster-autoscaler | tail -20

# ~2-3 minutes : nouveau node qui apparaît
kubectl get nodes
# ip-192-168-x-x   NotReady   <none>   10s   v1.31.x
# ip-192-168-x-x   Ready      <none>   90s   v1.31.x
```

### Phase 5 — Scale down

Arrêter k6 (`Ctrl+C`) et observer le scale down :
- HPA réduit les pods après 2 minutes (stabilizationWindow)
- Cluster Autoscaler supprime le node superflu après ~10 minutes

---

## 9. Monitoring en live

### Commandes utiles pendant la démo

```bash
# Vue d'ensemble complète
kubectl get hpa,pods,nodes -n algohive

# Détail HPA (historique des events)
kubectl describe hpa algohive-server-hpa -n algohive

# Consommation CPU/mémoire en temps réel
kubectl top pods -n algohive
kubectl top nodes

# Logs du Cluster Autoscaler
kubectl logs -n kube-system \
  -l app.kubernetes.io/name=cluster-autoscaler \
  --tail=50 -f

# Events K8s (scaling decisions)
kubectl get events -n algohive \
  --sort-by='.lastTimestamp' | tail -20
```

### Métriques k6 à surveiller

Pendant le test, k6 affiche en temps réel :

| Métrique | Description | Seuil acceptable |
|---|---|---|
| `http_req_duration` | Temps de réponse | p(95) < 2s |
| `http_req_failed` | Taux d'erreur | < 10% |
| `vus` | Utilisateurs virtuels actifs | — |
| `iterations` | Requêtes par seconde | — |

---

## 10. Nettoyage

### Supprimer le HPA

```bash
kubectl delete hpa algohive-server-hpa -n algohive
```

### Désinstaller le Cluster Autoscaler

```bash
helm uninstall cluster-autoscaler -n kube-system
```

### Supprimer les ressources IAM Cluster Autoscaler

```bash
aws iam detach-role-policy \
  --role-name AlgoHiveClusterAutoscalerRole \
  --policy-arn arn:aws:iam::<ACCOUNT_ID>:policy/AlgoHiveClusterAutoscalerPolicy

aws iam delete-role --role-name AlgoHiveClusterAutoscalerRole
aws iam delete-policy \
  --policy-arn arn:aws:iam::<ACCOUNT_ID>:policy/AlgoHiveClusterAutoscalerPolicy
```

### Remettre le node group à sa taille initiale

```bash
aws eks update-nodegroup-config \
  --cluster-name algohive \
  --nodegroup-name algohive-nodes \
  --scaling-config minSize=1,maxSize=3,desiredSize=2
```
