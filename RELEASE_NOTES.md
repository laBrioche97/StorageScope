# StorageScope 3.4.3

- Recherche des mises à jour à chaque ouverture, en arrière-plan, avec une icône permanente à côté de la version. L’offre vérifiée reste visible hors ligne ; elle est revalidée avant installation.
- Un clic sur l’icône de mise à jour lance le téléchargement, les vérifications, l’installation et le redémarrage. Progression et annulation sont disponibles ; l’installation attend la fin des analyses et opérations de nettoyage.
- L’Explorateur propose les stockages locaux lorsqu’il y en a plusieurs et ouvre exactement la racine choisie, même si le disque était déjà sélectionné. Historique et filtres de l’explorateur sont réinitialisés ; le mode Liste et bulles reste conservé. Les stockages déconnectés et résultats obsolètes sont gérés.
- Nouvelle fenêtre Epic avec étapes illustrées disponibles hors ligne, sélecteur d’interface classique/nouvelle, captures officielles agrandissables, ouverture du launcher, vérification immédiate et arrêt du suivi. Le menu de désinstallation illustré est celui de l’interface classique ; les variantes de présentation sont expliquées. La confirmation dans Epic reste nécessaire lorsqu’aucun désinstalleur officiel du jeu n’est enregistré.
- Seule la vérification des enregistrements et manifestes locaux confirme la désinstallation. Aucun dossier de jeu ni sauvegarde n’est supprimé directement. Aucun moteur tiers ni compte supplémentaire n’est ajouté.

## Installation et confiance

Téléchargez l’installateur Windows depuis https://labrioche.tech/telechargements puis ouvrez-le. Il sélectionne la version native x64 ou ARM64. Depuis 3.4.2, recherchez cette mise à jour dans Plus → Rechercher des mises à jour ; les contrôles de signature du manifeste et du paquet restent applicables. À partir de 3.4.3, la détection visible se fait à chaque ouverture.

Le paquet et ses métadonnées sont vérifiés par la clé de mise à jour StorageScope. L’installateur Windows reste sans signature Authenticode d’éditeur : Windows peut afficher un avertissement SmartScreen. Aucun paquet macOS non validé et non signé/notarié n’est annoncé.
