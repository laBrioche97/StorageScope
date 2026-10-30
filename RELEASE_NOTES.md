# StorageScope 3.7.2

- Mac : l’index complet et le résumé restent dans Application Support, indépendamment de la version installée. Les anciens résumés en cache sont repris automatiquement lorsqu’ils existent.
- La restauration précède toute première analyse automatique. Une taille inconnue dans un dossier ne relance plus une analyse complète lorsqu’une analyse enregistrée existe. Un problème de lecture est expliqué et journalisé, sans effacement ni reconstruction silencieuse de l’index.
- Les changements connus du disque sont repris en arrière-plan depuis le journal macOS. La date et l’identité de l’analyse complète restent conservées lors d’une mise à jour. Si le journal est perdu, les anciens résultats restent disponibles et une nouvelle analyse est proposée explicitement.
- Les événements historiques sont regroupés avant lecture des dossiers. Une mémoire bornée des événements déjà traités est conservée avec le curseur du journal, pour éviter de relire les mêmes sous-arbres aux ouvertures suivantes.
- Mac et Windows : bannière visible dès la détection d’une nouvelle version, bouton « Mettre à jour et redémarrer », et accès permanent avec le numéro de version même après « Plus tard ». Les offres conservées hors ligne et le report pendant une analyse sont expliqués dans l’interface.
- Validation du remplacement réel de la version publiée 3.7.1 avec une arborescence de 2 305 fichiers, conservation de l’analyse et reprise des changements entre les versions. Les contrôles de signature, d’intégrité, d’annulation et de conservation de l’ancienne application restent actifs.

Apple Silicon, macOS 14 minimum. Le paquet Mac reste une version de test sans Developer ID ni notarisation ; Windows reste sans Authenticode. Les mises à jour sont authentifiées et vérifiées. Aucun paquet Intel n’est publié.
