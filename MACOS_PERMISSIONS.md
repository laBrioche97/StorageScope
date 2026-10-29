# Désinstaller une application sur Mac

Dans **Applications et jeux**, choisissez une application, puis **Vérifier la désinstallation**. Examinez sa taille et les éléments associés avant de confirmer. Documents, projets, réglages et sauvegardes restent conservés par défaut ; seuls les caches et journaux exactement attribués peuvent être présélectionnés.

## Autorisations

- **Gestion des apps** permet à StorageScope de gérer l’application sélectionnée. Le bouton ouvre Confidentialité et sécurité → Gestion des apps.
- **Automatisation du Finder** est un recours facultatif après un refus. « Autoriser et continuer » demande au Finder de déplacer uniquement le bundle vérifié. Activez StorageScope → Finder dans Automatisation si vous aviez refusé.
- Une **authentification administrateur** peut être demandée par macOS. Saisissez vos identifiants uniquement dans sa fenêtre système ; StorageScope ne les collecte pas.
- Les **données d’autres applications** et l’**Accès complet au disque** concernent la lecture des bibliothèques protégées. Ils ne remplacent ni Gestion des apps ni les droits administrateur. Une analyse partielle reste utilisable.

Après un changement de réglages, revenez dans StorageScope et continuez avec votre sélection. L’identité de l’application est revérifiée. Si macOS exige un redémarrage pour appliquer un accès, quittez puis relancez StorageScope et préparez à nouveau la sélection.

## Méthodes officielles et résultats

Les applications comportant des services privilégiés ou extensions exigent leur désinstalleur officiel. Le plan permet d’ouvrir l’application ou son emplacement. StorageScope ne retire pas arbitrairement les services de `/Library`, composants partagés et applications intégrées protégées par macOS.

Après un résultat non confirmé, aucun fichier associé n’est supprimé et l’action n’est pas relancée automatiquement. Actualisez l’inventaire avant de poursuivre. L’historique reste local, sans envoi automatique.

Cette version de test n’a pas de certificat Developer ID ni de notarisation. Une mise à jour peut provoquer une nouvelle demande d’autorisation.
