# StorageScope 3.6.1

- Mac : correction de la commande officielle envoyée au Finder après « Autoriser et continuer ». Elle utilise désormais la suite Standard du Finder et permet à macOS d’afficher sa fenêtre d’authentification au premier plan.
- Vérification des réponses du Finder, y compris lorsqu’il renvoie une référence plutôt qu’une URL. Une application absente de son emplacement n’est déclarée déplacée qu’après vérification de son identité dans la corbeille du compte courant.
- Les refus, interruptions et réponses sans résultat indiquent leur contexte ; l’historique local conserve le domaine et le code système. Aucun fichier associé n’est traité sans déplacement confirmé du bundle.
- Une autre opération en cours ne peut plus laisser « Autoriser et continuer » sans explication. Les composants système et les applications exigeant un désinstalleur éditeur restent protégés.
- Tests du protocole contre le dictionnaire réel du Finder et tests de régression des installations, permissions et mises à jour depuis 3.6.0. Aucune application personnelle n’est utilisée pour les essais destructifs.

Apple Silicon, macOS 14 minimum. Le paquet Mac reste une version de test sans Developer ID ni notarisation ; Windows reste sans Authenticode. Les mises à jour sont authentifiées et vérifiées. Les autorisations interactives macOS restent soumises aux décisions de l’utilisateur et aux restrictions du système.
