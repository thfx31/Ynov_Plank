# Documentation technique : architecture microservices AlgoHive

## 1. Contexte
Le projet **AlgoHive** est une plateforme d'apprentissage du code basée sur une architecture distribuée (Microservices).
Ce document détaille le rôle de chaque composant et leurs interactions au sein du cluster Kubernetes.

---

## 2. Plateforme infra
Premier PoC en récupérant le code Algohive : https://github.com/AlgoHive-Coding-Puzzles/AlgoHive-Infra

Le docker compose a été transformé en manifestes K8S pour tester la faisabilité.
L'appli tourne actuellement sur un cluster `kind`.
Un refactoring et templating sera proposé dans une nouvelle itération

---

## 3. Cartographie des services

### Frontend
* **Service :** `algohive-client`
* **Rôle :** Interface utilisateur et administration des comptes
* **Comportement :** Affiche l'interface et envoie des requêtes API au serveur

### Backend 
* **Service :** `algohive-server`
* **Rôle :** Centralise les appels :
    * Authentification des étudiants (JWT)
    * Gestion des scores
    * Routage des demandes vers les catalogues d'exercices
* **Dépendances :** Connecté à la Base de Données (`db`) et au Cache (`redis`)

### Catalogues (BeeAPIs)
* **Services :** `beeapi-server-tlse`, `beeapi-server-mpl`, `beeapi-server-lyon`...
* **Rôle :** Hébergement décentralisé des exercices
* **Architecture :** Chaque instance représente un campus (Toulouse, Montpellier, etc.)
* **Persistence :** Utilise un **Persistent Volume (PVC)** pour stocker physiquement les fichiers des puzzles (.md, .json)
* **Interaction :** Le serveur principal les interroge via leur nom DNS interne (ex: `http://beeapi-server-tlse:5000`)

### Administration (BeeHub)
* **Service :** `beehub`
* **Rôle :** Back-office pour les professeurs. Permet de créer/modifier des puzzles et de gérer les catalogues BeeAPI
* **Spécificité :** Possède sa propre base de données légère (**SQLite**) persistée via un volume dédié, indépendante de la base principale

### Données & Persistance
* **Algohive DB (`postgres`)** : Stockage critique (Utilisateurs, Historique). Données persistantes via PVC
* **Algohive Cache (`redis`)** : Stockage volatile (Sessions, Cache API). Améliore les performances

---

## 4. Architecture

```mermaid
graph TD
    %% --- NOEUDS EXTERNES ---
    User((Utilisateur<br/>Navigateur Web))

    %% --- CLUSTER KUBERNETES ---
    subgraph K8S [Cluster Kubernetes - Namespace: algohive]
        direction TB

        %% Couche Exposition (Front & Admin)
        subgraph EXPOSITION [Frontend & Admin]
            Client[<b>Algohive Client</b><br/>React/Nginx<br/>Port: 80]
            BeeHub[<b>BeeHub Admin</b><br/>Backoffice<br/>Port: 8081]
        end

        %% Couche Logique (Backend)
        subgraph BACKEND [Backend Core]
            Server[<b>Algohive Server</b><br/>API Gateway<br/>Port: 8080]
        end

        %% Couche Microservices (Catalogues)
        subgraph CATALOGUES [Microservices Puzzles]
            BeeAPI_Tlse[<b>BeeAPI Tlse</b><br/>Port: 5000]
            BeeAPI_Mpl[<b>BeeAPI Mpl</b><br/>Port: 5000]
            BeeAPI_Lyon[<b>BeeAPI Lyon</b><br/>Port: 5000]
            BeeAPI_Stag[<b>BeeAPI Staging</b><br/>Port: 5000]
        end

        %% Couche Données (Persistence)
        subgraph DATA [Data Layer]
            PG[(<b>Postgres DB</b><br/>Port: 5432)]
            Redis[(<b>Redis Cache</b><br/>Port: 6379)]
            SQLite[(<b>SQLite</b><br/>Fichier Local)]
        end
    end

    %% --- FLUX DE DONNEES ---

    %% Accès Utilisateur (Simulé via Port-Forward pour l'instant)
    User -- "HTTP (Port-Forward :7002)" --> Client
    User -- "HTTP (Port-Forward :8002)" --> BeeHub
    User -- "Appels API / HTTP" --> Server

    %% Interactions Client -> Serveur
    Client -.-> Server

    %% Interactions Serveur -> Données
    Server -- "TCP :5432 (Auth/Scores)" --> PG
    Server -- "TCP :6379 (Sessions)" --> Redis

    %% Interactions Serveur -> Microservices
    Server -- "HTTP :5000 (Get Puzzles)" --> BeeAPI_Tlse
    Server -- "HTTP :5000" --> BeeAPI_Mpl
    Server -- "HTTP :5000" --> BeeAPI_Lyon
    Server -- "HTTP :5000" --> BeeAPI_Stag

    %% Interactions BeeHub (Admin)
    BeeHub -- "Volume Local" --> SQLite
    BeeHub -- "HTTP :5000 (Admin/Update)" --> BeeAPI_Tlse
    BeeHub -.-> BeeAPI_Mpl
    BeeHub -.-> BeeAPI_Lyon
    BeeHub -.-> BeeAPI_Stag

    %% Styles pour faire joli
    classDef plain fill:#fff,stroke:#333,stroke-width:1px;
    classDef db fill:#e1f5fe,stroke:#0277bd,stroke-width:2px;
    classDef micro fill:#fff9c4,stroke:#fbc02d,stroke-width:2px;
    classDef core fill:#e8f5e9,stroke:#2e7d32,stroke-width:2px;

    class PG,Redis,SQLite db;
    class BeeAPI_Tlse,BeeAPI_Mpl,BeeAPI_Lyon,BeeAPI_Stag micro;
    class Server core;
    class Client,BeeHub plain;
```
---
## 5. Data flow

### Scénario : Un étudiant lance un exercice
1.  **User** -> **Client** : Clic sur "Ouvrir Puzzle Toulouse"
2.  **Client** -> **Server** : Requête HTTP `GET /api/puzzles/tlse/1`
3.  **Server** -> **Redis** : Vérification du Token (Est-il connecté ?)
4.  **Server** -> **BeeAPI-Tlse** : Appel interne `GET /puzzles/1`.
5.  **BeeAPI-Tlse** : Lecture du fichier sur disque et réponse au serveur
6.  **Server** -> **Client** : Renvoi du JSON de l'exercice

---

## 6. Choix d'infrastructure (Kubernetes)
Le déploiement utilise les objets natifs K8s pour garantir robustesse et scalabilité :
* **Namespaces** : Isolation de l'environnement (`algohive`)
* **ConfigMaps/Secrets** : Externalisation de la configuration
* **Services (ClusterIP)** : Découverte de services via DNS interne
* **PVC (Persistent Volume Claims)** : Garantie de conservation des données (DB et Puzzles) indépendamment du cycle de vie des pods

---

## 7. Démarrage du PoC

Voir documentation [Setup_PoC_Kind](docs/SETUP_POC_kind.md)