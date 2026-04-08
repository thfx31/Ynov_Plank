# Makefile

# Déploiement de l'infrastructure Kubernetes 
deploy:
	@../k8s-rework/manage-bee.sh

# Suppression de l'infrastructure Kubernetes
destroy:
	@../k8s-rework/destroy-bee.sh

# Affiche l'état des pods
status:
	@kubectl get pods -n algohive