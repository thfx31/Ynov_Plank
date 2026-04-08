#!/bin/bash

# --- PALETTE DE COULEURS ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# --- CONFIGURATION ---
NAMESPACE="algohive"
SEARCH_PATTERN="API key initialized"

# --- FONCTIONS ---

show_menu() {
    echo -e "${CYAN}=========================================${NC}"
    echo -e "${BOLD}🐝  ALGOHIVE - INFRA MANAGER (PLANK)${NC}"
    echo -e "${CYAN}=========================================${NC}"
    echo "1) Toulouse"
    echo "2) Montpellier"
    echo "3) Lyon"
    echo "4) Staging"
    echo "5) TOUT DÉPLOYER (Stack complète)"
    echo -e "${CYAN}=========================================${NC}"
    echo -n " Votre choix : "
    read CHOICE
}

deploy_step() {
    local FOLDER=$1
    local DESC=$2
    # On vérifie si le dossier ou fichier existe
    if [ -d "$FOLDER" ] || [ -f "$FOLDER" ]; then
        echo -e -n "🏗️   Déploiement de ${BOLD}${DESC}${NC}..."
        # L'option -R (récursif) permet de prendre tout le contenu
        OUTPUT=$(kubectl apply -R -f "$FOLDER" 2>&1)
        if [ $? -eq 0 ]; then
            echo -e " ${GREEN}OK${NC}"
        else
            echo -e " ${RED}ERREUR${NC}"
            echo "$OUTPUT"
        fi
    else
        echo -e "${YELLOW}⚠️   Chemin '$FOLDER' introuvable (étape ignorée)${NC}"
    fi
}

deploy_core_infra() {
    echo -e "${BLUE}🔧  Vérification du SOCLE (Infra + Core Apps)...${NC}"
    deploy_step "00-initialization" "Namespace"
    deploy_step "01-common" "Configs & Secrets"
    deploy_step "02-infrastructure" "Infrastructure (DB & Redis)"
    
    # Cible uniquement le dossier 'core' (Client, Backend, BeeHub)
    deploy_step "03-apps/core" "Applications Core"
    echo "-----------------------------------------"
}

get_api_key() {
    local CITY_LABEL=$1  # Ex: tlse, mpl
    local DISPLAY_NAME=$2 # Ex: Toulouse
    local LABEL="app=beeapi-server-${CITY_LABEL}"
    
    echo -e "${YELLOW}⏳  [${DISPLAY_NAME}] Recherche de la clé API...${NC}"

    local POD_NAME=""
    local RETRY_POD=0
    # On attend un peu que le pod apparaisse après le kubectl apply
    while [ -z "$POD_NAME" ] && [ $RETRY_POD -lt 10 ]; do
        POD_NAME=$(kubectl get pods -n ${NAMESPACE} -l ${LABEL} -o jsonpath="{.items[0].metadata.name}" 2>/dev/null)
        if [ -z "$POD_NAME" ]; then
            sleep 1
            ((RETRY_POD++))
        fi
    done

    if [ -z "$POD_NAME" ]; then
        echo -e "${RED}❌  [${DISPLAY_NAME}] Pod introuvable.${NC}"
        return
    fi

    local MAX_RETRIES=30
    local COUNT=0
    local KEY_FOUND=""
    while [ $COUNT -lt $MAX_RETRIES ]; do
        local LOG_LINE=$(kubectl logs ${POD_NAME} -n ${NAMESPACE} 2>/dev/null | grep "${SEARCH_PATTERN}")
        if [ -n "$LOG_LINE" ]; then
            KEY_FOUND=$(echo "$LOG_LINE" | awk '{print $NF}')
            break
        fi
        sleep 2
        ((COUNT++))
    done

    if [ -n "$KEY_FOUND" ]; then
        echo -e "${GREEN}🔑  [${DISPLAY_NAME}] Clé : ${BOLD}${KEY_FOUND}${NC}"
    else
        echo -e "${RED}⚠️   [${DISPLAY_NAME}] Timeout.${NC}"
    fi
}

# --- EXÉCUTION DU PROGRAMME PRINCIPAL ---

# 1. On affiche TOUJOURS le menu
show_menu

# 2. On traite le choix utilisateur
case $CHOICE in
    1)
        deploy_core_infra
        deploy_step "03-apps/beeapi/toulouse" "BeeAPI Toulouse"
        get_api_key "tlse" "Toulouse"
        ;;
    2)
        deploy_core_infra
        deploy_step "03-apps/beeapi/montpellier" "BeeAPI Montpellier"
        get_api_key "mpl" "Montpellier"
        ;;
    3)
        deploy_core_infra
        deploy_step "03-apps/beeapi/lyon" "BeeAPI Lyon"
        get_api_key "lyon" "Lyon"
        ;;
    4)
        deploy_core_infra
        deploy_step "03-apps/beeapi/staging" "BeeAPI Staging"
        get_api_key "staging" "Staging"
        ;;
    5)
        deploy_core_infra
        # Déploie tout le dossier beeapi (toutes les villes d'un coup)
        deploy_step "03-apps/beeapi" "TOUS les BeeAPI"
        
        echo -e "${BLUE}📋  Récupération de TOUTES les clés...${NC}"
        get_api_key "tlse" "Toulouse"
        get_api_key "mpl" "Montpellier"
        get_api_key "lyon" "Lyon"
        get_api_key "staging" "Staging"
        ;;
    *)
        echo -e "${RED}❌ Choix invalide.${NC}"
        ;;
esac

echo "-----------------------------------------"
echo -e "${GREEN}Déploiement Kubernetes terminé.${NC}"