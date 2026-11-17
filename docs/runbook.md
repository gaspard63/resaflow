# Runbook d'exploitation

Prérequis : `az login`, `az aks get-credentials -g <rg> -n <aks>`, `kubelogin convert-kubeconfig -l azurecli`.
`$ns` = `resaflow-prod` (ou `-staging`, `-dev`).

## Erreurs 5xx
*Alertes : `ResaflowErrorBudgetFastBurn`, `ResaflowErrorBudgetSlowBurn`, `ResaflowApiUnavailable`*
1. Grafana → *Service API* : quelles routes ? stable ou canary ? corrélé à un déploiement (annotation) ?
2. `kubectl get pods -n $ns` ; `kubectl logs -n $ns deploy/resaflow-api --since=15m | Select-String '"level": "ERROR"'`.
3. Base : `kubectl exec -n $ns deploy/resaflow-api -- python -c "import urllib.request;print(urllib.request.urlopen('http://127.0.0.1:8000/health/ready').read())"`.
4. Régression après déploiement → `helm rollback resaflow 0 -n $ns --wait`.
5. Ouvrir un post-mortem si plus de 25 % du budget mensuel a été consommé.

## Latence
*Alerte : `ResaflowLatencySLOBreach`*
1. Panneau « Latence p95 par route » ; trace lente dans Grafana → Explore → Tempo (recherche par durée > 300 ms) pour voir la requête SQL fautive.
2. HPA au maximum ? (`ResaflowHpaAtMax`) → augmenter `api.autoscaling.maxReplicas` ou la taille du pool.
3. PostgreSQL Burstable à court de crédits CPU ? (métrique *CPU credits remaining* du portail) → passer en `GP_Standard_D2ds_v5` (variable `postgres_sku`).

## File de messages saturée
*Alerte : `ResaflowQueueBacklog`*
1. `kubectl get pods -n $ns -l app.kubernetes.io/component=worker -o wide` (pods en attente après une éviction Spot ?).
2. Échecs ? Dashboard *Worker* ; `kubectl logs -n $ns deploy/resaflow-worker --since=30m`.
3. Mise à l'échelle manuelle temporaire : `kubectl scale deploy/resaflow-worker -n $ns --replicas=4` (l'HPA reprend la main ensuite).

## Sauvegardes
*Alertes : `ResaflowBackupFailed`, `ResaflowBackupMissing`*
- Logs : `kubectl logs -n $ns job/<job> -c dump` puis `-c upload`.
- Relance : `kubectl create job backup-manual -n $ns --from=cronjob/resaflow-db-backup`.
- **Restauration** (test mensuel recommandé) : `./scripts/demo/demo-backup-restore.ps1 -Environment <env> -StorageAccount <compte> -TestRestore`.
- Prod : restauration à un instant donné du serveur managé (portail → *Restore*, ou `az postgres flexible-server restore`) vers un nouveau serveur, puis mise à jour du secret `prod-database-url` dans Key Vault (les pods le relisent sous 2 min, redémarrer l'API pour rouvrir les connexions).

## Rotation d'un secret
1. Terraform : `terraform apply -replace="random_password.jwt[\"prod\"]"` (ou mise à jour du secret dans Key Vault).
2. Le CSI Driver synchronise le Secret Kubernetes sous 2 min ; les variables d'environnement étant lues au démarrage : `kubectl rollout restart deploy -n $ns`.
3. Rotation du JWT = déconnexion de tous les utilisateurs (jetons existants invalides) : prévenir.

## Tentative de force brute
*Alerte : `ResaflowAuthBruteForce`*
1. Dashboard *Sécurité* → IP sources (requête LogQL « échecs par IP »).
2. La limitation à 5 req/s/IP est déjà active ; blocage ciblé : Middleware Traefik `ipAllowList`/`ipDenyList` ou règle NSG.
3. Consigner l'incident (A.5.24 / A.5.25).

## Éviction Spot
Normal et attendu : les tâches en cours sont remises en file (acks tardifs), les workers se replanifient sur un autre nœud Spot ou sur le pool système. Vérifier `ResaflowQueueBacklog` et les échecs de tâches.

## Canary rejeté
Le pipeline a déjà supprimé le canary. Consulter la sortie de l'étape « Analyse canary » (taux d'erreurs et p95 mesurés), comparer stable/canary dans le panneau dédié, corriger puis relancer le pipeline.

## Cluster arrêté (FinOps)
Le cluster et PostgreSQL sont arrêtés le soir et le week-end. Démarrage manuel : *Actions → finops-schedule → Run workflow → start* (≈ 5 min).
