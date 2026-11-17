# FinOps — coût chiffré, optimisations appliquées, mesure de l'effet

## 1. Hypothèses de chiffrage

- Région **France Central**, prix publics à la demande en **USD** (Azure facture en EUR au taux Microsoft du mois), relevés en octobre 2026 : VM `Standard_B2s_v2` 0,0944 $/h et `Standard_D2as_v5` 0,101 $/h ([azurespeed.com](https://www.azurespeed.com/AzureVmPricing/Regions/francecentral)) ; `Standard_D2as_v5` Spot 0,019 $/h ([devzero.io](https://www.devzero.io/instances/azure/Standard_D2as_v5)) ; PostgreSQL Flexible B1ms ≈ 14 $/mois ([bytebase.com](https://www.bytebase.com/dbcost/azure-flexible/instance/B1ms.md)).
- Postes marqués « ≈ » : ordres de grandeur des grilles publiques (disques, load balancer, ACR, stockage), **à confirmer** dans la [calculatrice Azure](https://azure.microsoft.com/pricing/calculator/) puis par la **facture réelle** (§4).
- Mois = 730 h. Plage d'ouverture : lundi–vendredi, 06:15–18:30 UTC (12,25 h × ~21,7 jours ≈ **266 h**, soit 36 % du temps).
- Une seule plateforme héberge les trois environnements (un cluster, trois namespaces).

## 2. Coût mensuel : avant / après optimisation

| Poste | Sans optimisation | Avec optimisations | Optimisation |
|---|---:|---:|---|
| Nœuds AKS (calcul) | 3 × B2s_v2 × 730 h = **206,7 $** | 2 × B2s_v2 × 266 h = **50,2 $** | n°1 Spot + n°2 arrêt planifié + n°3 right-sizing |
| Nœud Spot workers | — | 1 × D2as_v5 Spot × 266 h = **5,1 $** | n°1 |
| Disques OS des nœuds (P6 64 Go) | 3 × ≈ 9,9 $ = **29,7 $** | 3 nœuds × 36 % ≈ **10,8 $** | n°2 (nœuds supprimés à l'arrêt) |
| PostgreSQL Flexible B1ms (calcul) | **14,0 $** | 14 × 36 % ≈ **5,1 $** | n°2 |
| PostgreSQL stockage 32 Go | ≈ **4,0 $** | ≈ **4,0 $** | — |
| Volumes persistants (Prometheus, Loki, Tempo, Grafana, PostgreSQL et RabbitMQ in-cluster) | ≈ **5,1 $** | ≈ **5,1 $** | n°4 (rétentions bornées) |
| Load balancer Standard + IP publique | ≈ **21,9 $** | ≈ **21,9 $** | — |
| Container Registry Basic | ≈ **5,0 $** | ≈ **5,0 $** | choix de SKU |
| Blob Storage, Key Vault, Log Analytics (≤ 5 Go gratuits) | ≈ **1,0 $** | ≈ **1,0 $** | n°4 (cycle de vie, plafond 1 Go/j) |
| AKS plan de contrôle (Free) | 0 $ | 0 $ | choix de SKU |
| **Total estimé** | **≈ 287 $ / mois** | **≈ 108 $ / mois** | **≈ −62 %** |

Le budget Terraform (100 $/mois par défaut) alerte à 50 %, 80 %, 100 % réels et 100 % prévisionnel.

## 3. Optimisations réellement appliquées

### n°1 — Pool de nœuds Spot pour les workers Celery
- **Quoi** : pool `spot` (`Standard_D2as_v5`, priorité Spot, éviction *Delete*, autoscaler 0→3, `spot_max_price = -1`). Les pods worker tolèrent le taint Spot et le **préfèrent** par affinité ; ils peuvent se replier sur le pool système en cas d'éviction.
- **Pourquoi c'est sûr** : les tâches sont idempotentes, `task_acks_late` + `task_reject_on_worker_lost` remettent la tâche en file si le nœud disparaît (démontré par `demo-resilience.ps1`, étape 3).
- **Effet attendu** : capacité asynchrone à 0,019 $/h au lieu de 0,101 $/h (**−81 %**) ; le pool système reste à 2 nœuds au lieu de 3.
- **Preuve** : `kubectl get pods -n resaflow-prod -o wide -l app.kubernetes.io/component=worker` + `kubectl get nodes -L kubernetes.azure.com/scalesetpriority`.

### n°2 — Arrêt planifié hors heures ouvrées (AKS + PostgreSQL)
- **Quoi** : workflow `finops-schedule.yml` : `az aks stop` / `az postgres flexible-server stop` à 18:30 UTC, démarrage à 06:15 UTC, en semaine uniquement. Identité dédiée avec un **rôle personnalisé** limité à `start`/`stop`/`read`.
- **Effet attendu** : le calcul n'est plus facturé que 266 h sur 730 (**−64 %** sur VM, disques OS et vCores PostgreSQL).
- **Limite assumée** : environnement indisponible la nuit — acceptable pour un projet pédagogique, inacceptable pour une vraie prod (on garderait la prod allumée et n'arrêterait que dev/staging, dans un cluster séparé).

### n°3 — Right-sizing des requests/limits à partir des mesures
- **Quoi** : requests fixées d'après la consommation observée sous charge (panneau Grafana « CPU utilisé / demandé », test k6). Exemple : API 100m/192Mi, front 20m/32Mi, beat 20m/128Mi ; LimitRange par défaut pour éviter les pods sans requests.
- **Effet** : l'ordonnanceur place davantage de pods par nœud → 2 nœuds système suffisent pour les 3 environnements + la supervision (au lieu de 3).
- **Mesure** : capture du panneau avant/après et `kubectl describe nodes | Select-String "Allocated resources" -Context 0,6`.

### n°4 — Stockage et journaux bornés
- Cycle de vie Blob : sauvegardes en tier *Cool* à J+7 et supprimées à J+30, exports supprimés à J+8, anciennes versions purgées ; rétention Prometheus 15 j / 8 Go, Loki 14 j, Tempo 72 h ; Log Analytics plafonné à 1 Go/jour, catégorie `kube-audit-admin` (écritures) plutôt que `kube-audit` (volume ×10).
- Choix de SKU sobres : AKS Free, ACR Basic, PostgreSQL Burstable, stockage LRS, pas de redondance géographique.

## 4. Mesure de l'effet (méthode)

1. Laisser tourner la plateforme **7 jours sans** l'arrêt planifié (workflow désactivé) — période de référence.
2. Activer le workflow (et le pool Spot s'il ne l'était pas) — date D.
3. Après 7 jours, exécuter :
   ```powershell
   ./scripts/finops/cost-report.ps1 -ResourceGroup rg-resaflow-<suffixe> -From <D-7> -To <D+7> -OptimizationDate <D>
   ```
   Le script interroge l'API Cost Management, exporte le coût quotidien par service (CSV) et affiche la moyenne journalière avant/après et la projection mensuelle.
4. Compléter le tableau ci-dessous (et joindre la courbe *Cost analysis* du portail, vue quotidienne groupée par *Service name*).

| Indicateur | Avant (D−7 → D) | Après (D → D+7) | Écart |
|---|---:|---:|---:|
| Coût moyen / jour — Virtual Machines | | | |
| Coût moyen / jour — Azure Database for PostgreSQL | | | |
| Coût moyen / jour — total groupe de ressources | | | |
| Heures de nœuds facturées (Cost analysis, *Meter*) | | | |

> Les coûts Azure apparaissent avec 8 à 24 h de décalage : ne pas conclure sur le jour même.

## 5. Pistes non retenues (et pourquoi)

| Piste | Gain potentiel | Raison du rejet |
|---|---|---|
| Réservation 1 an / Savings Plan | −30 à −40 % | Engagement incompatible avec un projet de 2 mois |
| Container Apps / serverless | Facturation à l'usage | Le sujet impose Kubernetes |
| KEDA (scale-to-zero des workers sur la longueur de file) | Quelques $ | Ajouté comme évolution : l'HPA CPU suffit au volume actuel |
| Nœuds ARM (Ampere, `B2pls_v2`) | −20 % | Imposerait des images multi-architecture ; à envisager ensuite |
