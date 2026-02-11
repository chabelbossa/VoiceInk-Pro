# PROMPT DE MISE À JOUR AUTOMATIQUE - VOICEINK PERSO

**🚨 INSTRUCTION CRITIQUE POUR L'IA 🚨**
Ce document contient la procédure **EXACTE et OBLIGATOIRE** pour mettre à jour VoiceInk. Tu ne dois PAS improviser. Suis ces étapes une par une.

---

## 1. OBJECTIF

Récupérer la dernière version du développeur (`upstream`), fusionner avec mes modifications locales ("Hack Pro" + Build Local), résoudre les conflits, et réinstaller l'application fonctionnelle.

---

## 2. PROCÉDURE D'EXÉCUTION

### ÉTAPE 1 : Sauvegarde & Merge

1.  **Stash** mes modifications locales (pour ne pas les perdre) :
    `git stash save "Config Perso"`
2.  **Fetch & Merge** :
    ```bash
    git fetch upstream
    git merge upstream/main
    ```
3.  **Restaurer le stash** :
    `git stash pop`
4.  **Résolution de conflits** :
    - Si conflit sur `project.pbxproj` : Accepte la version **upstream** (les numéros de version changent), MAIS tu devras réappliquer manuellement le réglage des Entitlements à l'étape 3.
    - Si conflit sur `VoiceInk.swift` ou `LicenseManager.swift` : Garde **mes modifications locales** (le code qui désactive CloudKit et la vérification de licence).

### ÉTAPE 2 : Vérification du Code (Le "Hack")

**Tu dois vérifier que ces fichiers contiennent EXACTEMENT ce qui suit. Sinon, CORRIGE-LES.**

1.  **`VoiceInk/Services/LicenseManager.swift`**
    - Dans `init()`, la ligne `migrateFromUserDefaultsIfNeeded()` doit être **commentée** ou supprimée.
    - Code cible : `// migrateFromUserDefaultsIfNeeded()`

2.  **`VoiceInk/Models/LicenseViewModel.swift`**
    - La variable `licenseState` doit être initialisée à `.licensed` et ne jamais changer.
    - La fonction `validateLicense()` doit forcer `.licensed`.

3.  **`VoiceInk/VoiceInk.swift`**
    - Vérifie que CloudKit est désactivé pour les builds locaux.
    - Recherche : `#if LOCAL_BUILD` -> `cloudKitDatabase: .none`

### ÉTAPE 3 : Configuration du Build (CRITIQUE)

1.  **Vérifier `build_release.sh`** :
    Il doit contenir impérativement :
    - `CODE_SIGN_IDENTITY="-"`
    - `CODE_SIGNING_REQUIRED=NO`
    - `CODE_SIGNING_ALLOWED=YES`
    - `SWIFT_ACTIVE_COMPILATION_CONDITIONS='$(inherited) LOCAL_BUILD'`
    - Un bloc à la fin qui fait `xattr -cr` sur l'app.
    - Un bloc à la fin qui fait `codesign --force --sign - ...` sur tous les frameworks.

2.  **Vérifier `VoiceInk.xcodeproj/project.pbxproj`** :
    - Cherche la configuration **Release**.
    - La ligne `CODE_SIGN_ENTITLEMENTS` doit pointer vers : `VoiceInk/VoiceInkLocal.entitlements`
    - _Si ce n'est pas le cas (écrasé par le merge), change-le._

3.  **Vérifier `VoiceInk/VoiceInkLocal.entitlements`** :
    - Ce fichier doit exister.
    - Il NE DOIT PAS contenir `com.apple.developer.icloud*` ou `keychain-access-groups`.
    - Il DOIT contenir `com.apple.security.device.audio-input` et `screen-capture`.

### ÉTAPE 4 : Compilation & Installation

Exécute ces commandes :

```bash
# 1. Compiler
bash build_release.sh

# 2. Tuer l'ancienne instance
pkill -x VoiceInk || true

# 3. Installer dans /Applications
cp -R build_output/Export/VoiceInk.app /Applications/

# 4. Reset des permissions (pour éviter la boucle infinie)
tccutil reset Microphone com.prakashjoshipax.VoiceInk
tccutil reset ScreenCapture com.prakashjoshipax.VoiceInk
tccutil reset Accessibility com.prakashjoshipax.VoiceInk
```

### ÉTAPE 5 : Rapport Final

Confirme explicitement :

1. "Merge effectué (conflits résolus sur : ...)"
2. "Vérification Licence & CloudKit : OK"
3. "Build Ad-Hoc avec Entitlements Locaux : SUCCÈS"
4. "Permissions réinitialisées."
5. "L'application est prête à être lancée."

---

**Ne pose pas de questions. Exécute.**
