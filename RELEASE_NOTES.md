# StorageScope 3.7.1

- Mac : les données tierces choisies explicitement dans Application Support, comme TabNine, disposent d’un parcours de mise à la corbeille avec avertissement sur les réglages et données locales. Elles restent exclues du nettoyage automatique. Les emplacements système, bibliothèques sensibles, dossiers cloud, jeux gérés et liens conservent leurs protections.
- Corbeille : les entrées restent visibles lorsque leur taille ne peut pas être entièrement mesurée. Les accès refusés sont distingués d’une corbeille vide, avec un accès aux réglages de confidentialité et une actualisation au retour.
- Affichage du contenu de la corbeille, tailles partielles explicites et correction du bouton de vidage : une seule confirmation, limitée aux éléments inventoriés et vérifiés. Un inventaire partiel ne donne jamais un faux bilan « Corbeille vidée ».
- Vérification des identités avant chaque opération, historique local et protections de l’index persistant conservés.

Apple Silicon, macOS 14 minimum. Le paquet Mac reste une version de test sans Developer ID ni notarisation ; Windows reste sans Authenticode. Les mises à jour sont authentifiées et vérifiées. Aucun paquet Intel n’est publié.
