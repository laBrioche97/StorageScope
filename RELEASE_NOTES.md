StorageScope 3.2.1

• Correction du blocage « Ne répond pas » pendant une analyse Windows : l’énumération à la racine et le classement final s’exécutent entièrement en arrière-plan.
• Affichage des résultats par lots : les tableaux triés et regroupés ne sont plus recalculés pour chaque fichier ajouté, y compris avec 10 000 propositions de nettoyage.
• Annulation prise en compte pendant l’énumération des dossiers, sans afficher un résultat annulé ni réutiliser une ancienne progression.
• Compteurs mis à jour pendant l’analyse et étapes de classement/affichage indiquées explicitement.
• Tests supplémentaires de réactivité du fil d’interface, d’annulation et d’affichage de grands volumes.

Depuis StorageScope 3.2.0, utilisez « Mises à jour », puis acceptez l’installation. Depuis les versions 3.0/3.1, une installation manuelle reste nécessaire. Le fonctionnement local ne nécessite pas Internet.

Améliorations conservées depuis StorageScope 3.2.0 :

• Correction du crash Windows au changement d’onglet lié aux icônes et à l’accessibilité.
• Corbeille exécutée dans un processus isolé, interfaces Windows typées et vérification de l’identité juste avant l’action. Aucun effacement définitif de secours.
• Diagnostic local des erreurs et arrêts anormaux, export depuis le menu ⋯, sans transmission automatique.
• Logos recherchés dans les installations et caches locaux, puis sur le CDN officiel Steam pour les identifiants Steam vérifiés. Cache hors ligne et icône neutre si indisponible.
• Taille des installations calculée progressivement dès l’inventaire : déclarée, mesurée, partielle ou indisponible. Taille et conséquences affichées avant désinstallation ; sauvegardes conservées par StorageScope.
• Filtres indépendants par section, catégories directement accessibles, tri décroissant et indication des 500 plus gros fichiers retenus par catégorie.
• Clic droit : ouvrir, ouvrir le dossier, afficher dans l’Explorateur, copier le chemin, propriétés, corbeille ou désinstallation officielle.
• Mises à jour proposées après accord, manifeste signé RSA-PSS, contrôle de provenance, taille et SHA-256. La vérification réseau ne bloque pas le fonctionnement local.
• Installation vérifiée avant suppression des anciennes versions gérées par StorageScope : une seule version après remplacement réussi ; ancienne version conservée si le remplacement échoue.

Première installation manuelle nécessaire depuis une ancienne version 3.0/3.1. Les suivantes seront proposées dans StorageScope.

Cette distribution Windows x64/ARM64 ne possède pas encore de certificat Authenticode. La signature du manifeste de mise à jour ne remplace pas ce certificat et Windows peut afficher SmartScreen. Aucun installateur macOS n’est publié tant que la signature Apple et la notarisation ne sont pas activées.

Les tailles représentent les fichiers accessibles de l’installation, pas une promesse d’espace libéré. Les composants partagés, sauvegardes et résidus ne sont jamais supprimés automatiquement avec un jeu.
