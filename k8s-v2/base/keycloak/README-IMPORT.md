# Import utilisateurs Keycloak

## Fichiers fournis

- `users-import-template.csv`
- `users-import-template.xlsx`
- `import_users.py`

## Colonnes attendues

- `Nom`
- `Prenom`
- `Email`
- `Password`

Le mot de passe temporaire recommandé est `AlgoHive`.

Le script :

- crée le compte si besoin
- met à jour le compte s'il existe déjà
- active l'utilisateur
- définit le mot de passe temporaire
- force `UPDATE_PASSWORD` à la première connexion

## Accès local recommandés

Pour notre convention locale actuelle :

- Keycloak UI : `http://localhost:8003`
- Health Keycloak : `http://localhost:9003/health/ready`

Port-forward :

```bash
kubectl port-forward svc/keycloak -n algohive 8003:8082 9003:9002
```

## Vérifier le fichier sans importer

```bash
python3 k8s-v2/base/keycloak/import_users.py \
  k8s-v2/base/keycloak/users-import-template.csv \
  --dry-run
```

## Importer dans Keycloak

```bash
python3 k8s-v2/base/keycloak/import_users.py \
  k8s-v2/base/keycloak/users-import-template.csv \
  --base-url http://localhost:8003 \
  --realm master \
  --admin-user admin \
  --admin-password 'ChangeThisAdminPassword!'
```

## Import XLSX

Le support XLSX nécessite `openpyxl`.
Si ce module n'est pas installé, utiliser le CSV ou lancer le script dans un virtualenv.
