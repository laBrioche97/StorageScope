# StorageScope 3.4.4

- Désinstallation officielle des composants NVIDIA CUDA 12 reconnus : développement, documentation, runtime et intégration Visual Studio. Vérification de l’enregistrement, des signatures Microsoft/NVIDIA, des architectures et de l’identité de l’exécutable et de la DLL avant lancement. Les autres commandes utilisant un interpréteur restent bloquées.
- Chaque désinstallation cible le composant choisi, ouvre l’interface NVIDIA et ne réussit qu’après vérification de la disparition de ses enregistrements. Annuler dans StorageScope arrête uniquement le suivi. Les dossiers CUDA partagés sont signalés ; leur taille ne garantit pas l’espace libéré. Aucun dossier CUDA ni pilote graphique n’est effacé directement.
- Navigation avec zoom doux et fondu de 220 ms. Le contenu reste visible pendant la lecture du dossier suivant ; l’état de lecture apparaît immédiatement et la brioche après 150 ms si nécessaire.
- Cache de session des 32 derniers dossiers, limité à 64 Mio supplémentaires, avec disposition des bulles, sélection et défilement. Les vues en cache sont réaffichées immédiatement puis revalidées en arrière-plan. Les actualisations, analyses, nettoyages, désinstallations et changements de stockage invalident les vues concernées.
- Réutilisation des contrôles des bulles et transitions discrètes des sections et commandes. Les préférences de réduction des animations sont respectées ; les transitions Windows sont également désactivées en contraste élevé.

## Installation et confiance

Téléchargez l’installateur Windows depuis https://labrioche.tech/telechargements puis ouvrez-le. Il sélectionne la version native x64 ou ARM64. Depuis 3.4.3, l’icône près du numéro de version recherche cette mise à jour à chaque ouverture et permet de l’installer.

Le paquet et ses métadonnées sont vérifiés par la clé de mise à jour StorageScope. L’installateur Windows reste sans signature Authenticode d’éditeur : Windows peut afficher un avertissement SmartScreen. Aucun paquet macOS non validé et non signé/notarié n’est annoncé.