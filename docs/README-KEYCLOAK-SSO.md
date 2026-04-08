# Keycloak SSO

## Objectif

Mettre en place `Keycloak` comme fournisseur d'identité et permettre le `SSO` sur `Grafana`.

## Ce qui a été ajouté

- Déploiement `Keycloak` dans `k8s-v2`
- Intégration `Grafana -> Keycloak` validée en local
- Import utilisateurs Keycloak par script `CSV/XLSX`
- Version ArgoCD propre pour le monitoring avec `client_secret` dans un `SealedSecret`

## Fichiers principaux

- `k8s-v2/argocd/apps/keycloak.yaml`
- `k8s-v2/argocd/apps/monitoring.yaml`
- `k8s-v2/argocd/apps/monitoring-secrets.yaml`
- `k8s-v2/base/keycloak/`
- `k8s-v2/base/monitoring-secrets/`
- `k8s-v2/overlays/production/keycloak/`
- `k8s-v2/overlays/production/monitoring-secrets/`
- `k8s-v2/overlays/local-kind/`

## Convention locale

- Client AlgoHive : `http://localhost:7002`
- Backend AlgoHive : `http://localhost:8001`
- BeeHub : `http://localhost:8002`
- Keycloak : `http://localhost:8003`
- Health Keycloak : `http://localhost:9003/health/ready`
- Grafana : `http://localhost:3000`

## Ports Keycloak

Dans Kubernetes :

- HTTP Keycloak : `8082`
- Management Keycloak : `9002`

En local avec `port-forward` :

```bash
kubectl port-forward svc/keycloak -n algohive 8003:8082 9003:9002
```

## Comptes utiles en local

- Admin Keycloak :
  - login : `admin`
  - mot de passe : `ChangeThisAdminPassword!`

- Admin Grafana local :
  - login : `admin`
  - mot de passe : `ChangeThisGrafanaAdminPassword!`

## Grafana SSO

Le `client_secret` Grafana n'est pas stocké en clair dans `monitoring.yaml`.

Il est injecté par :

- `k8s-v2/argocd/apps/monitoring-secrets.yaml`
- `k8s-v2/base/monitoring-secrets/grafana-oauth-sealed-secret.yaml`

Dans `monitoring.yaml`, Grafana lit :

```yaml
grafana:
  envFromSecret: grafana-oauth-secret
```

et :

```yaml
client_secret: $__env{GF_AUTH_GENERIC_OAUTH_CLIENT_SECRET}
```

## Gestion des utilisateurs

### Pour Grafana SSO

Les utilisateurs peuvent être créés manuellement dans l'interface web Keycloak :

1. Ouvrir le realm `Grafana`
2. Aller dans `Users`
3. Créer l'utilisateur
4. Définir son mot de passe dans `Credentials`
5. Attribuer un rôle realm si besoin :
   - `platform-admin`
   - `manager`
   - `user`

Mapping Grafana :

- `platform-admin` -> `Admin`
- `manager` -> `Editor`
- autre -> `Viewer`

### Import CSV/XLSX

Disponible via :

- `k8s-v2/base/keycloak/import_users.py`
- `k8s-v2/base/keycloak/users-import-template.csv`
- `k8s-v2/base/keycloak/users-import-template.xlsx`

Le script peut :

- créer ou mettre à jour un utilisateur
- définir le mot de passe initial
- forcer `UPDATE_PASSWORD`

## Limites / points d'attention

- Un `SealedSecret` est lié à un cluster : si le cluster change, il faut le régénérer
- Le SSO Grafana est préparé pour ArgoCD/monitoring
- Le login AlgoHive (`/login`) n'utilise pas encore Keycloak

## Suite prévue

Créer une branche dédiée pour :

- analyser l'auth actuelle d'AlgoHive
- brancher Keycloak sur l'application
- permettre un login SSO AlgoHive
- gérer un import utilisateurs CSV pour ce flux
