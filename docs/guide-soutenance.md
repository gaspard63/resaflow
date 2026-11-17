# Fiche de soutenance — BC3 (ResaFlow)

## Le pitch en 1 minute

« ResaFlow est une application de réservation volontairement simple : l'effort porte sur tout ce qui l'entoure. Trois images Docker multi-stage, non-root et sans secret, construites une seule fois et promues de dev à la prod. Un chart Helm déploie l'application sur AKS dans trois namespaces isolés, avec autoscaling, PDB, NetworkPolicies et stockage persistant. GitHub Actions teste, scanne, construit, déploie en dev puis en staging avec un test de charge, et en prod en **canary à 10 %** jugé par Prometheus, avec retour arrière automatique — sans un seul secret stocké, grâce à OIDC. Terraform reconstruit toute la plateforme de zéro en 20 minutes. La supervision repose sur deux SLO et des alertes de burn rate, la sécurité sur 19 contrôles ISO 27001 tracés jusqu'au code, et quatre optimisations FinOps divisent le coût estimé par près de trois. »

## Les 5 messages à faire passer

1. **Un artefact, plusieurs environnements** : la même image (même digest) traverse dev, staging, prod.
2. **Le risque est borné** : canary 10 %, décision sur métriques réelles, retour arrière automatique.
3. **Zéro secret stocké** : OIDC pour la CI, Workload Identity pour les pods, Key Vault pour l'application.
4. **Reproductible** : détruire puis recréer la plateforme prouve que rien n'est fait à la main.
5. **Chaque arbitrage est assumé et documenté** : un cluster pour trois environnements, AKS Free, RabbitMQ à un réplica, avec ce qu'il faudrait changer en vraie production.

## Questions probables du jury

**Pourquoi une API sans état ?** Pour que n'importe quel pod serve n'importe quelle requête : c'est la condition de l'autoscaling horizontal et des rolling updates sans perte de session.

**Comment évitez-vous les doubles réservations avec plusieurs réplicas ?** Une vérification applicative ne suffit pas en concurrence ; la contrainte d'exclusion PostgreSQL (`EXCLUDE USING gist`) garantit au niveau de la base qu'aucun chevauchement n'est enregistré.

**Que se passe-t-il si un nœud Spot est évincé en pleine tâche ?** Les tâches sont idempotentes et acquittées après exécution (`acks_late`, `reject_on_worker_lost`) : RabbitMQ remet la tâche en file, un autre worker la rejoue. Démontré par `demo-resilience.ps1`.

**Canary ou blue/green ?** Le blue/green double la capacité et bascule 100 % du trafic d'un coup. Le canary n'expose que 10 % des utilisateurs et décide sur les métriques du seul canary (5xx ≤ 1 %, p95 ≤ 500 ms).

**Comment gérez-vous les migrations de base sans coupure ?** Motif expand/contract : le schéma reste compatible avec l'ancienne version du code ; on ajoute, on utilise, puis on supprime, sur trois versions.

**Comment la CI s'authentifie-t-elle sur Azure sans secret ?** Fédération OIDC : GitHub émet un jeton signé, Azure l'échange contre un jeton d'accès court, uniquement pour la branche `main` et les environnements autorisés. Un fork ne peut rien obtenir.

**Pourquoi un seul cluster pour trois environnements ?** Le coût serait multiplié par trois. L'isolation passe par namespaces, Pod Security `restricted`, quotas, NetworkPolicies et identités distinctes. Limite assumée : un incident de nœud touche tous les environnements ; en vraie production, la prod aurait son cluster.

**Qu'est-ce qu'un SLO et un budget d'erreur ?** Le SLO est l'objectif (99,5 % de requêtes sans erreur sur 30 jours) ; le budget d'erreur est ce qui reste autorisé (0,5 %, environ 3 h 36 par mois). Sous 25 % de budget restant, on gèle les nouveautés.

**Pourquoi des alertes de burn rate multi-fenêtres ?** Une alerte sur seuil simple sonne à chaque pic. Exiger que le budget brûle vite sur 1 h ET sur 5 min ne réagit qu'aux vrais incidents et s'éteint dès qu'ils sont résolus.

**Pourquoi Traefik et pas ingress-nginx ?** ingress-nginx n'est plus maintenu depuis mars 2026 (plus de correctifs de sécurité), et Traefik fait nativement la répartition pondérée dont le canary a besoin.

**Comment prouvez-vous l'effet des optimisations FinOps ?** Sept jours sans l'arrêt planifié, sept jours avec ; `cost-report.ps1` interroge l'API Cost Management et compare le coût quotidien moyen par service.

**Quels sont vos risques résiduels ?** Key Vault et Blob joignables publiquement (mais sans clé, authentification Entra ID), connexion à la base de prod avec le compte administrateur, secrets dans l'état Terraform (chiffré, accès restreint). Tous documentés avec leur évolution.

## À préparer avant la soutenance

- [ ] Déployer avec `setup-azure.ps1`, noter l'URL dans le rapport.
- [ ] Lancer les 4 scripts de démonstration et faire les captures.
- [ ] Capturer un run complet du pipeline et un commentaire de plan Terraform.
- [ ] Mesurer les coûts avant/après avec `cost-report.ps1`, compléter le tableau du rapport.
- [ ] Exécuter `destroy-azure.ps1` après les captures pour ne pas consommer de crédit.
