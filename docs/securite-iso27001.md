# Sécurité — contrôles ISO/IEC 27001:2022 (Annexe A)

Chaque mesure est rattachée à un ou plusieurs contrôles de l'Annexe A et à une **preuve** vérifiable dans le dépôt ou sur la plateforme.

## 1. Tableau de correspondance

| Mesure mise en place | Contrôle(s) | Implémentation | Preuve |
|---|---|---|---|
| **Chiffrement au repos** | A.8.24 | Blob : chiffrement service + infrastructure (double), PostgreSQL Flexible : chiffrement plateforme, disques AKS et PV (managed-csi) : SSE, Key Vault : HSM-backed par Azure | `infra/terraform/azure/storage.tf` (`infrastructure_encryption_enabled`), `postgres.tf` |
| **Chiffrement en transit** | A.8.24 | TLS Let's Encrypt (ECDSA P-256, rotation) sur Traefik, redirection HTTP→HTTPS, HSTS 1 an ; PostgreSQL `require_secure_transport=on` + TLS ≥ 1.2 + `sslmode=require` ; Blob/Key Vault : HTTPS uniquement, TLS ≥ 1.2 | `templates/ingress.yaml`, `platform/ingress.tf`, `postgres.tf` |
| **Accès au moindre privilège — Kubernetes** | A.5.15, A.8.2, A.8.3 | Comptes locaux désactivés, Entra ID + Azure RBAC ; la CI n'a des droits Kubernetes **que** sur les namespaces `resaflow-*` ; Role « opérateur » sans Secrets ni exec ; Role CI limité à `services/proxy` de Prometheus ; ServiceAccounts sans jeton monté | `azure/aks.tf`, `azure/identity.tf`, `templates/rbac.yaml`, `platform/rbac.tf` |
| **Accès au moindre privilège — Azure** | A.5.15, A.8.2 | Une identité managée **par environnement** : elle ne lit que **ses** secrets (rôle sur chaque secret) et **ses** conteneurs Blob (rôle par conteneur) ; CI déploiement : AcrPush + Cluster User + namespaces ; CI Terraform : limité au groupe de ressources ; rôles personnalisés minimaux pour l'arrêt/démarrage | `azure/identity.tf` |
| **Restriction de l'accès à l'information** | A.8.3 | Contrôle d'accès objet dans l'API (un utilisateur ne voit que ses réservations/exports, 404 sinon), routes admin protégées par rôle, PostgreSQL sans IP publique, NetworkPolicies deny-all | `routers/reservations.py` (`_owned`), `templates/networkpolicies.yaml` |
| **Authentification sécurisée** | A.8.5 | Argon2id, mot de passe ≥ 10 caractères, JWT court (30 min) avec `exp`/`iss` obligatoires, messages d'échec génériques + temps constant (anti-énumération), limitation de débit 5 req/s/IP sur `/api/v1/auth`, alerte force brute | `security.py`, `routers/auth.py`, Middleware `auth-ratelimit`, alerte `ResaflowAuthBruteForce` |
| **Informations d'authentification** | A.5.17 | Secrets générés aléatoirement par Terraform, stockés dans Key Vault, montés par le CSI Driver (rotation 2 min) ; aucune clé de compte Azure (clés partagées désactivées) ; **aucun secret dans GitHub** (OIDC) | `azure/keyvault.tf`, `templates/identity-and-secrets.yaml` |
| **Prévention de la fuite de données** | A.8.12 | `gitleaks` sur tout l'historique à chaque PR, `.gitignore` des `.env`/`tfvars`, logs sans mot de passe ni jeton ni e-mail en clair (domaine seulement), `Cache-Control: no-store`, CSP stricte, docs OpenAPI désactivées en prod | `pipeline.yml` (job security), `logging_conf.py`, `routers/auth.py`, `nginx/default.conf.template` |
| **Journalisation** | A.8.15 | Logger `security` structuré (`auth.login.failure`, `access.denied`, `admin.user.role_change`, `backup.uploaded`…) → Loki ; audit du plan de contrôle AKS (`kube-audit-admin`, `guard`), audit Key Vault, connexions PostgreSQL, écritures/suppressions Blob → Log Analytics ; journal d'accès Traefik | `logging_conf.py`, `azure/monitoring.tf`, dashboard « Sécurité » |
| **Surveillance** | A.8.16 | Prometheus + 14 alertes (dont force brute, pic de refus RBAC, sauvegarde manquante), dashboards Grafana, SLO | `templates/monitoring.yaml`, `docs/observabilite.md` |
| **Sauvegardes** | A.8.13 | CronJob quotidien `pg_dump` → conteneur `backups-<env>` (Cool à J+7, suppression J+30, versionnage) ; PITR 7 jours du serveur managé ; alertes d'échec/absence ; test de restauration scripté | `templates/backup-cronjob.yaml`, `azure/storage.tf`, `scripts/demo/demo-backup-restore.ps1` |
| **Gestion de la configuration** | A.8.9 | Toute l'infrastructure en Terraform (état distant versionné), toute la configuration Kubernetes en Helm, versions de charts et d'actions épinglées, revue par pull request | `infra/terraform/`, `deploy/helm/` |
| **Séparation des environnements** | A.8.31 | Namespaces dev/staging/prod, PSS `restricted`, quotas, identités/secrets/conteneurs distincts, environnements GitHub avec approbation pour la prod | `platform/namespaces.tf`, `azure/identity.tf` |
| **Accès au code source** | A.8.4 | Branche `main` protégée (PR + CI verte + revue), environnements GitHub protégés, fédération OIDC liée à la branche/l'environnement (un fork ne peut pas obtenir de jeton Azure) | Paramètres GitHub (cf. §3), `identity.tf` (sujets OIDC) |
| **Cycle de développement sécurisé** | A.8.25 | Sécurité à chaque étape du pipeline : SAST, scans, tests, déploiement progressif (canary) avec retour arrière automatique, actions tierces épinglées par SHA | `.github/workflows/pipeline.yml` |
| **Codage sécurisé** | A.8.28 | Validation stricte des entrées (Pydantic), ORM paramétré (pas d'injection SQL), validation du contenu réel des fichiers, en-têtes de sécurité, `bandit` + `ruff` (règles `S`) | `schemas.py`, `uploads.py`, `main.py` |
| **Protection contre les logiciels malveillants** | A.8.7 | Trivy sur chaque image (bloquant sur CVE critique corrigeable), SBOM CycloneDX archivé, images de base officielles, Dependabot, Image Cleaner AKS | `pipeline.yml` (job images), `.github/dependabot.yml`, `aks.tf` |
| **Gestion des vulnérabilités techniques** *(complément)* | A.8.8 | Mises à jour automatiques AKS (`patch` + `NodeImage`), Dependabot hebdomadaire (pip, npm, Docker, Actions, Terraform) | `aks.tf`, `dependabot.yml` |
| **Sécurité des réseaux** *(complément)* | A.8.20, A.8.22 | NSG (80/443 seulement), base dans un sous-réseau délégué privé, NetworkPolicies Cilium, aucun Service LoadBalancer hors Traefik (quota) | `main.tf`, `networkpolicies.yaml`, `namespaces.tf` |

## 2. Déclaration d'applicabilité (extrait — périmètre technique du projet)

| Contrôle | Applicable | Justification de l'inclusion / exclusion |
|---|---|---|
| A.5.15 Contrôle d'accès | Oui | Plusieurs populations (utilisateurs, admins, CI, opérateurs) |
| A.5.17 Informations d'authentification | Oui | Secrets applicatifs et d'infrastructure |
| A.5.23 Sécurité des services cloud | Oui | Hébergement Azure : responsabilités partagées documentées (plan de contrôle AKS, PaaS) |
| A.7.x Contrôles physiques | **Non** (hérités) | Couverts par Microsoft Azure (certifié ISO 27001), hors périmètre du projet |
| A.6.x Contrôles liés aux personnes | **Non** | Hors périmètre technique (équipe pédagogique) |
| A.8.2 / A.8.3 / A.8.4 / A.8.5 | Oui | Voir tableau §1 |
| A.8.7 / A.8.8 | Oui | Chaîne d'approvisionnement logicielle (images, dépendances) |
| A.8.9 Gestion de la configuration | Oui | IaC + Helm |
| A.8.12 Prévention de la fuite de données | Oui | Données personnelles (e-mails), secrets |
| A.8.13 Sauvegarde | Oui | Données métier persistantes |
| A.8.15 / A.8.16 | Oui | Exploitation et détection |
| A.8.20 / A.8.22 Réseaux | Oui | Services exposés sur Internet |
| A.8.24 Cryptographie | Oui | Données au repos et en transit |
| A.8.25 / A.8.28 | Oui | Développement interne |
| A.8.31 Séparation des environnements | Oui | 3 environnements sur un cluster partagé |
| A.8.14 Redondance | **Partiel** | Redondance applicative (réplicas, PDB) ; pas de redondance zonale/géo (arbitrage FinOps assumé) |

## 3. Paramètres GitHub à activer (A.8.4)

- *Settings → Branches* : règle sur `main` — pull request obligatoire, 1 approbation, statuts `pipeline` et `terraform` requis, pas de push forcé.
- *Settings → Environments* : `production` et `infra` avec *Required reviewers* ; `dev`/`staging` limités à la branche `main`.
- *Settings → Code security* : Dependabot alerts, secret scanning et push protection.

## 4. Risques résiduels et exceptions acceptées

| Constat | Justification | Mesure compensatoire / évolution |
|---|---|---|
| Key Vault et Blob joignables publiquement | Runner GitHub et poste de l'étudiant doivent y accéder ; points de terminaison privés = coût | Entra ID obligatoire (pas de clé), journal d'audit, RBAC par secret ; `enable_private_endpoints = true` prêt |
| L'application se connecte à PostgreSQL (prod) avec le compte administrateur | Créer un rôle applicatif nécessite un accès réseau à la base privée depuis Terraform | Évolution : authentification Entra ID à PostgreSQL via Workload Identity (plus aucun mot de passe) |
| L'état Terraform contient les secrets générés | Inhérent à `random_password` | État chiffré, sans clé partagée, accès Entra ID restreint, versionné |
| L'identité Terraform des PR a des droits d'écriture | Simplicité (une identité) | Évolution : identité « plan » en lecture seule |
| RabbitMQ et PostgreSQL in-cluster : 1 réplica | Coût, environnements hors prod | Prod sur PostgreSQL managé ; RabbitMQ sur PV (messages persistants) |
| Constats Trivy « config » non bloquants | Certains constats correspondent aux exceptions ci-dessus | Publiés dans l'onglet Security et triés à chaque PR |
