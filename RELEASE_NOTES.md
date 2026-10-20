# StorageScope 3.4.1

- Correctif : recherche de doublons autorisée dans les dossiers personnels principaux, qui restent protégés contre la suppression.
- Interface native simplifiée : navigation latérale, version visible à côté du nom, recherche et filtres propres à chaque section.
- Explorateur avec liste et bulles synchronisées, fichiers et dossiers du niveau courant, navigation précédente/suivante et regroupement adapté à la fenêtre.
- Animation de chargement Brioche, progression et annulation explicites ; prise en compte de la réduction des animations.
- Icônes cohérentes dans la vue d’ensemble, les catégories et le nettoyage.
- Sélection des temporaires reconnus corrigée malgré les filtres et la virtualisation des lignes.
- Recherche de doublons indépendante avec progression, résultats visibles, comparaison SHA-256 et conservation d’un exemplaire.
- Fonctionnement hors ligne, protections de suppression, sauvegardes conservées et logos en cache pendant la session.

## Installation et mises à jour

Téléchargez l’installateur Windows depuis https://labrioche.tech/telechargements puis ouvrez-le. Il sélectionne la version native x64 ou ARM64. Les versions compatibles déjà configurées proposent cette mise à jour après vérification du manifeste signé ; son installation demande votre accord.

Le paquet et ses métadonnées de mise à jour sont vérifiés par la clé StorageScope. L’installateur Windows reste sans signature Authenticode d’éditeur : Windows peut afficher un avertissement SmartScreen. Aucun paquet macOS non validé et non signé/notarié n’est annoncé.
