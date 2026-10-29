# StorageScope 3.7.0

- Mac : conservation locale de l’arborescence complète des fichiers et dossiers accessibles après une analyse, y compris les petits fichiers absents des récapitulatifs. Une génération temporaire préserve l’analyse précédente en cas d’interruption.
- Restauration au lancement et actualisation en arrière-plan depuis le journal macOS. Les changements connus sont intégrés sans analyser systématiquement tout le stockage. Un historique incomplet exige une nouvelle analyse explicite.
- État du stockage visible : vérification, actualisation, À jour, analyse partielle, analyse nécessaire ou stockage déconnecté. Les dates de l’analyse complète et de l’actualisation sont disponibles dans l’infobulle.
- Explorateur : zones cliquables circulaires natives, historique commun aux commandes, gestes macOS, raccourcis ⌘[ / ⌘] et boutons latéraux de souris. Conservation du mode Liste/Bulles et des caches de navigation.
- Les chemins, tailles, catégories, dates et identités sont conservés uniquement dans Application Support, sans copier le contenu des fichiers ni télémétrie. Les liens et les espaces techniques propres à l’index restent exclus. L’identité est revérifiée avant une mise à la corbeille.
- Une première analyse complète est nécessaire pour initialiser ce nouvel index. Les anciens résumés restent consultables. Les autres stockages gardent un index distinct et aucune surveillance ne continue lorsque l’application est fermée.

Apple Silicon, macOS 14 minimum. Le paquet Mac reste une version de test sans Developer ID ni notarisation ; Windows reste sans Authenticode. Les mises à jour sont authentifiées et vérifiées. Aucun paquet Intel n’est publié.
