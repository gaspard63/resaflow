# Architecture

## 1. Vue applicative

ResaFlow permet de réserver des salles et du matériel. Quatre entités : **User**, **Resource**, **Reservation**, **Export**.

| Brique | Technologie | Rôle |
|---|---|---|
| Front-end | React 19 + Vite, servi par Nginx non privilégié | SPA, aucun état serveur |
| Back-end | FastAPI (Python 3.13), SQLAlchemy 2, Alembic | API REST **stateless** : JWT, RBAC user/admin, logique métier |
| Base relationnelle | PostgreSQL 17 | Schéma versionné (Alembic), contrainte d'exclusion anti-chevauchement |
| Stockage objet | Azure Blob Storage (Azurite en local) | Photos des ressources, pièces jointes, exports PDF, sauvegardes |
| File de messages | RabbitMQ 4 | Broker Celery |
| Traitement asynchrone | Worker Celery (+ beat) | E-mail de confirmation, miniature, export PDF, purge planifiée, rappels planifiés |

### Flux « réservation »

```mermaid
sequenceDiagram
  participant U as Navigateur
  participant T as Traefik
  participant A as API
  participant DB as PostgreSQL
  participant Q as RabbitMQ
  participant W as Worker
  participant M as SMTP
  U->>T: POST /api/v1/reservations (JWT)
  T->>A: (TLS terminé, limitation de débit sur /auth)
  A->>DB: vérification du créneau + INSERT
  Note over DB: contrainte EXCLUDE USING gist :<br/>deux requêtes concurrentes ne peuvent<br/>pas réserver le même créneau
  A->>Q: send_reservation_confirmation(id)
  A-->>U: 201 Created
  Q->>W: tâche (acks tardifs)
  W->>DB: lecture réservation
  W->>M: e-mail de confirmation
```

### Choix applicatifs justifiés

- **API sans état** : aucune session serveur, JWT signé (HS256, 30 min) → n'importe quel pod peut servir n'importe quelle requête, condition de l'autoscaling horizontal.
- **Double protection anti-chevauchement** : vérification applicative (message clair) + contrainte d'exclusion PostgreSQL (vraie garantie en concurrence, avec plusieurs réplicas).
- **État des tâches en base** (table `exports`) plutôt que dans un backend de résultats Celery : une seule source de vérité, le front interroge l'API.
- **Une image back-end, deux cibles** (`api`, `worker`) : mêmes dépendances et même code, couches partagées, mais deux images distinctes et deux Deployments distincts.
- **Panne du broker tolérée** : si RabbitMQ est indisponible, la réservation est créée, l'erreur est journalisée (dégradation contrôlée).
- **Fichiers validés côté serveur** : taille, type déclaré ET contenu réel (Pillow / signature PDF), clés opaques (UUID) → ni traversée de chemin ni fichier déguisé.

## 2. Vue infrastructure Azure

```mermaid
flowchart TB
  subgraph RG["Groupe de ressources rg-resaflow-<suffixe> (France Central)"]
    subgraph VNET["VNet 10.20.0.0/16"]
      subgraph SAKS["snet-aks 10.20.0.0/23 (NSG : 80/443 entrants)"]
        SYS["Pool système Standard_D2as_v7<br/>autoscaler 1→3"]
        SPOT["Pool Spot Standard_D2as_v7<br/>autoscaler 0→1 (quota Spot : 3 vCPU)"]
      end
      SPG["snet-postgres 10.20.2.0/24 (délégué)"]
    end
    AKS["AKS (Free) — Entra ID + Azure RBAC,<br/>OIDC + Workload Identity, CNI Overlay + Cilium,<br/>Secrets Store CSI, mises à jour auto"]
    PG[("PostgreSQL Flexible 17 B1ms<br/>privé, TLS, PITR 7 j")]
    ST[("Storage Account LRS<br/>sans clé partagée, double chiffrement,<br/>versionnage, cycle de vie")]
    KV["Key Vault (RBAC, purge protégée)"]
    ACR["ACR Basic (sans admin)"]
    LA["Log Analytics : audit AKS, Key Vault,<br/>PostgreSQL, Blob"]
    BUD["Budget mensuel + alertes"]
    ID["Identités managées :<br/>app-dev / app-staging / app-prod,<br/>github-deploy, github-terraform"]
  end
  SPG --- PG
  AKS --- SAKS
  ACR -->|AcrPull kubelet| AKS
  ID -->|fédération OIDC| AKS
  GH[GitHub Actions] -->|OIDC, sans secret| ID
```

