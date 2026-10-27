# StorageScope 3.5.0

- Première distribution macOS universelle : Intel et Apple Silicon, macOS 14 minimum. Application native SwiftUI utilisable hors ligne.
- Tailles des applications et jeux calculées progressivement, indépendamment de l’analyse du disque ; distinction mesurée, déclarée, partielle ou indisponible.
- Logos conservés pendant les actualisations, lectures et tris en arrière-plan, conservation des vues de l’explorateur lorsque l’application revient au premier plan.
- Diagnostics locaux exportables, rotation des journaux et signalement des sessions interrompues. Aucun envoi automatique.
- Mises à jour Mac avec Sparkle : archives et flux signés Ed25519, vérification à chaque lancement, installation après accord.
- Distribution Mac de test : application signée ad hoc, installateur sans certificat Developer ID ni notarisation Apple. macOS peut demander une autorisation individuelle dans Réglages Système > Confidentialité et sécurité. Ne désactivez pas les protections du système.
- Installateur Windows x64/ARM64 maintenu avec vérification RSA des mises à jour. Absence de signature Authenticode ; SmartScreen peut afficher un avertissement.

Les sauvegardes restent conservées par défaut. Les tailles allouées APFS ne garantissent pas un gain équivalent d’espace libre (clones et instantanés). Les composants privilégiés et les désinstallations sans méthode officielle vérifiable restent protégés.
