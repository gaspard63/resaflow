# Observabilité

## 1. Les trois piliers

| Pilier | Émission | Collecte / stockage | Consultation |
|---|---|---|---|
| **Métriques** | API : `prometheus-fastapi-instrumentator` (RED) + compteurs métier/sécurité ; worker : serveur `/metrics` (port 9100) alimenté par les signaux Celery ; RabbitMQ : plugin `rabbitmq_prometheus` ; Traefik, cert-manager, Loki, Tempo | Prometheus (kube-prometheus-stack), découverte par `ServiceMonitor`, rétention 15 j | Grafana, Alertmanager |
| **Logs** | JSON sur stdout (horodatage, niveau, logger, `trace_id`, champs métier) ; logger `security` dédié | Grafana Alloy (DaemonSet) → Loki (rétention 14 j), label `category` | Grafana (Explore, dashboard Sécurité) |
| **Traces** | OpenTelemetry (FastAPI, SQLAlchemy, Celery) exporté en OTLP/HTTP | Tempo (rétention 72 h) | Grafana : trace ↔ logs par `trace_id` |

## 2. Métriques exposées

| Métrique | Type | Signification |
|---|---|---|
| `http_requests_total{handler,method,status}` | counter | Requêtes HTTP (taux, erreurs) |
| `http_request_duration_seconds_bucket{handler,method,le}` | histogram | Latence (buckets incluant le seuil SLO 0,3 s) |
| `resaflow_reservations_created_total{resource_type}` | counter | Réservations créées |
| `resaflow_reservation_conflicts_total` | counter | Créneaux refusés car déjà pris |
| `resaflow_uploads_total{kind,outcome}`, `resaflow_upload_size_bytes` | counter, histogram | Téléversements acceptés/rejetés |
| `resaflow_tasks_enqueued_total{task}` | counter | Tâches envoyées dans la file |
| `resaflow_auth_attempts_total{outcome}` | counter | Connexions réussies / échouées |
| `resaflow_access_denied_total` | counter | Refus RBAC |
| `resaflow_worker_tasks_total{task,state}` | counter | Tâches exécutées (success/failure/retry) |
| `resaflow_worker_task_duration_seconds` | histogram | Durée des tâches |
| `resaflow_worker_tasks_in_progress` | gauge | Tâches en cours |

Le label `resaflow_io_track` (`stable` / `canary`) est ajouté par le ServiceMonitor à partir des labels de pod : il permet de comparer les deux versions pendant un déploiement canary.

## 3. SLI / SLO

| SLO | SLI (PromQL, règle d'enregistrement) | Objectif | Fenêtre | Budget d'erreur |
|---|---|---|---|---|
| **Disponibilité de l'API** | `1 - resaflow:api_error_ratio:rate30d` = part des requêtes `/api/*` sans réponse 5xx | **99,5 %** | 30 jours glissants | 0,5 % ≈ 3 h 36 min d'indisponibilité totale / mois |
| **Latence de l'API** | `resaflow:api_latency_good_ratio:rate1d` = part des requêtes `/api/*` servies en moins de 300 ms | **95 %** | 30 jours glissants | 5 % de requêtes lentes |

Pourquoi ces seuils : 99,5 % est cohérent avec un cluster AKS *Free* (sans SLA du plan de contrôle) et un PostgreSQL Burstable sans haute disponibilité ; 300 ms au p95 correspond à une interface perçue comme instantanée pour des listes et réservations.

**Politique de budget d'erreur** : budget < 25 % → gel des mises en production fonctionnelles, seules les corrections de fiabilité passent ; budget épuisé → post-mortem.

### Alertes de burn rate (méthode multi-fenêtres)

| Alerte | Condition | Signification | Sévérité |
|---|---|---|---|
| `ResaflowErrorBudgetFastBurn` | taux d'erreurs > 14,4 × 0,5 % sur 1 h **et** sur 5 min | 2 % du budget mensuel brûlé en 1 h | critical |
| `ResaflowErrorBudgetSlowBurn` | > 6 × 0,5 % sur 6 h **et** sur 30 min | 5 % du budget brûlé en 6 h | warning |
| `ResaflowLatencySLOBreach` | bonnes requêtes < 95 % sur 1 h **et** 5 min | SLO de latence non tenu | warning |

La double fenêtre évite les faux positifs (pic bref) tout en réinitialisant vite l'alerte une fois l'incident résolu.

## 4. Alertes d'exploitation

| Alerte | Déclencheur |
|---|---|
| `ResaflowApiUnavailable` | aucun pod API disponible pendant 2 min |
| `ResaflowWorkerTasksFailing` | > 0,05 échec de tâche/s pendant 10 min |
| `ResaflowQueueBacklog` | > 100 messages en attente pendant 10 min |
| `ResaflowBackupFailed` / `ResaflowBackupMissing` | job de sauvegarde en échec / aucune sauvegarde réussie depuis 26 h |
| `ResaflowAuthBruteForce` | > 1 échec de connexion/s pendant 5 min |
| `ResaflowAccessDeniedSpike` | > 20 refus RBAC en 15 min |
| `ResaflowHpaAtMax` | HPA au maximum depuis 15 min (capacité insuffisante) |
| `ResaflowPodCrashLooping` | > 3 redémarrages en 15 min |
| `ResaflowVolumeAlmostFull` | PersistentVolume plein à plus de 85 % |
| `ResaflowCertificateExpiringSoon` | certificat TLS à moins de 14 jours d'échéance (le renouvellement automatique à J-30 a échoué) |

Routage : Alertmanager regroupe par `alertname`/`namespace`, inhibe les *warning* quand une *critical* identique est active, et notifie un webhook (Teams/Slack/Discord) configuré par la variable Terraform `alertmanager_webhook_url`.

## 5. Tableaux de bord Grafana

| Dashboard | Contenu |
|---|---|
| **ResaFlow — Service API (SLO & RED)** | disponibilité 30 j, budget d'erreur restant, % sous 300 ms, p95 ; débit par code ; erreurs stable vs canary ; latences p50/p95/p99 et par route ; métriques métier ; réplicas HPA, CPU utilisé/demandé (right-sizing), mémoire ; annotations de déploiement |
| **ResaFlow — Worker & file** | messages en attente, tâches en cours, échecs, pods ; débit par tâche/état, durée p95, profondeur de file, envoyées vs traitées |
| **ResaFlow — Sécurité** | échecs/succès de connexion, refus RBAC, fichiers rejetés, événements de sécurité par type (Loki), journal des événements |

Accès : `kubectl port-forward -n monitoring svc/kube-prometheus-stack-grafana 3000:80` puis http://localhost:3000 (Grafana n'est pas exposé sur Internet).

## 6. Requêtes utiles

```logql
# Événements de sécurité de la prod
{namespace="resaflow-prod", category="security"} | json | line_format "{{.event}} user={{.user_id}} ip={{.ip}}"

# Échecs de connexion par IP sur 1 h
sum by (ip) (count_over_time({namespace="resaflow-prod"} | json | event="auth.login.failure" [1h]))

# Erreurs de l'API avec leur trace
{namespace="resaflow-prod", container="api", level="ERROR"} | json
```

```promql
# Right-sizing : CPU réellement consommé / CPU demandé, par conteneur
sum by (container) (rate(container_cpu_usage_seconds_total{namespace="resaflow-prod",container!=""}[1h]))
  / sum by (container) (kube_pod_container_resource_requests{namespace="resaflow-prod",resource="cpu"})
```
