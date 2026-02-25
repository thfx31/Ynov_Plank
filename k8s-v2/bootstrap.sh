#!/usr/bin/env bash
# =============================================================================
# AlgoHive - Script de bootstrap
# Usage : ./bootstrap.sh
# Prérequis : kubectl configuré sur le cluster cible, kubeseal installé
# =============================================================================

set -euo pipefail

# --- Couleurs ---
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'

info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
success() { echo -e "${GREEN}[OK]${NC}   $1"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $1"; }
error()   { echo -e "${RED}[ERR]${NC}  $1"; exit 1; }
step()    { echo -e "\n${BOLD}══════════════════════════════════════${NC}"; echo -e "${BOLD} $1${NC}"; echo -e "${BOLD}══════════════════════════════════════${NC}"; }

# --- Vérification qu'on est bien à la racine du repo ---
if [[ ! -f "argocd/root-app.yaml" ]]; then
  error "Lancer ce script depuis la racine du repo (là où se trouve argocd/)"
fi

# =============================================================================
step "1/5 · Vérification des prérequis"
# =============================================================================

command -v kubectl  &>/dev/null || error "kubectl non trouvé. Installer kubectl et configurer le kubeconfig."
command -v kubeseal &>/dev/null || {
  warn "kubeseal non trouvé. Tentative d'installation..."
  if command -v brew &>/dev/null; then
    brew install kubeseal
  else
    KUBESEAL_VERSION="0.27.0"
    ARCH=$(uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/')
    OS=$(uname -s | tr '[:upper:]' '[:lower:]')
    URL="https://github.com/bitnami-labs/sealed-secrets/releases/download/v${KUBESEAL_VERSION}/kubeseal-${KUBESEAL_VERSION}-${OS}-${ARCH}.tar.gz"
    info "Téléchargement kubeseal depuis $URL"
    curl -sSL "$URL" | tar -xz kubeseal
    sudo mv kubeseal /usr/local/bin/
  fi
}

# Vérifier la connexion cluster
info "Vérification connexion cluster..."
kubectl cluster-info &>/dev/null || error "Impossible de joindre le cluster. Vérifier le kubeconfig."
CLUSTER=$(kubectl config current-context)
success "Connecté au cluster : $CLUSTER"

# Confirmer le bon cluster
echo ""
read -rp "$(echo -e "${YELLOW}Confirmer le déploiement sur ce cluster ? [y/N]${NC} ")" CONFIRM
[[ "$CONFIRM" =~ ^[yY]$ ]] || { info "Annulé."; exit 0; }

# =============================================================================
step "2/5 · Vérification ArgoCD"
# =============================================================================

kubectl get namespace argocd &>/dev/null || error "Namespace 'argocd' introuvable. ArgoCD est-il installé ?"
ARGOCD_PODS=$(kubectl get pods -n argocd --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l)
[[ "$ARGOCD_PODS" -gt 0 ]] || error "Aucun pod ArgoCD en Running. Vérifier l'installation ArgoCD."
success "ArgoCD opérationnel ($ARGOCD_PODS pods Running)"

# =============================================================================
step "3/5 · Bootstrap Sealed Secrets controller"
# =============================================================================

info "Application de la root-app ArgoCD (App of Apps)..."
kubectl apply -f argocd/root-app.yaml

info "Attente du déploiement du Sealed Secrets controller (wave -1)..."
echo -n "    "
for i in $(seq 1 24); do
  READY=$(kubectl get pods -n kube-system -l app.kubernetes.io/name=sealed-secrets \
    --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l)
  if [[ "$READY" -gt 0 ]]; then
    echo ""
    success "Sealed Secrets controller prêt"
    break
  fi
  echo -n "."
  sleep 5
  if [[ "$i" -eq 24 ]]; then
    echo ""
    error "Timeout : le controller Sealed Secrets n'est pas prêt après 2 min. Vérifier : kubectl get pods -n kube-system"
  fi
done

info "Récupération du certificat public du cluster..."
kubeseal --fetch-cert \
  --controller-name=sealed-secrets-controller \
  --controller-namespace=kube-system \
  > pub-cert.pem
success "Certificat récupéré → pub-cert.pem"

# =============================================================================
step "4/5 · Configuration des secrets"
# =============================================================================

echo ""
echo -e "${YELLOW}Saisir les valeurs des secrets AlgoHive.${NC}"
echo -e "${YELLOW}Appuyer sur Entrée pour garder la valeur par défaut (entre crochets).${NC}"
echo ""

# Fonction de saisie masquée avec valeur par défaut
read_secret() {
  local prompt="$1"
  local default="$2"
  local value
  if [[ -n "$default" ]]; then
    read -rsp "  $prompt [${default}] : " value
  else
    read -rsp "  $prompt : " value
  fi
  echo ""
  echo "${value:-$default}"
}

# Fonction génération chaîne aléatoire
random_string() {
  openssl rand -base64 32 | tr -d '/+=' | head -c 40
}

POSTGRES_PASSWORD=$(read_secret "Mot de passe PostgreSQL" "algohive")
JWT_SECRET=$(read_secret "JWT Secret (laisser vide = auto-généré)" "")
[[ -z "$JWT_SECRET" ]] && { JWT_SECRET=$(random_string); info "JWT Secret auto-généré"; }

SECRET_KEY=$(read_secret "Secret Key (laisser vide = auto-généré)" "")
[[ -z "$SECRET_KEY" ]] && { SECRET_KEY=$(random_string); info "Secret Key auto-générée"; }

DEFAULT_PASSWORD=$(read_secret "Mot de passe par défaut des comptes" "AlgoHive2024!")
ADMIN_PASSWORD=$(read_secret "Mot de passe admin BeeHub" "Admin2024!")
MAIL_PASSWORD=$(read_secret "Mot de passe SMTP mail (laisser vide si inutilisé)" "")

echo ""
info "Génération du secret K8S temporaire..."

# Créer le secret K8S temporaire
cat > /tmp/algohive-secret-plain.yaml << EOF
apiVersion: v1
kind: Secret
metadata:
  name: algohive-secret
  namespace: algohive
  labels:
    app.kubernetes.io/part-of: algohive
type: Opaque
stringData:
  POSTGRES_PASSWORD: "${POSTGRES_PASSWORD}"
  JWT_SECRET: "${JWT_SECRET}"
  DEFAULT_PASSWORD: "${DEFAULT_PASSWORD}"
  MAIL_PASSWORD: "${MAIL_PASSWORD}"
  CACHE_PASSWORD: ""
  SECRET_KEY: "${SECRET_KEY}"
  ADMIN_PASSWORD: "${ADMIN_PASSWORD}"
EOF

info "Chiffrement avec kubeseal..."
kubeseal --format yaml \
  --cert pub-cert.pem \
  < /tmp/algohive-secret-plain.yaml \
  > secrets/sealed-secret.yaml

# Effacer le fichier temporaire en clair immédiatement
rm -f /tmp/algohive-secret-plain.yaml
success "secrets/sealed-secret.yaml généré et chiffré"

info "Vérification du .gitignore..."
touch .gitignore
grep -q "secret-template.local.yaml" .gitignore || echo "secrets/secret-template.local.yaml" >> .gitignore
grep -q "pub-cert.pem" .gitignore              || echo "pub-cert.pem" >> .gitignore
success ".gitignore à jour"

echo ""
warn "Ne pas oublier de commiter secrets/sealed-secret.yaml avant de continuer :"
echo "    git add secrets/sealed-secret.yaml"
echo "    git commit -m 'chore: sealed secret'"
echo "    git push"
echo ""
read -rp "$(echo -e "${YELLOW}Le commit/push est fait ? [y/N]${NC} ")" PUSHED
[[ "$PUSHED" =~ ^[yY]$ ]] || { warn "Faire le push, puis relancer le script à l'étape 5 : kubectl apply -f argocd/root-app.yaml && kubectl get applications -n argocd -w"; exit 0; }

# =============================================================================
step "5/5 · Vérification du déploiement"
# =============================================================================

info "Attente de la synchronisation ArgoCD (peut prendre 2-3 min)..."
echo -n "    "
for i in $(seq 1 36); do
  SYNCED=$(kubectl get applications -n argocd --no-headers 2>/dev/null \
    | grep -c "Synced" || true)
  TOTAL=$(kubectl get applications -n argocd --no-headers 2>/dev/null \
    | wc -l || true)
  echo -ne "\r    Applications synchronisées : ${SYNCED}/${TOTAL}"
  [[ "$SYNCED" -eq "$TOTAL" && "$TOTAL" -gt 0 ]] && { echo ""; break; }
  sleep 5
  if [[ "$i" -eq 36 ]]; then
    echo ""
    warn "Timeout dépassé. Vérifier manuellement : kubectl get applications -n argocd"
  fi
done

echo ""
info "État des pods AlgoHive :"
kubectl get pods -n algohive 2>/dev/null || warn "Namespace algohive pas encore créé, attendre quelques secondes"

echo ""
info "État des PVC :"
kubectl get pvc -n algohive 2>/dev/null || true

echo ""
echo -e "${BOLD}══════════════════════════════════════${NC}"
echo -e "${GREEN}${BOLD} Bootstrap terminé !${NC}"
echo -e "${BOLD}══════════════════════════════════════${NC}"
echo ""
echo "  Accès ArgoCD UI :"
echo "    kubectl port-forward svc/argocd-server -n argocd 8080:443"
echo "    https://localhost:8080"
echo ""
echo "  Mot de passe admin ArgoCD :"
echo "    kubectl get secret argocd-initial-admin-secret -n argocd -o jsonpath='{.data.password}' | base64 -d"
echo ""
echo "  Logs backend :"
echo "    kubectl logs -n algohive deployment/algohive-server"
echo ""
