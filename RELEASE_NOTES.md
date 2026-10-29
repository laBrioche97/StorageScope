# StorageScope 3.6.0

- Mac : les applications tierces appartenant à root ne sont plus bloquées par leur propriétaire seul. Le plan distingue désinstallation admissible, autorisation macOS, méthode officielle nécessaire et protection système.
- Mise à la corbeille native, vérification de l’identité et du résultat avant les résidus. Après un refus, « Autoriser et continuer » explique Gestion des apps et le recours facultatif au Finder. Les identifiants administrateur restent dans les fenêtres système ; aucun service administrateur permanent n’est installé.
- Nouvelle liste native avec logos, tailles, état des autorisations et panneau de détails. Les jeux reconnus sont accessibles depuis le même écran.
- Interface aérée, accent framboise, résumé graphique des catégories et sélection de nettoyage accessible en bas de l’écran.
- Transitions discrètes, navigation avec zoom et fondu, respect de la réduction des animations et conservation du contenu pendant le chargement.
- États des logos et tailles isolés du scan, décodage des icônes en arrière-plan, lectures récursives limitées à deux et ouverture de l’index hors interface. Les dossiers en cache conservent sélection et défilement.
- Comparaison automatisée des scans avec 3.5.1 et tests isolés des autorisations, de l’installation et des mises à jour. Aucun essai de désinstallation ne vise une application personnelle.
- Les liens restent exclus du parcours sans risquer de sauter le contenu d’un dossier voisin lors du scan ou du calcul des tailles.
- Windows reste pris en charge avec ses fonctions et protections existantes. Aucun paquet Mac Intel n’est publié.

Version Mac de test, macOS 14 minimum, sans Developer ID ni notarisation Apple. Archives et flux Sparkle authentifiés par Ed25519. Le paquet Windows conserve son manifeste RSA-PSS vérifié et reste sans signature Authenticode. Les autorisations macOS peuvent devoir être renouvelées après une mise à jour de cette version de test. Les restrictions système et méthodes officielles des applications restent applicables.
