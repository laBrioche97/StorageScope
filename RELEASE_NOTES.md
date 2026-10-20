# StorageScope 3.4.2

- L’Explorateur conserve le mode choisi en ouvrant un dossier depuis les bulles, la liste ou l’historique. Le mode préféré reste visible.
- « Autres éléments » et « Voir les fichiers » ouvrent une liste temporaire ; la navigation suivante retrouve votre mode préféré.
- Le graphique conserve son panneau et le chargement Brioche. Les dossiers vides, inaccessibles ou de taille inconnue affichent un état explicite.
- Les jeux Epic conservent leurs identifiants et manifestes pour préparer et vérifier leur désinstallation.
- Lorsqu’une commande officielle est enregistrée pour le jeu, StorageScope l’utilise. Sinon, « Désinstaller avec Epic » ouvre le launcher et indique comment confirmer dans sa bibliothèque ; StorageScope suit ensuite le résultat.
- L’ouverture d’Epic seule n’est jamais annoncée comme une désinstallation réussie. L’absence du launcher, l’annulation du suivi et les résultats non confirmés sont explicités.
- Aucun dossier de jeu ni sauvegarde n’est supprimé directement. Les protections de nettoyage et le fonctionnement hors ligne sont conservés.

## Installation et mises à jour

Téléchargez l’installateur Windows depuis https://labrioche.tech/telechargements puis ouvrez-le. Il sélectionne la version native x64 ou ARM64. Les versions compatibles déjà configurées proposent cette mise à jour après vérification du manifeste signé ; son installation demande votre accord.

Le paquet et ses métadonnées de mise à jour sont vérifiés par la clé StorageScope. L’installateur Windows reste sans signature Authenticode d’éditeur : Windows peut afficher un avertissement SmartScreen. Aucun paquet macOS non validé et non signé/notarié n’est annoncé.
