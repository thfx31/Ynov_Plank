# AlgoHive — Checklist de déploiement

Cocher chaque case au fur et à mesure. En cas de blocage, se référer à `DEPLOY.md`.

---

## Prérequis

- [ ] `kubectl get nodes` répond sans erreur
- [ ] `kubectl get pods -n argocd` montre des pods Running
- [ ] Repo Git cloné en local
- [ ] `kubeseal` installé (`kubeseal --version`)

---

## Bootstrap

- [ ] `./bootstrap.sh` lancé **OU** étapes manuelles suivies
- [ ] Controller Sealed Secrets Running : `kubectl get pods -n kube-system | grep sealed-secrets`
- [ ] Certificat récupéré : fichier `pub-cert.pem` présent
- [ ] `secrets/sealed-secret.yaml` généré (contient `kind: SealedSecret`)
- [ ] `git push` fait avec le `sealed-secret.yaml`

---

## Déploiement ArgoCD

- [ ] `kubectl apply -f argocd/root-app.yaml` exécuté
- [ ] Application `algohive-root` visible dans ArgoCD : `kubectl get applications -n argocd`
- [ ] Toutes les applications en `Synced` + `Healthy`

```bash
kubectl get applications -n argocd
# Résultat attendu :
# NAME                   SYNC STATUS   HEALTH STATUS
# algohive-root          Synced        Healthy
# sealed-secrets         Synced        Healthy
# algohive-project       Synced        Healthy
# algohive-production    Synced        Healthy
# algohive-staging       Synced        Healthy
```

---

## Vérification des ressources

- [ ] Namespace `algohive` créé : `kubectl get ns algohive`
- [ ] Tous les pods Running :

```bash
kubectl get pods -n algohive
```

| Pod | Attendu |
|-----|---------|
| `algohive-db` | 1/1 Running |
| `algohive-cache` | 1/1 Running |
| `algohive-server` (x2) | 1/1 Running |
| `algohive-client` | 1/1 Running |
| `beehub` | 1/1 Running |
| `beeapi-server-toulouse` | 1/1 Running |
| `beeapi-server-lyon` | 1/1 Running |
| `beeapi-server-montpellier` | 1/1 Running |
| `beeapi-server-staging` | 1/1 Running |

- [ ] Tous les PVC en `Bound` :

```bash
kubectl get pvc -n algohive
# Toutes les lignes doivent afficher STATUS = Bound
```

---

## Tests fonctionnels

- [ ] Backend répond :
```bash
kubectl port-forward svc/algohive-server -n algohive 8080:8080 &
curl -s http://localhost:8080/health
```

- [ ] Frontend accessible :
```bash
kubectl port-forward svc/algohive-client -n algohive 3000:80 &
# Ouvrir http://localhost:3000
```

- [ ] BeeAPI Toulouse répond :
```bash
kubectl port-forward svc/beeapi-server-toulouse -n algohive 5000:5000 &
curl -s http://localhost:5000/health
```

- [ ] ArgoCD UI accessible :
```bash
kubectl port-forward svc/argocd-server -n argocd 8443:443 &
# Ouvrir https://localhost:8443
```

---

## Sécurité

- [ ] `secrets/secret-template.local.yaml` absent du repo (gitignore)
- [ ] `pub-cert.pem` absent du repo (gitignore)
- [ ] Aucun mot de passe en clair dans Git : `git log --all -p | grep -i password` ne retourne rien de sensible

---

## 🎉 Déploiement validé

- [ ] Toutes les cases cochées
- [ ] URL de l'application communiquée à l'équipe