### Arbitrages d'infrastructure

| Décision | Alternative écartée | Raison |
|---|---|---|
| **Un cluster, trois namespaces** (dev/staging/prod) | Un cluster par environnement | Coût ×3 ; la séparation est assurée par namespaces + PSS + quotas + NetworkPolicies + identités Azure distinctes par environnement + conteneurs Blob et secrets distincts. Limite assumée : un incident de nœud touche tous les environnements. |
| **PostgreSQL managé en prod**, **StatefulSet sur PV** en dev/staging | Tout managé / tout in-cluster | Prod : sauvegardes PITR, correctifs, chiffrement gérés par Azure. Dev/staging : ~0 € de plus et démonstration explicite du stockage persistant Kubernetes exigé par le sujet. |
| **RabbitMQ in-cluster** (1 réplica sur PV) | Azure Service Bus | Celery supporte nativement AMQP ; Service Bus aurait ajouté un transport moins éprouvé. Un cluster RabbitMQ à 3 nœuds (quorum queues) serait la cible d'une vraie prod. |
| **Traefik** | ingress-nginx | ingress-nginx n'est plus maintenu depuis mars 2026 (aucun correctif de sécurité). Traefik offre nativement la répartition pondérée (canary) et la limitation de débit. |
| **AKS Free tier** | Standard (SLA 99,9 %) | Projet pédagogique : le SLA du plan de contrôle ne justifie pas ~70 $/mois. |
| **CNI Overlay + Cilium** | kubenet / Azure CNI classique | Peu d'adresses VNet consommées, NetworkPolicies appliquées par eBPF. |
| **Pas de points de terminaison privés par défaut** | Private endpoints Blob/Key Vault | ~7 $/mois chacun ; le code est prêt (`enable_private_endpoints = true`). Compensé par l'authentification Entra ID obligatoire (clés partagées désactivées) et TLS. |
| **sslip.io** pour le nom d'hôte | Domaine acheté + zone DNS | Pas de coût ni de délai ; `INGRESS_HOST` permet de passer à un vrai domaine. |

## 3. Vue Kubernetes

| Objet | API | Worker | Beat | Front | PostgreSQL | RabbitMQ |
|---|---|---|---|---|---|---|
| Contrôleur | Deployment (+ canary) | Deployment | Deployment (Recreate, 1) | Deployment | StatefulSet + PVC | StatefulSet + PVC |
| Scaling | HPA 2→10 (CPU 70 %) | HPA 1→5 | 1 fixe | 2 fixes | 1 | 1 |
| Disponibilité | PDB minAvailable 1, maxUnavailable 0, preStop | PDB maxUnavailable 1 | — | PDB minAvailable 1 | — | — |
| Sondes | startup, readiness (base), liveness | readiness/liveness (métriques) | — | readiness/liveness | pg_isready | rabbitmq-diagnostics |
| Sécurité | non-root, FS lecture seule, caps supprimées, seccomp | idem | idem | idem (UID 101) | non-root (UID 70) | non-root (UID 999) |

Autres objets : ConfigMap, SecretProviderClass (Key Vault → Secret), ServiceAccount (Workload Identity, sans jeton Kubernetes monté), Job de migration (hook Helm), CronJob de sauvegarde, IngressRoute + Middlewares + Certificate, NetworkPolicies (deny-all + flux explicites), Role/RoleBinding opérateur, ServiceMonitor, PrometheusRule, ConfigMap de dashboards. Au niveau namespace (Terraform) : Pod Security Standards `restricted`, ResourceQuota, LimitRange.

## 4. Chaîne CI/CD

```mermaid
flowchart LR
  PR[Pull request] --> Q1[ruff · bandit · pytest+PostgreSQL]
  PR --> Q2[eslint · vitest · npm audit · build]
  PR --> Q3[gitleaks · hadolint · Trivy config]
  PR --> Q4[helm lint · kubeconform]
  Q1 & Q2 & Q3 & Q4 --> M{merge main}
  M --> B[build ×3 · Trivy image · SBOM · push ACR]
  B --> D[dev : rolling + fumée]
  D --> S[staging : rolling + fumée + k6]
  S --> AP{{approbation manuelle}}
  AP --> C[prod : canary 10 %]
  C --> CA[analyse Prometheus 5 min]
  CA -->|sain| P[promotion rolling]
  CA -->|KO| R[retour arrière]
```

Voir [`deploiement.md`](deploiement.md) pour le détail.
