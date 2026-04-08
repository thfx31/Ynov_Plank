#!/bin/bash

# --- 🎨 PALETTE DE COULEURS ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

NAMESPACE="algohive"

# --- FONCTIONS ---

show_banner() {
    clear
    echo -e "${RED}=========================================${NC}"
    echo -e "${BOLD}🧨  ALGOHIVE - DESTRUCTION DE LA STACK${NC}"
    echo -e "${RED}=========================================${NC}"
    echo -e "${YELLOW}ATTENTION : Cette action est irréversible.${NC}"
    echo "Elle va supprimer :"
    echo -e "  - Le Namespace ${BOLD}${NAMESPACE}${NC}"
    echo "  - Tous les Pods, Services, Déploiements"
    echo "  - Tous les Volumes (Données DB & Redis seront PERDUES)"
    echo -e "${RED}=========================================${NC}"
}

# --- EXÉCUTION ---

show_banner

# Demande de confirmation interactive
echo -n "Êtes-vous sûr de vouloir tout détruire ? (y/N) : "
read CONFIRM

if [[ "$CONFIRM" =~ ^[Yy]$ ]]; then
    echo ""
    echo -e "${RED}💥  Lancement de la destruction...${NC}"
    echo "-----------------------------------------"

    # On vérifie si le namespace existe d'abord
    if kubectl get namespace "$NAMESPACE" >/dev/null 2>&1; then
        # Méthode radicale : supprimer le namespace supprime tout ce qu'il contient
        echo -e "🗑️   Suppression du namespace ${BOLD}$NAMESPACE${NC} (cela peut prendre quelques secondes)..."
        
        kubectl delete namespace "$NAMESPACE"
        
        echo "-----------------------------------------"
        echo -e "${GREEN}✅  Stack détruite avec succès.${NC}"
    else
        echo -e "${YELLOW}⚠️   Le namespace '$NAMESPACE' n'existe pas. Rien à détruire.${NC}"
    fi

else
    echo ""
    echo -e "${GREEN}🛡️   Opération annulée. Ouf !${NC}"
fi