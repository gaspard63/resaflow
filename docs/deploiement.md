# Déploiement : CI/CD, stratégie, mise en place

## 1. Pipeline applicatif (`.github/workflows/pipeline.yml`)

| Étape | Déclencheur | Contenu | Bloquant si |
|---|---|---|---|
| Back-end | PR + main | `ruff`, `bandit`, `pytest` contre un vrai PostgreSQL 17 (service CI) avec migrations Alembic, couverture ≥ 75 % | erreur de lint, constat bandit ≥ moyen, test KO |
| Front-end | PR + main | `eslint`, `vitest`, `npm audit` (hautes/critiques), `vite build` | idem |
| Sécurité | PR + main | `gitleaks` (historique complet), `hadolint` ×2, Trivy *config* (SARIF → onglet Security) | secret détecté, erreur Dockerfile |
| Helm | PR + main | `helm lint` + `helm template` → kubeconform (schémas Kubernetes 1.33 + CRD) pour dev, staging, prod, prod canary | manifeste invalide |
| Images | main | build des 3 images, **scan Trivy avant tout push** (CVE critiques corrigeables), SBOM CycloneDX, push ACR taggé par **SHA du commit** | CVE critique |
| dev | main | `helm upgrade --install` (rolling update) + tests de fumée | |
| staging | après dev | rolling update + tests de fumée + **k6** (seuils = SLO) | p95 > 300 ms ou erreurs > 1 % |
| production | après staging + **approbation** | **canary** (cf. §2) | analyse canary KO → retour arrière automatique |

Les images ne sont jamais reconstruites entre environnements : le **même artefact** (même digest) traverse dev → staging → prod.

## 2. Stratégies de déploiement

### Rolling update (dev, staging, et promotion en prod)
- `maxSurge: 1`, `maxUnavailable: 0` : un nouveau pod doit être *Ready* (readinessProbe sur `/health/ready`, qui teste la base) avant qu'un ancien soit retiré.
- `preStop: sleep 5 s` : laisse Traefik retirer le pod de ses backends avant l'arrêt ; `terminationGracePeriodSeconds` 30 s (API) / 60 s (worker).
- PDB : au moins 1 pod API disponible pendant les opérations de maintenance des nœuds.
- Retour arrière : `helm rollback resaflow <révision>` (historique de 10 révisions).

### Canary (production)
1. La version stable reste en place ; un second Deployment `resaflow-api-canary` démarre avec la nouvelle image.
2. Un `TraefikService` pondéré envoie **10 %** du trafic `/api` au canary ; l'en-tête `X-Canary: always` permet de le cibler explicitement.
3. Tests de fumée sur le canary, puis **analyse automatique pendant 5 minutes** : `scripts/ci/canary-analysis.sh` interroge Prometheus (via le proxy de l'API Kubernetes) et compare le taux de 5xx (≤ 1 %) et la latence p95 (≤ 500 ms) **du seul canary** (label `resaflow_io_track="canary"`).
4. Sain → promotion : rolling update de la version stable vers la nouvelle image, suppression du canary. KO → suppression du canary, la version stable n'a jamais été touchée.

Pourquoi canary plutôt que blue/green : le blue/green double toute la capacité pendant le déploiement (coût) et bascule 100 % du trafic d'un coup ; le canary limite l'exposition à 10 % et s'appuie sur des métriques réelles. Limite : le front et le worker sont mis à jour en rolling update à la promotion (ils ne portent pas de logique risquée côté front, et le worker consomme la même file).

### Migrations de schéma (expand / contract)
Le job de migration (hook Helm) s'exécute **avant** le canary avec la nouvelle image : la nouvelle version du schéma doit rester compatible avec l'ancienne version du code. Règle : ajouter (colonne nullable, table) dans une version, utiliser dans la suivante, supprimer l'ancien dans une troisième.

## 3. Pipeline Terraform (`.github/workflows/terraform.yml`)

- PR : `fmt -check`, `validate`, scan Trivy IaC, puis `plan` de la stack `azure` publié en commentaire.
- main : `apply` des stacks `azure` puis `platform` après approbation (environnement `infra`), verrou d'état et file d'exécution unique (`concurrency`).

## 4. Mise en place depuis zéro

1. `./scripts/demo/setup-azure.ps1 -Suffix <xxx> -GithubRepo <compte>/resaflow -Email <mail>` — environ 20 minutes.
2. GitHub : environnements `production` et `infra` avec *Required reviewers* ; protection de `main` (cf. `securite-iso27001.md` §3).
3. Pousser sur `main` → le pipeline déploie dev puis staging, et attend l'approbation pour la prod.
4. Premier déploiement en prod : pas de version stable existante, le pipeline installe directement (le canary s'applique à partir du second déploiement).

Variables GitHub utilisées (aucune n'est secrète) : `AZURE_TENANT_ID`, `AZURE_SUBSCRIPTION_ID`, `AZURE_CLIENT_ID_DEPLOY`, `AZURE_CLIENT_ID_TERRAFORM`, `AZURE_RESOURCE_GROUP`, `AKS_NAME`, `ACR_NAME`, `ACR_LOGIN_SERVER`, `KEY_VAULT_NAME`, `POSTGRES_SERVER_NAME`, `STORAGE_ACCOUNT_URL`, `APP_IDENTITY_CLIENT_ID_{DEV,STAGING,PROD}`, `INGRESS_IP`, `TF_BACKEND_HCL`, `TF_VARS_AZURE`, `TF_VARS_PLATFORM`, optionnellement `OPERATORS_GROUP_ID`.

## 5. Déploiement manuel (sans CI)

```powershell
az aks get-credentials -g <rg> -n <aks> ; kubelogin convert-kubeconfig -l azurecli
$env:ACR_LOGIN_SERVER="..." ; $env:KEY_VAULT_NAME="..." ; $env:AZURE_TENANT_ID="..."
$env:STORAGE_ACCOUNT_URL="..." ; $env:INGRESS_IP="..." ; $env:APP_IDENTITY_CLIENT_ID_DEV="..."
bash ./scripts/ci/helm-deploy.sh dev <tag>   # via Git Bash ou WSL
```

### Cluster local (Docker Desktop Kubernetes, kind) sans compte Azure

Utile pour répéter les démonstrations Kubernetes (scaling, suppression de pods, rolling update) gratuitement :

```powershell
Copy-Item deploy/helm/resaflow/secrets.local.example.yaml deploy/helm/resaflow/secrets.local.yaml   # puis remplacer les change-me
docker compose build                                            # images resaflow-*:local
# kind uniquement : kind load docker-image resaflow-api:local resaflow-worker:local resaflow-frontend:local
helm upgrade --install resaflow deploy/helm/resaflow -n resaflow-dev --create-namespace `
  -f deploy/helm/resaflow/values-dev.yaml -f deploy/helm/resaflow/secrets.local.yaml
kubectl -n resaflow-dev port-forward svc/resaflow-frontend 8080:80
```

Ce mode remplace Key Vault par un Secret Kubernetes, Blob Storage par l'émulateur Azurite et `managed-csi` par la StorageClass par défaut ; il désactive Ingress/TLS, NetworkPolicies et ServiceMonitor (absents d'un cluster vierge). L'HPA nécessite metrics-server, absent par défaut de Docker Desktop comme de kind : `kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml` (ajouter l'argument `--kubelet-insecure-tls` au Deployment sur un cluster local).
