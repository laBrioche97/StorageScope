# StorageScope 3.5.1

- Correctif Mac : les tableaux de fichiers utilisent désormais des cellules natives à hauteur stable, afin d’éviter la boucle de mise en page observée lors de l’ouverture d’une catégorie depuis la vue d’ensemble.
- Navigation latérale stable, sélection et clavier conservés ; volet superposé dans les petites fenêtres.
- Contrôles de changements de sections et de tailles répétés dans la vraie fenêtre, y compris sur macOS 27, en plus des contrôles macOS 14, 15 Intel et 26.
- Les catégories affichent au maximum leurs 500 principaux fichiers, avec le total détecté ; les anciens filtres sont réinitialisés à l’ouverture.
- Le diagnostic local conserve la raison des exceptions de mise en page lorsqu’AppKit la fournit. Une vérification normale sans nouvelle version n’est plus enregistrée comme une erreur de mise à jour.
- Fonctionnement hors ligne, protections de nettoyage, sauvegardes et données personnelles conservés. Aucun changement fonctionnel Windows.

Version Mac de test, sans signature Developer ID ni notarisation Apple. Les archives et le flux de mise à jour sont authentifiés par Ed25519. Windows conserve son manifeste RSA-PSS vérifié ; le paquet n’a pas de signature Authenticode. Les autorisations du système restent applicables.
